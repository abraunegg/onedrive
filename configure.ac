AC_PREREQ([2.69])
AC_INIT([onedrive],[2.2.1], [https://github.com/abraunegg/onedrive], [onedrive])
AC_CONFIG_SRCDIR([src/main.d])


AC_ARG_VAR([DC], [D compiler executable])
AC_ARG_VAR([DCFLAGS], [flags for D compiler])

: ${DCFLAGS='-w -g -O'}
AC_SUBST([DCFLAGS])

AC_PROG_INSTALL
AC_PROG_SED
PKG_PROG_PKG_CONFIG

AC_PATH_PROGS([DC], [dmd ldmd2], NOT_FOUND)
DC_SUFFIX=
case $(basename $DC) in
	dmd) DC_SUFFIX=-dmd ;;
	ldmd2) DC_SUFFIX=-ldc ;;
	NOT_FOUND) AC_MSG_ERROR(Could not find any compatible D compiler, 1)
esac

PKG_CHECK_MODULES([CURL],[libcurl])
PKG_CHECK_MODULES([SQLITE],[sqlite3])

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

AM_CONDITIONAL([HAVE_SYSTEMD], [test "x$with_systemduserunitdir" != "xno" -a "x$with_systemdsystemunitdir" != "xno"])



#
# Notification support
#
AC_ARG_ENABLE(notifications,
       [AS_HELP_STRING([--enable-notifications],
          [Enable desktop notifications via libnotify])],
       [enable_notifications="${enableval}"],
       [enable_notifications=yes])
if test "x$enable_notifications" = "xyes"
then
	PKG_CHECK_MODULES(NOTIFY,libnotify,,enable_notifications=no)
fi
AM_CONDITIONAL([NOTIFICATIONS], [test x$enable_notifications = xyes])

AM_INIT_AUTOMAKE([1.15 foreign])

AC_CONFIG_FILES([Makefile pacman/PKGBUILD spec/onedrive.spec])
AC_OUTPUT
