AC_INIT([onedrive],[2.2.1], [https://github.com/abraunegg/onedrive], [onedrive])
AC_CONFIG_SRCDIR([Makefile.in])
AM_INIT_AUTOMAKE
AC_PREREQ(2.6)
# AC_CONFIG_MACRO_DIR([m4])
# AC_CONFIG_AUX_DIR([build-aux])

AC_ARG_PROGRAM
AC_PROG_INSTALL

AC_ARG_WITH(gdc,
   [AS_HELP_STRING([--with-gdc=<cmd>],
      [specify the GDC compiler @<:@default: gdc@:>@])],
   gdc=$withval,gdc=gdc)
AC_ARG_WITH(dmd,
   [AS_HELP_STRING([--with-dmd=<cmd>],
      [specify the GCL compiler @<:@default: dmd@:>@])],
   dmd=$withval,dmd=dmd)

AC_PATH_PROG(gdc_path,$gdc)
AC_PATH_PROG(dmd_path,$dmd)

# AC_PROG_MAKE_SET
# AC_PROG_MKDIR_P

AC_ARG_WITH(dc,
   [AS_HELP_STRING([--with-dc=<dmd|gdc>],
      [specify the D compiler to be used. By default if "dmd" is available it is used, otherwise "gdc".])],
        dc=$withval)


if test "x$dc" = "xdmd"
then
	if test -z "$dmd_path"
	then
		AC_MSG_ERROR([selected D compiler dmd not available])
	fi
elif test "x$dc" = "xgdc"
then
	if test -z "$gdc_path"
	then
		AC_MSG_ERROR([selected D compiler gcc not available])
	fi
elif test "x$dc" = "x" 
then
	# no DC specified, select one by default
	if   test -n "$dmd_path" ; then dc="$dmd_path" ; 
	elif test -n "$gdc_path" ; then dc="$gdc_path" ;
	else
		AC_MSG_ERROR([no supported D compiler found])
	fi
else
	AC_MSG_ERROR([unsupported D compiler $dc])
fi

AC_MSG_NOTICE([Using D compiler: $dc])

# check for necessary libraris

PKG_CHECK_MODULES(curl,libcurl)
PKG_CHECK_MODULES(sqlite,sqlite3)
AC_SUBST(curl_LIBS)
AC_SUBST(sqlite_LIBS)


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
	PKG_CHECK_MODULES(notify,libnotify)
	AC_SUBST(notify_LIBS)
fi




AC_SUBST(enable_notifications)
AC_SUBST(dc)
AC_SUBST(dmd_path)
AC_SUBST(gdc_path)

AC_CONFIG_FILES([
  Makefile
])
AC_OUTPUT()
