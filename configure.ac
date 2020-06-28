dnl configure.ac for OneDrive Linux Client
dnl Copyright 2019 Norbert Preining
dnl Licensed GPL v3 or later

dnl How to make a release
dnl - increase the version number in the AC_INIT call below
dnl - run autoconf which generates configure
dnl - commit the changed files (configure.ac, configure)
dnl - tag the release

AC_PREREQ([2.69])
AC_INIT([onedrive],[v2.4.4-dev], [https://github.com/abraunegg/onedrive], [onedrive])
AC_CONFIG_SRCDIR([src/main.d])


AC_ARG_VAR([DC], [D compiler executable])
AC_ARG_VAR([DCFLAGS], [flags for D compiler])

dnl necessary programs: install, pkg-config
AC_PROG_INSTALL
PKG_PROG_PKG_CONFIG

dnl Determine D compiler
dnl we check for dmd, dmd2, and ldc2 in this order
dnl furthermore, we set DC_TYPE to either dmd or ldc and export this into the
dnl Makefile so that we can adjust command line arguments
AC_CHECK_PROGS([DC], [dmd ldmd2 ldc2], NOT_FOUND)
DC_TYPE=
case $(basename $DC) in
        dmd) DC_TYPE=dmd ;;
        ldmd2) DC_TYPE=dmd ;;
        ldc2) DC_TYPE=ldc ;;
        NOT_FOUND) AC_MSG_ERROR(Could not find any compatible D compiler, 1)
esac

dnl dash/POSIX version of version comparison
vercomp () {
    IFS=. read -r a0 a1 a2 aa <<EOF
$1
EOF
    IFS=. read -r b0 b1 b2 bb <<EOF
$2
EOF
    # leading 0 are ignored: 01 == 1, this also
    # converts empty strings into 0: 1..2 == 1.0.2
    a0=$(expr $a0 + 0)
    a1=$(expr $a1 + 0)
    a2=$(expr $a2 + 0)
    b0=$(expr $b0 + 0)
    b1=$(expr $b1 + 0)
    b2=$(expr $b2 + 0)
    #echo "$1 parsed to a=$a0 b=$a1 c=$a2 rest=$aa"
    #echo "$2 parsed to a=$b0 b=$b1 c=$b2 rest=$bb"
    if test $a0 -lt $b0 
    then
      return 2
    elif test $a0 -gt $b0 
    then
      return 1
    else
      if test $a1 -lt $b1
      then
        return 2
      elif test $a1 -gt $b1
      then
        return 1
      else
        if test $a2 -lt $b2
	then
	  return 2
	elif test $a2 -gt $b2
	then
	  return 1
	else
	  if test $aa '<' $bb
	  then
	    return 2
	  elif test $aa '>' $bb
	  then
	    return 1
          else
	    return 0
	  fi
	fi
      fi
    fi
}

DO_VERSION_CHECK=1
AC_ARG_ENABLE(version-check,
  AS_HELP_STRING([--disable-version-check], [Disable checks of compiler version during configure time]))
AS_IF([test "x$enable_version_check" = "xno"], DO_VERSION_CHECK=0,)

AS_IF([test "$DO_VERSION_CHECK" = "1"],
      [ dnl do the version check
AC_MSG_CHECKING([version of D compiler])
# check for valid versions
case $(basename $DC) in
	ldmd2|ldc2)
		# LDC - the LLVM D compiler (1.12.0): ...
		VERSION=`$DC --version`
		# remove  everything up to first (
		VERSION=${VERSION#* (}
		# remove everthing after ):
		VERSION=${VERSION%%):*}
		# now version should be something like L.M.N
		MINVERSION=1.12.0
		;;
	dmd)
		# DMD64 D Compiler v2.085.1\n...
		VERSION=`$DC --version | tr '\n' ' '`
		VERSION=${VERSION#*Compiler v}
		VERSION=${VERSION%% *}
		# now version should be something like L.M.N
		MINVERSION=2.083.1
		;;
esac

AC_MSG_RESULT([$VERSION])

vercomp $MINVERSION $VERSION
if test $? = 1
then
	AC_MSG_ERROR([Compiler version insufficient, current compiler version $VERSION, minimum version $MINVERSION], 1)
fi
#echo "MINVERSION=$MINVERSION VERSION=$VERSION"
      ])



AC_SUBST([DC_TYPE])
dnl In case the environment variable DCFLAGS is set, we export it to the
dnl generated Makefile at configure run:
AC_SUBST([DCFLAGS])

dnl The package date is only used in the man page onedrive.1.in
dnl we generate onedrive.1 from it during configure run, but we want
dnl to have the same date, namely the one when the configure script
dnl was generated from the configure.ac (i.e., on release time).
dnl this uses a call to the underlying m4 engine to call an external cmd
PACKAGE_DATE="m4_esyscmd([date "+%B %Y" | tr -d '\n'])" 
AC_SUBST([PACKAGE_DATE])

dnl Check for required modules: curl and sqlite at the moment
PKG_CHECK_MODULES([curl],[libcurl])
PKG_CHECK_MODULES([sqlite],[sqlite3])

dnl
dnl systemd and unit file directories
dnl This is a bit tricky, because we want to allow for 
dnl   --with-systemdsystemunitdir=auto
dnl as well as =/path/to/dir
dnl The first step is that we check whether the --with options is passed to configure run
dnl if yes, we don't do anything (the ,, at the end of the next line), and if not, we
dnl set with_systemdsystemunitdir=auto, meaning we will try pkg-config to find the correct
dnl value.
AC_ARG_WITH([systemdsystemunitdir],
     [AS_HELP_STRING([--with-systemdsystemunitdir=DIR], [Directory for systemd system service files])],,
     [with_systemdsystemunitdir=auto])
dnl If no value is passed in (or auto/yes is passed in), then we try to find the correct
dnl value via pkg-config and put it into $def_systemdsystemunitdir
AS_IF([test "x$with_systemdsystemunitdir" = "xyes" -o "x$with_systemdsystemunitdir" = "xauto"],
      [ dnl true part, so try to determine with pkg-config
        def_systemdsystemunitdir=$($PKG_CONFIG --variable=systemdsystemunitdir systemd)
        dnl if we cannot find it via pkg-config, *and* the user explicitely passed it in with,
        dnl we warn, and in all cases we unset (set to no) the respective variable
        AS_IF([test "x$def_systemdsystemunitdir" = "x"],
              [  dnl we couldn't find the default value via pkg-config
                AS_IF([test "x$with_systemdsystemunitdir" = "xyes"],
                      [AC_MSG_ERROR([systemd support requested but pkg-config unable to query systemd package])])
                with_systemdsystemunitdir=no
              ],
              [ dnl pkg-config found the value, use it
                with_systemdsystemunitdir="$def_systemdsystemunitdir"
              ]
        )
      ]
)
dnl finally, if we found a value, put it into the generated Makefile
AS_IF([test "x$with_systemdsystemunitdir" != "xno"],
      [AC_SUBST([systemdsystemunitdir], [$with_systemdsystemunitdir])])

dnl Now do the same as above for systemduserunitdir!
AC_ARG_WITH([systemduserunitdir],
     [AS_HELP_STRING([--with-systemduserunitdir=DIR], [Directory for systemd user service files])],,
     [with_systemduserunitdir=auto])
AS_IF([test "x$with_systemduserunitdir" = "xyes" -o "x$with_systemduserunitdir" = "xauto"],
      [
        def_systemduserunitdir=$($PKG_CONFIG --variable=systemduserunitdir systemd)
        AS_IF([test "x$def_systemduserunitdir" = "x"],
              [
                AS_IF([test "x$with_systemduserunitdir" = "xyes"],
                      [AC_MSG_ERROR([systemd support requested but pkg-config unable to query systemd package])])
                with_systemduserunitdir=no
              ],
              [
                with_systemduserunitdir="$def_systemduserunitdir"
              ]
        )
      ]
)
AS_IF([test "x$with_systemduserunitdir" != "xno"],
      [AC_SUBST([systemduserunitdir], [$with_systemduserunitdir])])

dnl We enable systemd integration only if we have found both user/system unit dirs
AS_IF([test "x$with_systemduserunitdir" != "xno" -a "x$with_systemdsystemunitdir" != "xno"],
      [havesystemd=yes], [havesystemd=no])
AC_SUBST([HAVE_SYSTEMD], $havesystemd)



dnl
dnl Notification support
dnl only check for libnotify if --enable-notifications is given
AC_ARG_ENABLE(notifications,
  AS_HELP_STRING([--enable-notifications], [Enable desktop notifications via libnotify]))

AS_IF([test "x$enable_notifications" = "xyes"], [enable_notifications=yes], [enable_notifications=no])

dnl if --enable-notifications was given, check for libnotify, and disable if not found
dnl otherwise substitute the notifu
AS_IF([test "x$enable_notifications" = "xyes"],
      [PKG_CHECK_MODULES(notify,libnotify,,enable_notifications=no)],
      [AC_SUBST([notify_LIBS],"")])
AC_SUBST([NOTIFICATIONS],$enable_notifications)

dnl
dnl Completion support
dnl First determine whether completions are requested, pass that to Makefile
AC_ARG_ENABLE([completions],
  AS_HELP_STRING([--enable-completions], [Install shell completions for bash and zsh]))

AS_IF([test "x$enable_completions" = "xyes"], [enable_completions=yes], [enable_completions=no])

AC_SUBST([COMPLETIONS],$enable_completions)


dnl if completions are enabled, search for the bash/zsh completion directory in the
dnl similar way as we did for the systemd directories
AS_IF([test "x$enable_completions" = "xyes"],[
  AC_ARG_WITH([bash-completion-dir],
              [AS_HELP_STRING([--with-bash-completion-dir=DIR], [Directory for bash completion files])],
              ,
              [with_bash_completion_dir=auto])
  AS_IF([test "x$with_bash_completion_dir" = "xyes" -o "x$with_bash_completion_dir" = "xauto"], 
    [
      PKG_CHECK_VAR(bashcompdir, [bash-completion], [completionsdir], ,
                    bashcompdir="${sysconfdir}/bash_completion.d")
      with_bash_completion_dir=$bashcompdir
    ])
  AC_SUBST([BASH_COMPLETION_DIR], $with_bash_completion_dir)

  AC_ARG_WITH([zsh-completion-dir],
              [AS_HELP_STRING([--with-zsh-completion-dir=DIR], [Directory for zsh completion files])],,
              [with_zsh_completion_dir=auto])
  AS_IF([test "x$with_zsh_completion_dir" = "xyes" -o "x$with_zsh_completion_dir" = "xauto"], 
    [
      with_zsh_completion_dir="/usr/local/share/zsh/site-functions"
    ])
  AC_SUBST([ZSH_COMPLETION_DIR], $with_zsh_completion_dir)
  ])

dnl
dnl Debug support
AC_ARG_ENABLE(debug,
  AS_HELP_STRING([--enable-debug], [Pass debug option to the compiler]))
AS_IF([test "x$enable_debug" = "xyes"], AC_SUBST([DEBUG],yes), AC_SUBST([DEBUG],no))

dnl generate necessary files
AC_CONFIG_FILES([
		 Makefile
		 contrib/pacman/PKGBUILD
		 contrib/spec/onedrive.spec
		 onedrive.1
		 contrib/systemd/onedrive.service
		 contrib/systemd/onedrive@.service
		])
AC_OUTPUT
