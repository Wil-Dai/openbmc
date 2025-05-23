#
# Copyright OpenEmbedded Contributors
#
# SPDX-License-Identifier: MIT
#

def get_autotools_dep(d):
    if d.getVar('INHIBIT_AUTOTOOLS_DEPS'):
        return ''

    pn = d.getVar('PN')
    deps = ''

    if pn in ['autoconf-native', 'automake-native']:
        return deps
    deps += 'autoconf-native automake-native '

    if not pn in ['libtool', 'libtool-native'] and not pn.endswith("libtool-cross"):
        deps += 'libtool-native '
        if not bb.data.inherits_class('native', d) \
                        and not bb.data.inherits_class('nativesdk', d) \
                        and not bb.data.inherits_class('cross', d) \
                        and not d.getVar('INHIBIT_DEFAULT_DEPS'):
            deps += 'libtool-cross '

    return deps


DEPENDS:prepend = "${@get_autotools_dep(d)} "

inherit siteinfo

# Space separated list of shell scripts with variables defined to supply test
# results for autoconf tests we cannot run at build time.
# The value of this variable is filled in in a prefunc because it depends on
# the contents of the sysroot.
export CONFIG_SITE

acpaths ?= "default"
EXTRA_AUTORECONF += "--exclude=autopoint"

export lt_cv_sys_lib_dlsearch_path_spec = "${libdir} ${base_libdir}"

# When building tools for use at build-time it's recommended for the build
# system to use these variables when cross-compiling.
# https://www.gnu.org/software/autoconf-archive/ax_prog_cc_for_build.html
# https://stackoverflow.com/questions/24201260/autotools-cross-compilation-and-generated-sources/24208587#24208587
export CPP_FOR_BUILD = "${BUILD_CPP}"
export CPPFLAGS_FOR_BUILD = "${BUILD_CPPFLAGS}"

export CC_FOR_BUILD = "${BUILD_CC}"
export CFLAGS_FOR_BUILD = "${BUILD_CFLAGS}"

export CXX_FOR_BUILD = "${BUILD_CXX}"
export CXXFLAGS_FOR_BUILD = "${BUILD_CXXFLAGS}"

export LD_FOR_BUILD = "${BUILD_LD}"
export LDFLAGS_FOR_BUILD = "${BUILD_LDFLAGS}"

CONFIGUREOPTS = " --build=${BUILD_SYS} \
		  --host=${HOST_SYS} \
		  --target=${TARGET_SYS} \
		  --prefix=${prefix} \
		  --exec_prefix=${exec_prefix} \
		  --bindir=${bindir} \
		  --sbindir=${sbindir} \
		  --libexecdir=${libexecdir} \
		  --datadir=${datadir} \
		  --sysconfdir=${sysconfdir} \
		  --sharedstatedir=${sharedstatedir} \
		  --localstatedir=${localstatedir} \
		  --libdir=${libdir} \
		  --includedir=${includedir} \
		  --oldincludedir=${includedir} \
		  --infodir=${infodir} \
		  --mandir=${mandir} \
		  --disable-silent-rules \
		  ${CONFIGUREOPT_DEPTRACK}"
CONFIGUREOPT_DEPTRACK ?= "--disable-dependency-tracking"

CACHED_CONFIGUREVARS ?= ""

AUTOTOOLS_SCRIPT_PATH ?= "${S}"
CONFIGURE_SCRIPT ?= "${AUTOTOOLS_SCRIPT_PATH}/configure"

AUTOTOOLS_AUXDIR ?= "${AUTOTOOLS_SCRIPT_PATH}"

oe_runconf () {
	# Use relative path to avoid buildpaths in files
	cfgscript_name="`basename ${CONFIGURE_SCRIPT}`"
	cfgscript=`python3 -c "import os; print(os.path.relpath(os.path.dirname('${CONFIGURE_SCRIPT}'), '.'))"`/$cfgscript_name
	if [ -x "$cfgscript" ] ; then
		bbnote "Running $cfgscript ${CONFIGUREOPTS} ${EXTRA_OECONF} $@"
		if ! CONFIG_SHELL=${CONFIG_SHELL-/bin/bash} ${CACHED_CONFIGUREVARS} $cfgscript ${CONFIGUREOPTS} ${EXTRA_OECONF} "$@"; then
			bbnote "The following config.log files may provide further information."
			bbnote `find ${B} -ignore_readdir_race -type f -name config.log`
			bbfatal_log "configure failed"
		fi
	else
		bbfatal "no configure script found at $cfgscript"
	fi
}

CONFIGURESTAMPFILE = "${WORKDIR}/configure.sstate"

autotools_preconfigure() {
	if [ -n "${CONFIGURESTAMPFILE}" -a -e "${CONFIGURESTAMPFILE}" ]; then
		if [ "`cat ${CONFIGURESTAMPFILE}`" != "${BB_TASKHASH}" ]; then
			if [ "${S}" != "${B}" ]; then
				echo "Previously configured separate build directory detected, cleaning ${B}"
				rm -rf ${B}
				mkdir -p ${B}
			else
				# At least remove the .la files since automake won't automatically
				# regenerate them even if CFLAGS/LDFLAGS are different
				cd ${S}
				if [ "${CLEANBROKEN}" != "1" -a \( -e Makefile -o -e makefile -o -e GNUmakefile \) ]; then
					oe_runmake clean
				fi
				find ${S} -ignore_readdir_race -name \*.la -delete
			fi
		fi
	fi
}

autotools_postconfigure(){
	if [ -n "${CONFIGURESTAMPFILE}" ]; then
		mkdir -p `dirname ${CONFIGURESTAMPFILE}`
		echo ${BB_TASKHASH} > ${CONFIGURESTAMPFILE}
	fi
}

EXTRACONFFUNCS ??= ""

EXTRA_OECONF:append = " ${PACKAGECONFIG_CONFARGS}"

do_configure[prefuncs] += "autotools_preconfigure autotools_sitefiles ${EXTRACONFFUNCS}"
do_configure[postfuncs] += "autotools_postconfigure"

# Tell autoconf to load the site defaults from siteinfo
python autotools_sitefiles () {
    sitefiles, searched = siteinfo_get_files(d, sysrootcache=True)
    d.setVar("CONFIG_SITE", " ".join(sitefiles))
}

do_configure[file-checksums] += "${@' '.join(siteinfo_get_files(d, sysrootcache=False)[1])}"

CONFIGURE_FILES = "${S}/configure.in ${S}/configure.ac ${S}/config.h.in *.m4 Makefile.am"

autotools_do_configure() {
	# WARNING: gross hack follows:
	# An autotools built package generally needs these scripts, however only
	# automake or libtoolize actually install the current versions of them.
	# This is a problem in builds that do not use libtool or automake, in the case
	# where we -need- the latest version of these scripts.  e.g. running a build
	# for a package whose autotools are old, on an x86_64 machine, which the old
	# config.sub does not support.  Work around this by installing them manually
	# regardless.

	PRUNE_M4=""

	for ac in `find ${S} -ignore_readdir_race -name configure.in -o -name configure.ac`; do
		rm -f `dirname $ac`/configure
	done
	if [ -e ${AUTOTOOLS_SCRIPT_PATH}/configure.in -o -e ${AUTOTOOLS_SCRIPT_PATH}/configure.ac ]; then
		olddir=`pwd`
		cd ${AUTOTOOLS_SCRIPT_PATH}
		# aclocal looks in the native sysroot by default, so tell it to also look in the target sysroot.
		ACLOCAL="aclocal --aclocal-path=${STAGING_DATADIR}/aclocal/"
		if [ x"${acpaths}" = xdefault ]; then
			acpaths=
			for i in `find ${AUTOTOOLS_SCRIPT_PATH} -ignore_readdir_race -maxdepth 2 -name \*.m4|grep -v 'aclocal.m4'| \
				grep -v 'acinclude.m4' | sed -e 's,\(.*/\).*$,\1,'|sort -u`; do
				acpaths="$acpaths -I $i"
			done
		else
			acpaths="${acpaths}"
		fi
		# autoreconf is too shy to overwrite aclocal.m4 if it doesn't look
		# like it was auto-generated.  Work around this by blowing it away
		# by hand, unless the package specifically asked not to run aclocal.
		if ! echo ${EXTRA_AUTORECONF} | grep -q "aclocal"; then
			bbnote Removing existing aclocal.m4
			rm -f aclocal.m4
		fi
		if [ -e configure.in ]; then
			CONFIGURE_AC=configure.in
		else
			CONFIGURE_AC=configure.ac
		fi
		if grep -q "^[[:space:]]*AM_GLIB_GNU_GETTEXT" $CONFIGURE_AC; then
			if grep -q "sed.*POTFILES" $CONFIGURE_AC; then
				: do nothing -- we still have an old unmodified configure.ac
	    		else
				bbnote Executing glib-gettextize --force --copy
				echo "no" | glib-gettextize --force --copy
			fi
		elif [ "${BPN}" != "gettext" ] && grep -q "^[[:space:]]*AM_GNU_GETTEXT" $CONFIGURE_AC; then
			# We'd call gettextize here if it wasn't so broken...
			cp ${STAGING_DATADIR_NATIVE}/gettext/config.rpath ${AUTOTOOLS_AUXDIR}/
			if [ -d ${S}/po/ ]; then
				cp -f ${STAGING_DATADIR_NATIVE}/gettext/po/Makefile.in.in ${S}/po/
				if [ ! -e ${S}/po/remove-potcdate.sed ]; then
					cp ${STAGING_DATADIR_NATIVE}/gettext/po/remove-potcdate.sed ${S}/po/
				fi
			fi
			PRUNE_M4="$PRUNE_M4 gettext.m4 iconv.m4 lib-ld.m4 lib-link.m4 lib-prefix.m4 nls.m4 po.m4 progtest.m4"
		fi
		mkdir -p m4

		for i in $PRUNE_M4; do
			find ${S} -ignore_readdir_race -name $i -delete
		done

		bbnote Executing ACLOCAL=\"$ACLOCAL\" autoreconf -Wcross --verbose --install --force ${EXTRA_AUTORECONF} $acpaths
		ACLOCAL="$ACLOCAL" autoreconf -Wcross -Wno-obsolete --verbose --install --force ${EXTRA_AUTORECONF} $acpaths || die "autoreconf execution failed."
		cd $olddir
	fi
	if [ -e ${CONFIGURE_SCRIPT} ]; then
		oe_runconf
	else
		bbnote "nothing to configure"
	fi
}

autotools_do_compile() {
	oe_runmake
}

autotools_do_install() {
	oe_runmake 'DESTDIR=${D}' install
	# Info dir listing isn't interesting at this point so remove it if it exists.
	if [ -e "${D}${infodir}/dir" ]; then
		rm -f ${D}${infodir}/dir
	fi
}

EXPORT_FUNCTIONS do_configure do_compile do_install

B = "${WORKDIR}/build"
