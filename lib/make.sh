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

# This performs all the steps to build a full cross toolchain
build_all()
{
#    trace "$*"
    
    local builds="$*"

    notice "build_all: Building components: ${builds}"

    local build_all_ret=

    # build each component
    for i in ${builds}; do
        local mingw_only="$(get_component_mingw_only $i)"
        if [ x"$mingw_only" = x"yes" ] && ! is_host_mingw ; then
            notice "Skipping component $i, which is only required for mingw hosts"
            continue
        fi
        notice "Building all, current component $i"
        # If an interactive build, stop betweeen each step so we can
        # check the build and config options.
        if test x"${interactive}" = x"yes"; then
            echo "Hit any key to continue..."
            read answer
        fi
        case $i in
            # Build stage 1 of GCC, which is a limited C compiler used to compile
            # the C library.
            libc)
                build ${clibrary}
                build_all_ret=$?
                ;;
            stage1)
                build gcc stage1
                build_all_ret=$?
                # Don't create the sysroot if the clibrary build didn't succeed.
                if test ${build_all_ret} -lt 1; then
                    # If we don't install the sysroot, link to the one we built so
                    # we can use the GCC we just built.
		    if test x"${dryrun}" != xyes; then
			local sysroot="$(${target}-gcc -print-sysroot)"
			if test ! -d ${sysroot}; then
			    dryrun "ln -sfnT ${abe_top}/sysroots/${target} ${sysroot}"
			fi
		    fi
                fi
                ;; 
            # Build stage 2 of GCC, which is the actual and fully functional compiler
            stage2)
		# FIXME: this is a seriously ugly hack required for building Canadian Crosses.
		# Basically the gcc/auto-host.h produced when configuring GCC stage2 has a
		# conflict as sys/types.h defines a typedef for caddr_t, and autoheader screws
		# up, and then tries to redefine caddr_t yet again. We modify the installed
		# types.h instead of the one in the source tree to be a tiny bit less ugly.
		# After libgcc is built with the modified file, it needs to be changed back.
		if is_host_mingw; then
		    sed -i -e 's/typedef __caddr_t caddr_t/\/\/ FIXME: typedef __caddr_t caddr_t/' ${sysroots}/usr/include/sys/types.h
		fi

                build gcc stage2
                build_all_ret=$?
		# Reverse the ugly hack
		if is_host_mingw; then
		    sed -i -e 's/.*FIXME: //' ${sysroots}/usr/include/sys/types.h
		fi
                ;;
            expat)
		# TODO: avoid hardcoding the version in the path here
		dryrun "rsync -ar ${local_snapshots}/expat-2.1.0-1/include ${local_builds}/destdir/${host}/usr/"
		if [ $? -ne 0 ]; then
		    error "rsync of expat include failed"
		    return 1
		fi
		dryrun "rsync -ar ${local_snapshots}/expat-2.1.0-1/lib ${local_builds}/destdir/${host}/usr/"
		if [ $? -ne 0 ]; then
		    error "rsync of expat lib failed"
		    return 1
		fi
		;;
            python)
		# The mingw package of python contains a script used by GDB to
		# configure itself, this is used to specify that path so we
		# don't have to modify the GDB configure script.
		# TODO: avoid hardcoding the version in the path here...
		export PYTHON_MINGW=${local_snapshots}/python-2.7.4-mingw32
		# The Python DLLS need to be in the bin dir where the
		# executables are.
		dryrun "rsync -ar ${PYTHON_MINGW}/pylib ${PYTHON_MINGW}/dll ${PYTHON_MINGW}/libpython2.7.dll ${local_builds}/destdir/${host}/bin/"
		if [ $? -ne 0 ]; then
		    error "rsync of python libs failed"
		    return 1
		fi
		# Future make check support of python GDB in mingw32 will
		# require these exports.  Export them now for future reference.
		export PYTHONHOME=${local_builds}/destdir/${host}/bin/dll
		warning "You must set PYTHONHOME in your environment to ${PYTHONHOME}"
		export PYTHONPATH=${local_builds}/destdir/${host}/bin/pylib
		warning "You must set PYTHONPATH in your environment to ${PYTHONPATH}"
		;;
            *)
		build $i
                build_all_ret=$?
                ;;
        esac
        #if test $? -gt 0; then
        if test ${build_all_ret} -gt 0; then
            error "Failed building $i."
            return 1
        fi
    done

    # Notify that the build completed successfully
    build_success

    return 0
}

check_all()
{
    local test_packages="${1}"

    # If we're building a full toolchain the binutils tests need to be built
    # with the stage 2 compiler, and therefore we shouldn't run unit-test
    # until the full toolchain is built.  Therefore we test all toolchain
    # packages after the full toolchain is built. 
    if test x"${test_packages}" != x; then
	notice "Testing components ${test_packages}..."
	local check_ret=0
	local check_failed=

	is_package_in_runtests "${test_packages}" newlib
	if test $? -eq 0; then
	    make_check newlib
	    if test $? -ne 0; then
		check_ret=1
		check_failed="${check_failed} newlib"
	    fi
	fi

	is_package_in_runtests "${test_packages}" binutils
	if test $? -eq 0; then
	    make_check binutils
	    if test $? -ne 0; then
		check_ret=1
		check_failed="${check_failed} binutils"
	    fi
	fi

	is_package_in_runtests "${test_packages}" gcc
	if test $? -eq 0; then
	    make_check gcc stage2
	    if test $? -ne 0; then
		check_ret=1
		check_failed="${check_failed} gcc-stage2"
	    fi
	fi

	is_package_in_runtests "${test_packages}" gdb
	if test $? -eq 0; then
	    make_check gdb
	    if test $? -ne 0; then
		check_ret=1
		check_failed="${check_failed} gdb"
	    fi
	fi

	# Only perform unit tests on [e]glibc when we're building native.
        if test x"${target}" = x"${build}"; then
	    # TODO: Get glibc make check working 'native'
	    is_package_in_runtests "${test_packages}" glibc
	    if test $? -eq 0; then
		#make_check ${glibc_version}
		#if test $? -ne 0; then
		#check_ret=1
	        #check_failed="${check_failed} glibc"
		#fi
		notice "make check on native glibc is not yet implemented."
	    fi

	    is_package_in_runtests "${test_packages}" eglibc
	    if test $? -eq 0; then
		#make_check ${eglibc_version}
		#if test $? -ne 0; then
		#check_ret=1
	        #check_failed="${check_failed} eglibc"
		#fi
		notice "make check on native eglibc is not yet implemented."
	    fi
	fi

	if test ${check_ret} -ne 0; then
	    error "Failed checking of ${check_failed}."
	    return 1
	fi
    fi

    # Notify that the test run completed successfully
    test_success

    return 0
}


do_tarsrc()
{
    # TODO: put the error handling in, or remove the tarsrc feature.
    # this isn't as bad as it looks, because we will catch errors from
    # dryrun'd commands at the end of the build.
    notice "do_tarsrc has no error handling"
    if test "$(echo ${with_packages} | grep -c toolchain)" -gt 0; then
	release_binutils_src
	release_gcc_src
    fi
    if test "$(echo ${with_packages} | grep -c gdb)" -gt 0; then
        release_gdb_src
    fi
}

do_tarbin()
{
    # TODO: put the error handling in
    # this isn't as bad as it looks, because we will catch errors from
    # dryrun'd commands at the end of the build.
    notice "do_tarbin has no error handling"
    # Delete any previous release files
    # First delete the symbolic links first, so we don't delete the
    # actual files
    dryrun "rm -fr ${local_builds}/linaro.*/*-tmp ${local_builds}/linaro.*/runtime*"
    dryrun "rm -f ${local_builds}/linaro.*/*"
    # delete temp files from making the release
    dryrun "rm -fr ${local_builds}/linaro.*"

    if test x"${clibrary}" != x"newlib"; then
	binary_runtime
    fi

    binary_toolchain
    binary_sysroot

#    if test "$(echo ${with_packages} | grep -c gdb)" -gt 0; then
#	binary_gdb
#    fi
    notice "Packaging took ${SECONDS} seconds"
    
    return 0
}

build()
{
#    trace "$*"

    local component=$1
 
    if test "$(echo $2 | grep -c gdb)" -gt 0; then
	local component="$2"
    fi
    local url="$(get_component_url ${component})"
    local srcdir="$(get_component_srcdir ${component})"
    local builddir="$(get_component_builddir ${component})${2:+-$2}"

    if [ x"${srcdir}" = x"" ]; then
	# Somehow this component hasn't been set up correctly.
	error "Component '${component}' has no srcdir defined."
        return 1
    fi

    local version="$(basename ${srcdir})"
    local stamp=
    stamp="$(get_stamp_name build ${version} ${2:+$2})"

    # The stamp is in the buildir's parent directory.
    local stampdir="$(dirname ${builddir})"

    notice "Building ${component} ${2:+$2}"

    # We don't need to build if the srcdir has not changed!  We check the
    # build stamp against the timestamp of the srcdir.
    local ret=
    check_stamp "${stampdir}" ${stamp} ${srcdir} build ${force}
    ret=$?
    if test $ret -eq 0; then
	return 0
    elif test $ret -eq 255; then
        # Don't proceed if the srcdir isn't present.  What's the point?
        error "no source dir for the stamp!"
        return 1
   fi

    if test x"${building}" != xno; then
	notice "Configuring ${component} ${2:+$2}"
	configure_build ${component} ${2:+$2}
	if test $? -gt 0; then
            error "Configure of $1 failed!"
            return $?
	fi
	
	# Clean the build directories when forced
	if test x"${force}" = xyes; then
            make_clean ${component} ${2:+$2}
            if test $? -gt 0; then
		return 1
            fi
	fi
	
	# Finally compile and install the libaries
	make_all ${component} ${2:+$2}
	if test $? -gt 0; then
            return 1
	fi
	
	# Build the documentation, unless it has been disabled at the command line.
	if test x"${make_docs}" = xyes; then
            make_docs ${component} ${2:+$2}
            if test $? -gt 0; then
		return 1
            fi
	else
            notice "Skipping make docs as requested (check host.conf)."
	fi
	
	# Install, unless it has been disabled at the command line.
	if test x"${install}" = xyes; then
            make_install ${component} ${2:+$2}
            if test $? -gt 0; then
		return 1
            fi
	else
            notice "Skipping make install as requested (check host.conf)."
	fi
	
	create_stamp "${stampdir}" "${stamp}"
	
	local tag="$(create_release_tag ${component})"
	notice "Done building ${tag}${2:+ $2}, took ${SECONDS} seconds"
	
	# For cross testing, we need to build a C library with our freshly built
	# compiler, so any tests that get executed on the target can be fully linked.
    fi

    return 0
}

make_all()
{
#    trace "$*"

    local component=$1

    # Linux isn't a build project, we only need the headers via the existing
    # Makefile, so there is nothing to compile.
    if test x"${component}" = x"linux"; then
        return 0
    fi

    local builddir="$(get_component_builddir ${component})${2:+-$2}"
    notice "Making all in ${builddir}"

    if test x"${parallel}" = x"yes" -a "$(echo ${component} | grep -c glibc)" -eq 0; then
	local make_flags="${make_flags} -j ${cpus}"
    fi

    # Enable an errata fix for aarch64 that effects the linker
    if test "$(echo ${component} | grep -c glibc)" -gt 0 -a $(echo ${target} | grep -c aarch64) -gt 0; then
	local make_flags="${make_flags} LDFLAGS=\"-Wl,--fix-cortex-a53-843419\" "
    fi

    if test "$(echo ${target} | grep -c aarch64)" -gt 0; then
	local make_flags="${make_flags} LDFLAGS_FOR_TARGET=\"-Wl,-fix-cortex-a53-843419\" "
    fi

    # Use pipes instead of /tmp for temporary files.
    if test x"${override_cflags}" != x -a x"${component}" != x"eglibc"; then
	local make_flags="${make_flags} CFLAGS_FOR_BUILD=\"-pipe -g -O2\" CFLAGS=\"${override_cflags}\" CXXFLAGS=\"${override_cflags}\" CXXFLAGS_FOR_BUILD=\"-pipe -g -O2\""
    else
	local make_flags="${make_flags} CFLAGS_FOR_BUILD=\"-pipe -g -O2\" CXXFLAGS_FOR_BUILD=\"-pipe -g -O2\""
    fi

    if test x"${override_ldflags}" != x; then
        local make_flags="${make_flags} LDFLAGS=\"${override_ldflags}\""
    fi

    # All tarballs are statically linked
    local make_flags="${make_flags} LDFLAGS_FOR_BUILD=\"-static-libgcc\" -C ${builddir}"

    # Some components require extra flags to make: we put them at the
    # end so that config files can override
    local default_makeflags="$(get_component_makeflags ${component})"

    if test x"${default_makeflags}" !=  x; then
        local make_flags="${make_flags} ${default_makeflags}"
    fi

    if test x"${CONFIG_SHELL}" = x; then
        export CONFIG_SHELL=${bash_shell}
    fi

    if test x"${make_docs}" != xyes; then
        local make_flags="${make_flags} BUILD_INFO=\"\" MAKEINFO=echo"
    fi
    local makeret=
    # GDB and Binutils share the same top level files, so we have to explicitly build
    # one or the other, or we get duplicates.
    local logfile="${builddir}/make-${component}${2:+-$2}.log"
    record_artifact "log_make_${component}${2:+-$2}" "${logfile}"
    dryrun "make SHELL=${bash_shell} -w -C ${builddir} ${make_flags} 2>&1 | tee ${logfile}"
    local makeret=$?
    
#    local errors="$(dryrun \"egrep '[Ff]atal error:|configure: error:|Error' ${logfile}\")"
#    if test x"${errors}" != x -a ${makeret} -gt 0; then
#       if test "$(echo ${errors} | egrep -c "ignored")" -eq 0; then
#           error "Couldn't build ${tool}: ${errors}"
#           exit 1
#       fi
#    fi

    # Make sure the make.log file is in place before grepping or the -gt
    # statement is ill formed.  There is not make.log in a dryrun.
#    if test -e "${builddir}/make-${tool}.log"; then
#       if test $(grep -c "configure-target-libgcc.*ERROR" ${logfile}) -gt 0; then
#           error "libgcc wouldn't compile! Usually this means you don't have a sysroot installed!"
#       fi
#    fi
    if test ${makeret} -gt 0; then
        warning "Make had failures!"
        return 1
    fi

    return 0
}

# Print path to dynamic linker in sysroot
# $1 -- sysroot path
# $2 -- whether dynamic linker is expected to exist
find_dynamic_linker()
{
    local sysroots="$1"
    local strict="$2"
    local dynamic_linker c_library_version

    # Programmatically determine the embedded glibc version number for
    # this version of the clibrary.
    if test -x "${sysroots}/usr/bin/ldd"; then
	c_library_version="$(${sysroots}/usr/bin/ldd --version | head -n 1 | sed -e "s/.* //")"
	dynamic_linker="$(find ${sysroots} -type f -name ld-${c_library_version}.so)"
    fi
    if $strict && [ -z "$dynamic_linker" ]; then
        error "Couldn't find dynamic linker ld-${c_library_version}.so in ${sysroots}"
        exit 1
    fi
    echo "$dynamic_linker"
}

make_install()
{
#    trace "$*"

    local component=$1

    # Do not use -j for 'make install' because several build systems
    # suffer from race conditions. For instance in GCC, several
    # multilibs can install header files in the same destination at
    # the same time, leading to conflicts at file creation time.
    if echo "$makeflags" | grep -q -e "-j"; then
	warning "Make install flags contain -j: this may fail because of a race condition!"
    fi

    if test x"${component}" = x"linux"; then
        local srcdir="$(get_component_srcdir ${component}) ${2:+$2}"
	local ARCH=
	case ${target} in
	    *aarch64*)
		ARCH=arm64
		;;
	    *i?86*)
		ARCH=i386
		;;
	    *x86_64*)
		ARCH=x86_64
		;;
	    *arm*)
		ARCH=arm
		;;
	    *powerpc*|*ppc*)
		ARCH=powerpc
		;;
	    *)
		error "Unknown arch for make headers_install!"
		return 1
	esac
        dryrun "make ${make_opts} -C ${srcdir} headers_install ARCH=${ARCH} INSTALL_HDR_PATH=${sysroots}/usr"
        if test $? != "0"; then
            error "Make headers_install failed!"
            return 1
        fi
        return 0
    fi


    local builddir="$(get_component_builddir ${component})${2:+-$2}"
    notice "Making install in ${builddir}"

    if test "$(echo ${component} | grep -c glibc)" -gt 0; then
        local make_flags=" install_root=${sysroots} ${make_flags} LDFLAGS=-static-libgcc"
    fi

    if test x"${override_ldflags}" != x; then
        local make_flags="${make_flags} LDFLAGS=\"${override_ldflags}\""
    fi

    # NOTE: $make_flags is dropped, so the headers and libraries get
    # installed in the right place in our non-multilib'd sysroot.
    if test x"${component}" = x"newlib"; then
        # as newlib supports multilibs, we force the install directory to build
        # a single sysroot for now. FIXME: we should not disable multilibs!
        local make_flags=" tooldir=${sysroots}/usr/"
        if test x"$2" = x"libgloss"; then
            local make_flags="${make_flags}"
        fi
    fi

    if test x"${make_docs}" != xyes; then
	export BUILD_INFO=""
    fi

    # Don't stop on CONFIG_SHELL if it's set in the environment.
    if test x"${CONFIG_SHELL}" = x; then
        export CONFIG_SHELL=${bash_shell}
    fi

    local default_makeflags= #"$(get_component_makeflags ${component})"
    local install_log="$(dirname ${builddir})/install-${component}${2:+-$2}.log"
    record_artifact "log_install_${component}${2:+-$2}" "${install_log}"
    if test x"${component}" = x"gdb" ; then
        dryrun "make install-gdb ${make_flags} ${default_makeflags} -w -C ${builddir} 2>&1 | tee ${install_log}"
    else
	dryrun "make install ${make_flags} ${default_makeflags} -w -C ${builddir} 2>&1 | tee ${install_log}"
    fi
    if test $? != "0"; then
        warning "Make install failed!"
        return 1
    fi

    # Copy libs only when building a toolchain where build=host,
    # otherwise we can't execute ${target}-gcc. In case of a canadian
    # cross build, the libs have already been installed when building
    # the first cross-compiler.
    if test x"${component}" = x"gcc" \
	-a x"$2" = "xstage2" \
	-a "$(echo ${host} | grep -c mingw)" -eq 0; then
	dryrun "copy_gcc_libs_to_sysroot \"${local_builds}/destdir/${host}/bin/${target}-gcc --sysroot=${sysroots}\""
	if test $? != "0"; then
            error "Copy of gcc libs to sysroot failed!"
            return 1
	fi
    fi

    return 0
}

# $1 - The component to test
# $2 - If set to anything, installed tools are used'
make_check()
{
#    trace "$*"

    local component=$1
    local builddir="$(get_component_builddir ${component})${2:+-$2}"

    if [ x"${builddir}" = x"" ]; then
	# Somehow this component hasn't been set up correctly.
	error "Component '${component}' has no builddir defined."
        return 1
    fi

    # Some tests cause problems, so don't run them all unless
    # --enable alltests is specified at runtime.
    local ignore="dejagnu gmp mpc mpfr make eglibc linux gdbserver"
    for i in ${ignore}; do
        if test x"${component}" = x$i -a x"${alltests}" != xyes; then
            return 0
        fi
    done
    notice "Making check in ${builddir}"

    # Use pipes instead of /tmp for temporary files.
    if test x"${override_cflags}" != x -a x"$2" != x"stage2"; then
        local make_flags="${make_flags} CFLAGS_FOR_BUILD=\"${override_cflags}\" CXXFLAGS_FOR_BUILD=\"${override_cflags}\""
    else
        local make_flags="${make_flags} CFLAGS_FOR_BUILD=-\"-pipe\" CXXFLAGS_FOR_BUILD=\"-pipe\""
    fi

    if test x"${override_ldflags}" != x; then
        local make_flags="${make_flags} LDFLAGS_FOR_BUILD=\"${override_ldflags}\""
    fi

    local runtestflags="$(get_component_runtestflags ${component})"
    if test x"${runtestflags}" != x; then
        local make_flags="${make_flags} RUNTESTFLAGS=\"${runtestflags}\""
    fi
    if test x"${override_runtestflags}" != x; then
        local make_flags="${make_flags} RUNTESTFLAGS=\"${override_runtestflags}\""
    fi

    if test x"${parallel}" = x"yes"; then
	local make_flags
	case "${target}" in
	    "$build"|*"-elf"*|armeb*) make_flags="${make_flags} -j ${cpus}" ;;
	    # Double parallelization when running tests on remote boards
	    # to avoid host idling when waiting for the board.
	    *) make_flags="${make_flags} -j $((2*${cpus}))" ;;
	esac
    fi

    # load the config file for Linaro build farms
    export DEJAGNU=${topdir}/config/linaro.exp

    # Run tests
    local checklog="${builddir}/check-${component}.log"
    record_artifact "log_check_${component}" "${checklog}"
    if test x"${build}" = x"${target}"; then
	# Overwrite ${checklog} in order to provide a clean log file
	# if make check has been run more than once on a build tree.
	dryrun "make check RUNTESTFLAGS=\"${runtest_flags} --xml=${component}.xml \" ${make_flags} -w -i -k -C ${builddir} 2>&1 | tee ${checklog}"
        local result=$?
        record_test_results "${component}" $2
	if test $result -gt 0; then
	    error "make check -C ${builddir} failed."
	    return 1
	fi
    else
	local exec_tests
	exec_tests=false
	case "$component" in
	    gcc) exec_tests=true ;;
	    binutils) exec_tests=true ;;
	    # Support testing remote gdb for the merged binutils-gdb.git
	    # where the branch name DOES indicate the tool.
	    gdb)
		exec_tests=true
		;;
	esac

	# Declare schroot_make_opts.  Its value will be set in
	# start_schroot_sessions depending on features that target board[s]
	# support.
	eval "schroot_make_opts="

	# Export SCHROOT_TEST so that we can choose correct boards
	# in config/linaro.exp
	export SCHROOT_TEST="$schroot_test"

	if $exec_tests && [ x"$schroot_test" = x"yes" ]; then
	    # Start schroot sessions on target boards that support it
	    start_schroot_sessions "${target}" "${sysroots}" "${builddir}"
	    if test $? -ne 0; then
		return 1
	    fi
	fi

	case ${component} in
	    binutils)
		local dirs="/binutils /ld /gas"
		local check_targets="check-DEJAGNU"
		;;
	    gdb)
		local dirs="/"
		local check_targets="check-gdb"
		;;
	    newlib)
		# We need a special case for newlib, to bypass its
		# multi-do Makefile targets that do not properly
		# propagate multilib flags. This means that we call
		# runtest only once for newlib.
		local dirs="/${target}/newlib"
		local check_targets="check-DEJAGNU"
		;;
	    *)
		local dirs="/"
		local check_targets="check"
		;;
	esac
	if test x"${component}" = x"gcc" -a x"${clibrary}" != "newlib"; then
            touch ${sysroots}/etc/ld.so.cache
            chmod 700 ${sysroots}/etc/ld.so.cache
	fi

	# Remove existing logs so that rerunning make check results
	# in a clean log.
	if test -e ${checklog}; then
	    # This might or might not be called, depending on whether make_clean
	    # is called before make_check.  None-the-less it's better to be safe.
	    notice "Removing existing check-${component}.log: ${checklog}"
	    rm ${checklog}
	fi

	for i in ${dirs}; do
	    # Always append "tee -a" to the log when building components individually
            dryrun "make ${check_targets} SYSROOT_UNDER_TEST=${sysroots} FLAGS_UNDER_TEST=\"\" PREFIX_UNDER_TEST=\"${local_builds}/destdir/${host}/bin/${target}-\" RUNTESTFLAGS=\"${runtest_flags}\" ${schroot_make_opts} ${make_flags} -w -i -k -C ${builddir}$i 2>&1 | tee -a ${checklog}"
            local result=$?
            record_test_results "${component}" $2
	    if test $result -gt 0; then
		error "make ${check_targets} -C ${builddir}$i failed."
		return 1
	    fi
	done

	# Stop schroot sessions
	stop_schroot_sessions
	unset SCHROOT_TEST
       
        if test x"${component}" = x"gcc"; then
            rm -rf ${sysroots}/etc/ld.so.cache
	fi
    fi

    return 0
}

make_clean()
{
#    trace "$*"

    builddir="$(get_component_builddir $1 ${2:+$2})"
    notice "Making clean in ${builddir}"

    if test x"$2" = "dist"; then
        dryrun "make distclean ${make_flags} -w -C ${builddir}"
    else
        dryrun "make clean ${make_flags} -w -C ${builddir}"
    fi
    if test $? != "0"; then
        warning "Make clean failed!"
        #return 1
    fi

    return 0
}

make_docs()
{
#    trace "$*"

    local component=$1
    local builddir="$(get_component_builddir ${component})${2:+-$2}"

    notice "Making docs in ${builddir}"

    case $1 in
        *binutils*)
            # the diststuff target isn't supported by all the subdirectories,
            # so we build both all targets and ignore the error.
            record_artifact "log_makedoc_${component}${2:+-$2}" "${builddir}/makedoc.log"
	    for subdir in bfd gas gold gprof ld
	    do
		# Some configurations want to disable some of the
		# components (eg gold), so ${build}/${subdir} may not
		# exist. Skip them in this case.
		if [ -d ${builddir}/${subdir} ]; then
		    dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir}/${subdir} diststuff install-man 2>&1 | tee -a ${builddir}/makedoc.log"
		    if test $? -ne 0; then
			error "make docs failed in ${subdir}"
			return 1;
		    fi
		fi
	    done
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir} install-html install-info 2>&1 | tee -a ${builddir}/makedoc.log"
	    if test $? -ne 0; then
		error "make docs failed"
		return 1;
	    fi
            return 0
            ;;
        *gdbserver)
            return 0
            ;;
        *gdb)
	    record_artifact "log_makedoc_${component}${2:+-$2}" "${builddir}/makedoc.log"
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir}/gdb diststuff install-html install-info 2>&1 | tee -a ${builddir}/makedoc.log"
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir}/gdb/doc install-man 2>&1 | tee -a ${builddir}/makedoc.log"
            return $?
            ;;
        *gcc*)
	    record_artifact "log_makedoc_${component}${2:+-$2}" "${builddir}/makedoc.log"
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir} install-html install-info 2>&1 | tee -a ${builddir}/makedoc.log"
            return $?
            ;;
        *linux*|*dejagnu*|*gmp*|*mpc*|*mpfr*|*newlib*|*make*)
            # the regular make install handles all the docs.
            ;;
        glibc|eglibc)
	    record_artifact "log_makedoc_${component}${2:+-$2}" "${builddir}/makedoc.log"
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir} info html 2>&1 | tee -a ${builddir}/makedoc.log"
            return $?
            ;;
        *)
	    record_artifact "log_makedoc_${component}${2:+-$2}" "${builddir}/makedoc.log"
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir} info man 2>&1 | tee -a ${builddir}/makedoc.log"
            return $?
            ;;
    esac

    return 0
}

# See if we can link a simple executable
hello_world()
{
#    trace "$*"

    if test ! -e /tmp/hello.cpp; then
    # Create the usual Hello World! test case
    cat <<EOF > /tmp/hello.cpp
#include <iostream>
int
main(int argc, char *argv[])
{
    std::cout << "Hello World!" << std::endl; 
}
EOF
    fi

    # Make sure we have C flags we need to link successfully
    local extra_cflags=
    case "${clibrary}/${target}" in
        newlib/arm*) extra_cflags="-mcpu=cortex-a8"
          ;;
        newlib/aarch64*) extra_cflags="--specs=rdimon.specs"
          ;;
        newlib/*)
          notice "Hello world test not supported for newlib on ${target}"
          return 0
          ;;
    esac

    # See if a test case compiles to a fully linked executable.
    if test x"${build}" != x"${target}"; then
        dryrun "${target}-g++ ${extra_cflags} -o /tmp/hi /tmp/hello.cpp"
        if test -e /tmp/hi; then
            rm -f /tmp/hi
        else
            return 1
        fi
    fi

    return 0
}

# TODO: Should copy_gcc_libs_to_sysroot() use the input parameter in $1?
# $1 - compiler (and any compiler flags) to query multilib information
copy_gcc_libs_to_sysroot()
{
    local libgcc
    local ldso
    local gcc_lib_path
    local sysroot_lib_dir

    ldso="$(find_dynamic_linker "${sysroots}" false)"
    if ! test -z "${ldso}"; then
	libgcc="libgcc_s.so"
    else
	libgcc="libgcc.a"
    fi

    # Make sure the compiler built before trying to use it
    if test ! -e ${local_builds}/destdir/${host}/bin/${target}-gcc; then
	error "${target}-gcc doesn't exist!"
	return 1
    fi
    libgcc="$(${local_builds}/destdir/${host}/bin/${target}-gcc -print-file-name=${libgcc})"
    if test x"${libgcc}" = xlibgcc.so -o x"${libgcc}" = xlibgcc_s.so; then
	error "GCC doesn't exist!"
	return 1
    fi
    gcc_lib_path="$(dirname "${libgcc}")"
    if ! test -z "${ldso}"; then
	sysroot_lib_dir="$(dirname ${ldso})"
    else
	sysroot_lib_dir="${sysroots}/usr/lib"
    fi

    rsync -a ${gcc_lib_path}/ ${sysroot_lib_dir}/
}

# helper function for record_test_results(). Records .sum files as artifacts
# for components which use dejagnu for testing.
record_sum_files()
{
    local component=$1
    local builddir="$(get_component_builddir ${component})${2:+-$2}"

    local findargs=
    case "${component}" in
       gdb)
           # skip partial .sum files in gdb results
           findargs="-name *.sum -not -path */gdb/testsuite/outputs/*"
           ;;
       *)
           findargs="-name *.sum"
           ;;
    esac
         

    local time=$SECONDS
    # files/directories could have any weird chars in, so take care to
    # escape them correctly
    local i
    for i in $(find "${builddir}" ${findargs} -exec bash -c 'printf "$@"' bash '%q\n' {} ';' ); do
	record_artifact "dj_sum_${component}${2:+-$2}" "${i}"
    done
    notice "Finding artifacts took $((SECONDS-time)) seconds"
}

# record_test_results() is used to record the artifacts generated by
# make check.
record_test_results()
{
    local component=$1
    local subcomponent=$2

    # no point in incurring the cost of $(find) if we don't need the
    # results.
    if [ "${list_artifacts:+set}" != "set" -o x"${dryrun}" = xyes ]; then
        notice "Skipping search for test results."
        return 0
    fi

    case "${component}" in
        binutils|gcc|gdb|newlib)
            # components which use dejagnu for testing, and generate .sum
            # files during make check. It is assumed that the location of .log
            # files can be derived by the consumer of the artifacts list.
            record_sum_files "${component}" ${subcomponent}
            ;;
        *)
            # this component doesn't have test results (yet?)
            return 0
            ;;
    esac
    return 0
}
