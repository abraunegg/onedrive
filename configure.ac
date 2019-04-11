AC_PREREQ([2.69])
AC_INIT([onedrive],[2.3.2], [https://github.com/abraunegg/onedrive], [onedrive])
AC_CONFIG_SRCDIR([src/main.d])


AC_ARG_VAR([DC], [D compiler executable])
AC_ARG_VAR([DCFLAGS], [flags for D compiler])

AC_PROG_INSTALL
AC_PROG_SED
PKG_PROG_PKG_CONFIG

AC_CHECK_PROGS([DC], [dmd ldmd2 ldc2], NOT_FOUND)
DC_TYPE=
case $(basename $DC) in
	dmd) DC_TYPE=dmd ;;
	ldmd2) DC_TYPE=dmd ;;
	ldc2) DC_TYPE=ldc ;;
	NOT_FOUND) AC_MSG_ERROR(Could not find any compatible D compiler, 1)
esac
AC_SUBST([DC_TYPE])

AC_SUBST([DCFLAGS])

PKG_CHECK_MODULES([curl],[libcurl])
PKG_CHECK_MODULES([sqlite],[sqlite3])

#
# systemd and unit file directories
#
AC_ARG_WITH([systemdsystemunitdir],
     [AS_HELP_STRING([--with-systemdsystemunitdir=DIR], [Directory for systemd system service files])],,
     [with_systemdsystemunitdir=auto])
AS_IF([test "x$with_systemdsystemunitdir" = "xyes" -o "x$with_systemdsystemunitdir" = "xauto"], [
     def_systemdsystemunitdir=$($PKG_CONFIG --variable=systemdsystemunitdir systemd)

     AS_IF([test "x$def_systemdsystemunitdir" = "x"],
   [AS_IF([test "x$with_systemdsystemunitdir" = "xyes"],
    [AC_MSG_ERROR([systemd support requested but pkg-config unable to query systemd package])])
    with_systemdsystemunitdir=no],
   [with_systemdsystemunitdir="$def_systemdsystemunitdir"])])
AS_IF([test "x$with_systemdsystemunitdir" != "xno"],
      [AC_SUBST([systemdsystemunitdir], [$with_systemdsystemunitdir])])

AC_ARG_WITH([systemduserunitdir],
     [AS_HELP_STRING([--with-systemduserunitdir=DIR], [Directory for systemd user service files])],,
     [with_systemduserunitdir=auto])
AS_IF([test "x$with_systemduserunitdir" = "xyes" -o "x$with_systemduserunitdir" = "xauto"], [
     def_systemduserunitdir=$($PKG_CONFIG --variable=systemduserunitdir systemd)

     AS_IF([test "x$def_systemduserunitdir" = "x"],
   [AS_IF([test "x$with_systemduserunitdir" = "xyes"],
    [AC_MSG_ERROR([systemd support requested but pkg-config unable to query systemd package])])
    with_systemduserunitdir=no],
   [with_systemduserunitdir="$def_systemduserunitdir"])])
AS_IF([test "x$with_systemduserunitdir" != "xno"],
      [AC_SUBST([systemduserunitdir], [$with_systemduserunitdir])])

AS_IF([test "x$with_systemduserunitdir" != "xno" -a "x$with_systemdsystemunitdir" != "xno"],
      [havesystemd=yes], [havesystemd=no])
AC_SUBST([HAVE_SYSTEMD], $havesystemd)



#
# Notification support
# only check for libnotify if --enable-notifications is given
AC_ARG_ENABLE(notifications,
       [AS_HELP_STRING([--enable-notifications],
          [Enable desktop notifications via libnotify])],
       enable_notifications=yes,
       enable_notifications=no)
if test "x$enable_notifications" = "xyes"
then
	PKG_CHECK_MODULES(notify,libnotify,,enable_notifications=no)
else
	AC_SUBST([notify_LIBS],"")
fi
AC_SUBST([NOTIFICATIONS],$enable_notifications)

#
# Completion support
# only check for libnotify if --enable-notifications is given
AC_ARG_ENABLE(completions,
       [AS_HELP_STRING([--enable-completions],
          [Install shell completions for bash and zsh])],
       enable_completions=yes,
       enable_completions=no)
AC_SUBST([COMPLETIONS],$enable_completions)


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


#
# Debug support
AC_ARG_ENABLE(debug,
       [AS_HELP_STRING([--enable-debug],
          [Pass debug option to the compiler])],
       enable_debug=yes,
       enable_debug=no)
AC_SUBST([DEBUG],$enable_debug)

AC_CONFIG_FILES([Makefile pacman/PKGBUILD spec/onedrive.spec onedrive.1])
AC_OUTPUT
