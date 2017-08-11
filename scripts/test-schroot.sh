#!/bin/bash

# Improve debug logs
PRGNAME=`basename $0`
PS4='+ $PRGNAME: ${FUNCNAME+"$FUNCNAME : "}$LINENO: '

set -e

arch="native"
begin_session=false
shared_dir=""
finish_session=false
sysroot=""
ssh_master=false
target_ssh_opts=""
host_ssh_opts=""
profile="tcwg-test"
multilib_path="lib"
uname=""

while getopts "a:bd:fh:l:mo:p:P:qu:v" OPTION; do
    case $OPTION in
	a) arch=$OPTARG ;;
	b) begin_session=true ;;
	d) shared_dir=$OPTARG ;;
	f) finish_session=true ;;
	h) multilib_path="$OPTARG" ;;
	l) sysroot=$OPTARG ;;
	m) ssh_master=true ;;
	o) target_ssh_opts="$target_ssh_opts -o $OPTARG" ;;
	p) host_ssh_opts="$OPTARG" ;;
	P) profile="$OPTARG" ;;
	q) exec > /dev/null ;;
	u) uname="$OPTARG" ;;
	v) set -x ;;
    esac
done
shift $((OPTIND-1))

triplet_to_deb_arch()
{
    set -e
    case "$1" in
	aarch64-*linux-gnu) echo arm64 ;;
	arm*-*linux-gnueabi*) echo armhf ;;
	i686-*linux-gnu) echo i386 ;;
	x86_64-*linux-gnu) echo amd64 ;;
	*) return 1 ;;
    esac
}

triplet_to_deb_dist()
{
    set -e
    case "$arch" in
	aarch64-*linux-gnu) echo trusty ;;
	arm*-*linux-gnueabi*) echo trusty ;;
	i686-*linux-gnu) echo trusty ;;
	x86_64-*linux-gnu) echo trusty ;;
	*) return 1 ;;
    esac
}

user="$(echo $1 | grep "@" | sed -e "s/@.*//")"
machine="$(echo $1 | sed -e "s/.*@//g" -e "s/:.*//g")"
port="$(echo $1 | grep ":" | sed -e "s/.*://")"

if [ -z "$machine" ]; then
    echo ERROR: no target specified
    exit 1
fi

if [ -z "$port" ]; then
    echo "ERROR: no custom [ssh] port specified"
    exit 1
fi

# See https://git.linaro.org/ci/dockerfiles.git/blob/HEAD:/tcwg-buildslave/.ssh/config
# for the master copy of these settings.
# We need to duplicate them here to handle bare IP addresses of containers.
ssh_opts="-o Port=$port -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=FATAL -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh-$profile-%r@%h:%p.$$ $target_ssh_opts"
rsh="ssh $ssh_opts"
rcp="scp $ssh_opts"

if [ x"$user" = x"" ]; then
    if $begin_session || $finish_session; then
	user="$(ssh $target_ssh_opts $machine echo \$USER)"
    else
	user="$($rsh $machine echo \$USER)"
    fi
fi

target="$user@$machine"

if $begin_session || $finish_session; then
    initial_ssh="ssh $target_ssh_opts $target"
else
    initial_ssh="ssh $ssh_opts $target"
fi

use_qemu=false
if ! triplet_to_deb_arch "$arch" >/dev/null 2>&1; then
    use_qemu=true
    arch="native"
fi

# Use '|| true' to avoid early exit if $target does not answer.
cpu="$($initial_ssh uname -m)" || true
case "$cpu" in
    aarch64) native_arch=aarch64-linux-gnu ;;
    armv*l) native_arch=arm-linux-gnueabihf ;;
    armv*) native_arch=arm-linux-gnueabi ;;
    i686) native_arch=i686-linux-gnu ;;
    x86_64) native_arch=x86_64-linux-gnu ;;
    "")
	echo "ERROR: target $target returned no cpu type."
	exit 1
	;;
    *)
	echo "ERROR: unrecognized native target $cpu"
	exit 1
	;;
esac

if [ x"$arch" = x"native" ]; then
    arch="$native_arch"
fi

deb_arch="$(triplet_to_deb_arch $arch)"

case "$cpu:$deb_arch" in
    "x86_64:amd64"|"x86_64:i386") ;;
    "x86_64:"*)
	use_qemu=true
	arch=$native_arch
	;;
esac

deb_arch="$(triplet_to_deb_arch $arch)"
deb_dist="$(triplet_to_deb_dist $arch)"

schroot_id=$profile-$deb_arch-$deb_dist

schroot="$initial_ssh schroot -r -c session:$profile-$port -d / -u root --"
home="$($initial_ssh pwd)"

if $begin_session; then
    $initial_ssh schroot -b -c chroot:$schroot_id -n $profile-$port -d /
    # Start ssh server on custom port
    $schroot sed -i -e "\"s/^Port 22/Port $port/\"" /etc/ssh/sshd_config
    # Run as root
    $schroot sed -i -e "\"s/^UsePrivilegeSeparation yes/UsePrivilegeSeparation no/\"" /etc/ssh/sshd_config
    # Adjust unsupported option
    $schroot sed -i -e "\"s/PermitRootLogin prohibit-password/PermitRootLogin without-password/\"" /etc/ssh/sshd_config
    # Increase number of incoming connections from 10 to 256
    $schroot sed -i -e "\"/.*MaxStartups.*/d\"" -e "\"/.*MaxSesssions.*/d\"" /etc/ssh/sshd_config
    $schroot bash -c "\"echo \\\"MaxStartups 256\\\" >> /etc/ssh/sshd_config\""
    $schroot bash -c "\"echo \\\"MaxSessions 256\\\" >> /etc/ssh/sshd_config\""
    $schroot /etc/init.d/ssh start
    # Crouton needs firewall rule.
    $schroot iptables -I INPUT -p tcp --dport $port -j ACCEPT >/dev/null 2>&1 || true

    $schroot mkdir -p /root/.ssh
    if $initial_ssh test -f .ssh/authorized_keys; then
	$initial_ssh cat .ssh/authorized_keys
    else
	$initial_ssh sss_ssh_authorizedkeys $user
    fi \
	| $schroot bash -c "'cat > /root/.ssh/authorized_keys'"
    $schroot chmod 0600 /root/.ssh/authorized_keys

    $rsh root@$machine echo "Can login as root!"

    $rsh root@$machine getent passwd $user | true
    if [ x"${PIPESTATUS[0]}" != x"0" ]; then
	user_data="$($initial_ssh getent passwd $user)"
	target_uid="$(echo "$user_data" | cut -d: -f 3)"
	$rsh root@$machine useradd -m -u $target_uid $user
    fi

    $rsh root@$machine rsync -a /root/ $home/
    $rsh root@$machine chown -R $user $home/

    $rsh root@$machine "echo 1 > /dont_keep_session"
    $rsh root@$machine chmod 0666 /dont_keep_session

    echo $target:$port started schroot: $rsh $target
fi

if ! [ -z "$shared_dir" ]; then
    # Generate a one-time key to allow ssh back to host.
    ssh-keygen -t rsa -N "" -C "test-schroot.$$" -f ~/.ssh/id_rsa-test-schroot.$$
    echo >> ~/.ssh/authorized_keys
    cat ~/.ssh/id_rsa-test-schroot.$$.pub >> ~/.ssh/authorized_keys
    $rcp ~/.ssh/id_rsa-test-schroot.$$ $target:.ssh/

    $rsh root@$machine mkdir -p "$shared_dir"
    $rsh root@$machine chown -R $user "$shared_dir"

    $rsh root@$machine rm -f /etc/mtab
    $rsh root@$machine ln -s /proc/mounts /etc/mtab
    tmp_ssh_port="$(($port-10000))"
    host_ssh_port="$(grep "^Port" /etc/ssh/sshd_config | sed -e "s/^Port //")"
    test -z "$host_ssh_port" && host_ssh_port="22"
    # Establish port forwarding
    $rsh -fN -S none -R $tmp_ssh_port:127.0.0.1:$host_ssh_port $target
    # Recent versions of sshfs fail if ssh_command has more than a single
    # white spaces between options or ends with a space; filter ssh_command.
    ssh_command="$(echo "ssh -o Port=$tmp_ssh_port -o IdentityFile=$home/.ssh/id_rsa-test-schroot.$$ -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $host_ssh_opts" | sed -e "s/ \+/ /g" -e "s/ \$//")"
    try="0"
    while [ "$try" -lt "3" ]; do
	$rsh $target sshfs -C -o ssh_command="\"$ssh_command\"" "$USER@127.0.0.1:$shared_dir" "$shared_dir" | true
	if [ x"${PIPESTATUS[0]}" != x"0" ]; then
	    try=$(($try + 1))
	    sleep 1
	    continue
	fi
	break
    done

    # Remove temporary key and delete extra empty lines at the end of file.
    sed -i -e "/.*test-schroot\.$$\$/d" -e '/^$/N;/\n$/D' ~/.ssh/authorized_keys
    rm ~/.ssh/id_rsa-test-schroot.$$*

    if [ "$try" != "3" ]; then
	echo "$target:$port shared directory $shared_dir: SUCCESS"
    else
	echo "$target:$port shared directory $shared_dir: FAIL"
    fi
else
    # GCC's profiling tests expect read-write access to the mirror path
    # on the remote as the path they are on the build host.
    # When we are not sharing the build directory, create at least mirror
    # ABE's top-dir path in the testing session owned by remote user
    # to accomodate profiling tests.
    $rsh root@$machine mkdir -p $(pwd)
    $rsh root@$machine chown -R $user $(pwd)
fi

if ! [ -z "$sysroot" ]; then
    rsync -az -e "$rsh" $sysroot/ root@$machine:/sysroot/
    $rsh root@$machine chown -R root:root /sysroot/

    if [ -e $sysroot/lib64/ld-linux-aarch64.so.1 ]; then
	# Our aarch64 sysroot has everything in /lib64, but executables
	# still expect to find dynamic linker under /lib/ld-linux-aarch64.so.1
	if [ -h $sysroot/lib ]; then
	    $rsh root@$machine "rm /sysroot/lib"
	fi
	if [ -h $sysroot/lib ] \
	    || ! [ -e $sysroot/lib/ld-linux-aarch64.so.1 ]; then
	    $rsh root@$machine "mkdir -p /sysroot/lib/"
	    $rsh root@$machine "cd /sysroot/lib; ln -s ../lib64/ld-linux-aarch64.so.1 ."
	fi
    fi

    if ! $use_qemu; then
	# Make sure that sysroot libraries are searched before any other.
	$rsh root@$machine "cat > /etc/ld.so.conf.new" <<EOF
/$multilib_path
/usr/$multilib_path
EOF
	$rsh root@$machine "cat /etc/ld.so.conf >> /etc/ld.so.conf.new"
	$rsh root@$machine "mv /etc/ld.so.conf.new /etc/ld.so.conf && rsync -a --exclude=/sysroot /sysroot/ / && ldconfig"
    else
	# Remove /etc/ld.so.cache to workaround QEMU problem for targets with
	# different endianness (i.e., /etc/ld.so.cache is endian-dependent).
	$rsh root@$machine "rm /etc/ld.so.cache"
	# Cleanup runaway QEMU processes that ran for more than 2 minutes.
	# Note the "-S none" option -- ssh does not always detach from process
	# when multiplexing is used.  I think this is a bug in ssh.
	# We calculate delay in this fashion to avoid multi-thread tests
	# getting through a minute of usertime in 60/#_of_cpus seconds.
	delay=$((60 / $($rsh $target getconf _NPROCESSORS_ONLN)))
	$rsh -f -S none $target bash -c "\"while sleep $delay; do ps uxf | sed -e \\\"s/ \+/ /g\\\" | cut -d\\\" \\\" -f 2,10- | grep \\\"^[0-9]\+ [0-9]*2:[0-9]\+ ._ qemu-\\\" | cut -d\\\" \\\" -f 1 | xargs -r kill -9; done\""
    fi
    echo $target:$port installed sysroot $sysroot
fi

if [ x"$uname" != x"" ]; then
    old_uname="$($rsh root@$machine "uname -m")"
    $rsh root@$machine "mv /bin/uname /bin/uname.real"
    $rsh root@$machine "cat > /bin/uname" <<EOF
#!/bin/bash

/bin/uname.real "\$@" | sed -e "s/$old_uname/$uname/g"
exit \${PIPESTATUS[0]}
EOF
    $rsh root@$machine "chmod a+x /bin/uname"
fi

if $ssh_master; then
    ssh -o ControlMaster=yes -o ControlPath=/tmp/ssh-%u-%r@%h:%p $ssh_opts -fN $target
    ssh -v -o ControlMaster=no -o ControlPath=/tmp/ssh-%u-%r@%h:%p $ssh_opts $target echo "Can ssh using master connection if the above log is short"
fi

# Keep the session alive when file /dont_kill_me is present
if $finish_session; then
    # Perform all operations from outside of schroot session since the inside
    # may be completely broken (e.g., bash doesn't start).
    schroot_location="$($initial_ssh schroot --location -c session:$profile-$port)"
    if [ x"$($initial_ssh cat $schroot_location/dont_keep_session)" != x"1" ]; then
	finish_session=false
    fi
fi

if $finish_session; then
    $schroot iptables -I INPUT -p tcp --dport $port -j REJECT >/dev/null 2>&1 || true
    $initial_ssh schroot -f -e -c session:$profile-$port | true
    if [ x"${PIPESTATUS[0]}" != x"0" ]; then
	# tcwgbuildXX machines have a kernel problem that a bind mount will be
	# forever busy if it had an sshfs under it.  Seems like fuse is not
	# cleaning up somethings.  The workaround is to lazy unmount the bind.
	$schroot umount -l /
	$initial_ssh schroot -f -e -c session:$profile-$port
    fi
    echo $target:$port finished session
fi

$rsh -O exit $user@$machine || true
$rsh -O exit root@$machine || true
