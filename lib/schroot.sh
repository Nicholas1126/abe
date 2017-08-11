#!/bin/bash
# 
#   Copyright (C) 2014, 2015, 2016 Linaro, Inc
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
# 

# Print DJ board files used for testing
# $1 - [optional] target triplet
print_schroot_board_files()
{
#    trace "$*"

    local target="$1"

    if ! [ -z "$target" ]; then
	target="--target=$target"
    fi

    # Run dummy runtest to figure out which target boards load schroot-ssh.exp
    runtest $target --tool none 2>&1 | awk '
/^Using .* as board description file for target\.$/ { if (board == "") { board=$2 } }
/^Using .*\/schroot-ssh.exp as generic interface file for target\.$/ { print board }
'
    rm -f none.log none.sum
}

# Print unique port to be used for ssh server on the boards
print_schroot_port()
{
#    trace "$*"

    local port

    if [ x"$test_container" != x"" ]; then
	port="$(echo $test_container | grep ":" | sed -e "s/.*://")"
	if [ x"$port" = x"" ]; then
	   error "Wrong format of test_container: $test_container"
	   return 1
	fi
	echo $port
	return 0
    fi

    # Set build_n to the last digit appearing in hostname.
    # E.g., tcwgbuild04 becomes "4" (and so does x86_64).
    # This is purely for convenience when determining which hosts use
    # a particular target board.
    # If the port turns out to be already in use on one of the boards then
    # test-schroot.sh will gracefully fail.
    local build_n
    build_n="$(hostname | sed -e "s/.*\([0-9]\).*/\1/" | grep "[0-9]")"
    test -z "$build_n" && build_n="0"
    port=$((50000+1000*$build_n+$RANDOM%1000))
    # We return ports between 50000 and 59999
    echo $port
}

# Start schroot session on a single board.
# $1 - target triplet (can be empty, which means "native")
# $2 - sysroot to copy to target (can be empty)
# $3 - directory on host that should be mounted on target via sshfs
# $4 - dejagnu board file
# $5 - filename for log
start_schroot_session()
{
    local target="$1"
    local sysroot="$2"
    local shared_dir="$3"
    local board_exp="$4"
    local log="$5"

    # Get board hostname
    local hostname
    hostname="$(grep "^set_board_info hostname " $board_exp | sed -e "s/^set_board_info hostname //")"
    if [ -z "$hostname" ]; then
	error "Board file $board_exp uses schroot testing, but does not define \"set_board_info hostname\""
	return 1
    elif [ x"$hostname" = x"[getenv ABE_TEST_CONTAINER_USER]@[getenv ABE_TEST_CONTAINER_MACHINE]" ]; then
	# Set $hostname to a container marker: "@".
	hostname="@"
    fi
    if [ x"$hostname" = x"@" -a x"$test_container" = x"" ]; then
	error "Board file $board_exp relies on [docker] container, but test_container is not defined"
	return 1
    fi

    local begin_session_opt machine_opt
    if [ x"$hostname" != x"@" ]; then
	begin_session_opt="-b"
	machine_opt="$hostname:$schroot_port"
    else
	begin_session_opt=""
	machine_opt="$test_container"
    fi

    local target_opt
    if ! [ -z "$target" ]; then
	target_opt="-a $target"
    fi

    local sysroot_opt
    if ! [ -z "$sysroot" ]; then
	local multilib_dir
	multilib_dir="$(find_dynamic_linker "$sysroot" true)"
	multilib_dir="$(basename $(dirname $multilib_dir))"
	sysroot_opt="-l $sysroot -h $multilib_dir"
    fi

    local result
    # This command is very handy to have in logs to reproduce test
    # environment.
    local was_verbose="${-//[^x]/}"
    if [ x"$was_verbose" != x"x" ]; then set -x; fi
    # Start testing schroot session.
    dryrun "$topdir/scripts/test-schroot.sh -v $begin_session_opt $target_opt -m $sysroot_opt $machine_opt" > $log 2>&1; result="$?"
    if [ x"$was_verbose" != x"x" ]; then set +x; fi

    cat $log >&2

    if grep -q "Failed to write session file: File exists" $log; then
	result="2"
    else
	if [ x"$hostname" != x"@" ]; then
	    # Add $hostname to the list of boards to cleanup in
	    # stop_schroot_sessions
	    schroot_boards="$schroot_boards $hostname"
	fi

	if test x"$result" != x"0"; then
	    result="1"
	fi
    fi

    return "$result"
}

# Start schroot sessions on all relevant boards.
# This routine sets global $schroot_make_opts to pass info upstream.
# Local state is maintained in $schroot_boards and $schroot_port variables.
# $1 - target triplet
# $2 - target sysroot
# $3 - directory on host that should be mounted on target
start_schroot_sessions()
{
#    trace "$*"

    local target="$1"
    local sysroot="$2"
    local shared_dir="$3"

    local sysroot_env
    if ! [ -z "$sysroot" ]; then
	sysroot_env="SYSROOT_UNDER_TEST=$sysroot"
    fi

    local -a board_exps
    board_exps=($(eval $sysroot_env print_schroot_board_files "$target"))

    if [ -z "${board_exps[@]}" ]; then
	return 0
    fi

    # Result of "0" means OK; "1" means FAIL; "2" means RETRY.
    local result="2"

    while test x"$result" = x"2"; do
	eval "schroot_boards="
	eval "schroot_port=$(print_schroot_port)"

	local shared_dir_ok=true
	local board_exp

	for board_exp in "${board_exps[@]}"; do
	    local log=$(mktemp)

	    start_schroot_session "$1" "$2" "$3" "$board_exp" "$log"
	    result="$?"

	    if ! grep -q "shared directory .*: SUCCESS" $log; then
		shared_dir_ok=false
	    fi

	    rm -f $log

	    if test x"$result" != x"0"; then
		stop_schroot_sessions
		break
	    fi
	done
    done

    if test x"$result" != x"0"; then
	return 1
    fi

    # Cleanup schroot sessions if user kills testing
    trap "stop_schroot_sessions" HUP INT KILL TERM EXIT

    schroot_make_opts="SCHROOT_PORT=$schroot_port"
    if $shared_dir_ok; then
	schroot_make_opts="$schroot_make_opts SCHROOT_SHARED_DIR=$shared_dir"
    fi
    if [ x"$test_container" != x"" ]; then
	local user machine
	user="$(echo $test_container | grep "@" | sed -e "s/@.*//")"
	machine="$(echo $test_container | sed -e "s/.*@//g" -e "s/:.*//g")"

	if [ x"$user" = x"" ]; then
	    user=$(ssh -p$schroot_port $machine whoami)
	fi

	schroot_make_opts="$schroot_make_opts ABE_TEST_CONTAINER_USER=$user ABE_TEST_CONTAINER_MACHINE=$machine"
    fi
}

# Stop schroot sessions on $schroot_boards
stop_schroot_sessions()
{
#    trace "$*"

    for hostname in $schroot_boards; do
	dryrun "${topdir}/scripts/test-schroot.sh -v -f $hostname:$schroot_port"
    done

    schroot_boards=""
}
