#!/bin/bash
# 
#   Copyright (C) 2013, 2014, 2015, 2016 Linaro, Inc
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

# These store all the data used for this test run that can be overwritten by
# command line options.

# Start by assuming it's a native build
build="${build}"
host="${host:-${build}}"
target="${host}"

# we need to read the date once, so that we don't have
# varying dates when midnight occurs during a build.
timestamp=$(date +%s)
date="$(date --date="@${timestamp}" "+%Y.%m.%d")"
gcc="$(which gcc)"
host_gcc_version="$(${gcc} -v 2>&1 | tail -1)"
binutils="default"
# This is the default clibrary and can be overridden on the command line.
clibrary="auto"
snapshots="default"
configfile="default"

# Don't set this unless you need to modify it.
override_arch=
override_cpu=
override_tune=

manifest_version=1.4

# The prefix for installing the toolchain
prefix=

# The default timeout.  If you're on a wireless network this
# might not be sufficient and can be overridden at the command
# line.
wget_timeout=10
wget_quiet=
# if output is on a terminal we use the default style (bar), otherwise
# we use the briefest available dot style to reduce the size of the logs
if [ -t 1 ]; then
    wget_progress_style=
else
    wget_progress_style=dot:giga
fi

# This doesn't do any real work, just prints the configure options and make commands
dryrun=no

#
launchpad_id=
svn_id=

# config values for the build machine
libc_version=
kernel=${kernel:+${kernel}}
build_arch=${build_arch:+${build_arch}}
hostname=${hostname:+${hostname}}
distribution=${distribution:+${distribution}}

# These are options flags to pass to make, usually just -j N as set by --parallel
make_flags=

# These can be changed by environment variables
if test x"${SNAPSHOTS_URL}" != x -o x"${ABE_SNAPSHOTS}" != x; then
    snapshots="${SNAPSHOTS_URL}"
fi

force=no
interactive=no
verbose=1
network=""

# Don't modify this in this file unless you're adding to it.  This is the list
# of packages that have make check run against them.  It will be queried for
# content when the users passes --check <package> or --excludecheck <package>.
all_unit_tests="glibc newlib gcc gdb binutils"

# Packages to run make check (unit-test) on.  This variable is composed from
# all --check <package> and --excludecheck <package> switches.  Don't modify
# this parameter manually.
runtests=

# Container <user>@<ipaddress>:<ssh_port> to be used in cross-testing.
test_container=

release=""
with_packages="toolchain,sysroot,gdb"
building=yes

override_linker=
override_cflags=
override_ldflags=
override_runtestflags=

if test x"${BUILD_NUMBER}" = x; then
    export BUILD_NUMBER=${RANDOM}
fi

jenkins_job_name=""
jenkins_job_url=""
sources_conf="${sources_conf:-${abe_path}/config/sources.conf}"

list_artifacts=""
build_config=""

# source a user specific config file for commonly used configure options.
# These overide any of the above values.
if test -e ~/.aberc; then
    . ~/.aberc
fi

#
#
#

import_manifest()
{
#    trace "$*"

    manifest=$1
    if test -f ${manifest} ; then
	local components="$(grep "^# Component data for " ${manifest} | cut -d ' ' -f 5)"

	clibrary="$(grep "^clibrary=" ${manifest} | cut -d '=' -f 2)"
	local ltarget="$(grep ^target= ${manifest}  | cut -d '=' -f 2)"
	if test x"${ltarget}" != x; then
	    target=${ltarget}
	fi
	sysroots=${sysroots}/${target}

	local manifest_format="$(grep "^manifest_format" ${manifest} | cut -d '=' -f 2)"
	local fixup_mingw=false
	case "${manifest_format}" in
	    1.1) # no md5sums or id, but no special handling required
                 fixup_mingw=true ;;
	    1.2) # no manifest id, but no special handling required
                 fixup_mingw=true ;;
	    1.3) fixup_mingw=true ;;
	    1.4) ;;
	    *)
		error "Imported manifest version $manifest_format is not supported."
		return 1
		;;
	esac
	local variables=
	local i=0
	for i in ${components}; do
	    local md5sum="$(grep "^${i}_md5sum" ${manifest} | cut -d '=' -f 2)"
	    local url="$(grep "^${i}_url" ${manifest} | cut -d '=' -f 2)"
	    local branch="$(grep "^${i}_branch" ${manifest} | cut -d '=' -f 2)"
	    local filespec="$(grep "^${i}_filespec" ${manifest} | cut -d '=' -f 2)"
	    local static="$(grep "^${i}_staticlink" ${manifest} | cut -d '=' -f 2)"
	    local mingw_extraconf="$(grep "^${i}_mingw_extraconf" ${manifest} | cut -d '=' -f 2- | tr ' ' '%'| tr -d '\"')"
	    local mingw_only="$(grep "^${i}_mingw_only" ${manifest} | cut -d '=' -f 2)"
	    # Any embedded spaces in the value have to be converted to a '%'
	    # character. for component_init().
	    local makeflags="$(grep "^${i}_makeflags" ${manifest} | cut -d '=' -f 2-20 | tr ' ' '%')"
	    eval "makeflags=${makeflags}"
	    local configure="$(grep "^${i}_configure" ${manifest} | cut -d '=' -f 2-20 | tr ' ' '%'| tr -d '\"')"
	    eval "configure=${configure}"
	    local revision="$(grep "^${i}_revision" ${manifest} | cut -d '=' -f 2)"
	    if test "$(echo ${filespec} | grep -c \.tar\.)" -gt 0; then
		local version="$(echo ${filespec} | sed -e 's:\.tar\..*$::')"
		local dir=${version}
	    else
		local fixbranch="$(echo ${branch} | tr '/@' '_')"
		local dir=${filespec}~${fixbranch}${revision:+_rev_${revision}}
	    fi
	    local srcdir="${local_snapshots}/${dir}"
	    local builddir="${local_builds}/${host}/${target}/${dir}"
	    case "${i}" in
		gdbserver)
		    local srcdir=${local_snapshots}/${dir}/gdb/gdbserver
 		    local builddir="${local_builds}/${host}/${target}/${dir}-gdbserver"
		    ;;
		*glibc)
		    # Glibc builds will fail if there is an @ in the path. This is
		    # unfortunately, as @ is used to deliminate the revision string.
		    local srcdir="${local_snapshots}/${dir}"
		    local builddir="$(echo ${local_builds}/${host}/${target}/${dir} | tr '@' '_')"
		    ;;
		gcc)
		    local configure=
		    local stage1_flags="$(grep ^gcc_stage1_flags= ${manifest} | cut -d '=' -f 2-20 | tr ' ' '%' | tr -d '\"')"
		    eval "stage1_flags=${stage1_flags}"
		    local stage2_flags="$(grep ^gcc_stage2_flags= ${manifest} | cut -d '=' -f 2-20 | tr ' ' '%' | tr -d '\"')"
		    eval "stage2_flags=${stage2_flags}"
		    ;;
		*)
		    ;;
	    esac

            # for old manifests, we have to fix up the missing parameters
            if ${fixup_mingw}; then
                mingw_extraconf=""
                case ${i} in
                    expat|python) mingw_only=yes ;;
                    *) mingw_only=no ;;
                esac
            fi

	    component_init $i ${branch:+BRANCH=${branch}} ${revision:+REVISION=${revision}} ${url:+URL=${url}} ${filespec:+FILESPEC=${filespec}} ${srcdir:+SRCDIR=${srcdir}} ${builddir:+BUILDDIR=${builddir}} ${stage1_flags:+STAGE1=\"${stage1_flags}\"} ${stage2_flags:+STAGE2=\"${stage2_flags}\"} ${configure:+CONFIGURE=\"${configure}\"} ${makeflags:+MAKEFLAGS=\"${makeflags}\"} ${static:+STATICLINK=${static}} ${md5sum:+MD5SUM=${md5sum}} ${mingw_only:+MINGWEXTRACONF=\"${mingw_extraconf}\"} ${mingw_only:+MINGWONLY=${mingw_only}}
	    if [ $? -ne 0 ]; then
		error "component_init failed while parsing manifest"
		build_failure
		return 1
	    fi

	    unset stage1_flags
	    unset stage2_flags
	    unset url
	    unset branch
	    unset filespec
	    unset static
	    unset makeflags
	    unset configure
	    unset md5sum
	    unset mingw_only
	    unset mingw_extraconf
	done
    else
	error "Manifest file '${manifest}' not found"
	build_failure
	return 1
    fi

    return 0
}

#
# get_component_list() returns the components which must be built in the
# current configuration
#
get_component_list()
{
    # read dependencies from infrastructure.conf
    # TODO: support --extraconfigdir for infrastructure.conf
    local builds="$(grep ^depends ${topdir}/config/infrastructure.conf | tr -d '"' | sed -e 's:^depends=::')"

    if test x"${target}" != x"${build}"; then
        # Build a cross compiler
	if is_host_mingw; then
	    # As Mingw32 requires a cross compiler to be already built, so we
	    # don't need to rebuild the sysroot.
            builds="${builds} expat python binutils libc stage2 gdb"
	else
	    # Non-linux builds skip expat and python, but are here so that
            # they are included in the manifest, so linux and mingw
            # manifests can be identical.
            builds="${builds} expat python binutils stage1 libc stage2 gdb"
	fi
	if test "$(echo ${target} | grep -c -- -linux-)" -eq 1; then
	    builds="${builds} gdbserver"
	else
	    # "linux" is included in the depends line in infrastructure.conf,
	    # but is only needed for linux targets. Therefore remove it for
	    # all other targets.
	    builds="$(echo ${builds} | sed -e 's: linux::')"
	fi
    else
        builds="${builds} binutils stage2 libc gdb" # native build
    fi

    # if this build is based on a manifest, then we must remove components from
    # the build list which aren't described by the manifest
    if [ x"${manifest}" != x"" ]; then
        local i
        for i in ${builds}; do
            local match=${i}
            match=${match/stage[12]/gcc}
            match=${match/libc/${clibrary}}
            if ! echo "${toolchain[*]}" | grep -q "\\<${match}\\>"; then
                builds=$(echo "${builds}" | sed -e "s/\\<${i}\\>//")
            fi
        done
    fi

    echo "${builds}"
}

#
# record_artifact() adds an artifact to the artifacts list file, if one
# was configured on the command line
#
record_artifact()
{
    local artifact=$1
    local path=$(readlink -m $2)
    if [ x"${path}" = x"" ]; then
        error "Artifact path '${2}' was invalid."
        return 1
    fi
    notice "Artifact ${artifact} created at ${path}."
    if [ "${list_artifacts:+set}" = "set" -a x"${dryrun}" != xyes ]; then
        echo "${artifact}=${path}" >> "${list_artifacts}"
    fi
}
