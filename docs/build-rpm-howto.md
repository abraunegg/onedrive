# RPM Package Build Process
The instructions below have been tested on the following systems:
*   CentOS Stream release 9

These instructions should also be applicable for RedHat & Fedora platforms, or any other RedHat RPM based distribution.

## Prepare Package Development Environment
Install the following dependencies on your build system:
```text
sudo yum groupinstall -y 'Development Tools'
sudo yum install -y libcurl-devel
sudo yum install -y sqlite-devel
sudo yum install -y libnotify-devel
sudo yum install -y wget
sudo yum install -y https://downloads.dlang.org/releases/2.x/2.088.0/dmd-2.088.0-0.fedora.x86_64.rpm
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
```

## Build RPM from spec file
Build the RPM from the provided spec file:
```text
wget https://github.com/abraunegg/onedrive/archive/refs/tags/v2.5.0.tar.gz -O ~/rpmbuild/SOURCES/v2.5.0.tar.gz
#wget https://raw.githubusercontent.com/abraunegg/onedrive/master/contrib/spec/onedrive.spec.in -O ~/rpmbuild/SPECS/onedrive.spec

wget https://raw.githubusercontent.com/abraunegg/onedrive/onedrive-v2.5.0-release-candidate-3/contrib/spec/onedrive.spec.in -O ~/rpmbuild/SPECS/onedrive.spec
rpmbuild -ba ~/rpmbuild/SPECS/onedrive.spec
```

## RPM Build Example Results
Below are example output results of building, installing and running the RPM package on the respective platforms:

### CentOS Stream release 9 RPM Build Process
```text
[alex@centos9stream ~]$ rpmbuild -ba ~/rpmbuild/SPECS/onedrive.spec
Executing(%prep): /bin/sh -e /var/tmp/rpm-tmp.V7l9aO
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd /home/alex/rpmbuild/BUILD
+ rm -rf onedrive-2.5.0
+ /usr/bin/tar -xof -
+ /usr/bin/gzip -dc /home/alex/rpmbuild/SOURCES/v2.5.0.tar.gz
+ STATUS=0
+ '[' 0 -ne 0 ']'
+ cd onedrive-2.5.0
+ /usr/bin/chmod -Rf a+rX,u+w,g-w,o-w .
+ RPM_EC=0
++ jobs -p
+ exit 0
Executing(%build): /bin/sh -e /var/tmp/rpm-tmp.x8hFro
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.5.0
+ CFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64-v2 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection'
+ export CFLAGS
+ CXXFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64-v2 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection'
+ export CXXFLAGS
+ FFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64-v2 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -I/usr/lib64/gfortran/modules'
+ export FFLAGS
+ FCFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64-v2 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -I/usr/lib64/gfortran/modules'
+ export FCFLAGS
+ LDFLAGS='-Wl,-z,relro -Wl,--as-needed  -Wl,-z,now -specs=/usr/lib/rpm/redhat/redhat-hardened-ld -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 '
+ export LDFLAGS
+ LT_SYS_LIBRARY_PATH=/usr/lib64:
+ export LT_SYS_LIBRARY_PATH
+ CC=gcc
+ export CC
+ CXX=g++
+ export CXX
+ '[' '-flto=auto -ffat-lto-objectsx' '!=' x ']'
++ find . -type f -name configure -print
+ for file in $(find . -type f -name configure -print)
+ /usr/bin/sed -r --in-place=.backup 's/^char \(\*f\) \(\) = /__attribute__ ((used)) char (*f) () = /g' ./configure
+ diff -u ./configure.backup ./configure
+ mv ./configure.backup ./configure
+ /usr/bin/sed -r --in-place=.backup 's/^char \(\*f\) \(\);/__attribute__ ((used)) char (*f) ();/g' ./configure
+ diff -u ./configure.backup ./configure
+ mv ./configure.backup ./configure
+ /usr/bin/sed -r --in-place=.backup 's/^char \$2 \(\);/__attribute__ ((used)) char \$2 ();/g' ./configure
+ diff -u ./configure.backup ./configure
+ mv ./configure.backup ./configure
+ /usr/bin/sed --in-place=.backup '1{$!N;$!N};$!N;s/int x = 1;\nint y = 0;\nint z;\nint nan;/volatile int x = 1; volatile int y = 0; volatile int z, nan;/;P;D' ./configure
+ diff -u ./configure.backup ./configure
+ mv ./configure.backup ./configure
+ /usr/bin/sed --in-place=.backup 's#^lt_cv_sys_global_symbol_to_cdecl=.*#lt_cv_sys_global_symbol_to_cdecl="sed -n -e '\''s/^T .* \\(.*\\)$/extern int \\1();/p'\'' -e '\''s/^$symcode* .* \\(.*\\)$/extern char \\1;/p'\''"#' ./configure
+ diff -u ./configure.backup ./configure
+ mv ./configure.backup ./configure
+ '[' 1 = 1 ']'
+++ dirname ./configure
++ find . -name config.guess -o -name config.sub
+ '[' 1 = 1 ']'
+ '[' x '!=' 'x-Wl,-z,now -specs=/usr/lib/rpm/redhat/redhat-hardened-ld' ']'
++ find . -name ltmain.sh
+ ./configure --build=x86_64-redhat-linux-gnu --host=x86_64-redhat-linux-gnu --program-prefix= --disable-dependency-tracking --prefix=/usr --exec-prefix=/usr --bindir=/usr/bin --sbindir=/usr/sbin --sysconfdir=/etc --datadir=/usr/share --includedir=/usr/include --libdir=/usr/lib64 --libexecdir=/usr/libexec --localstatedir=/var --sharedstatedir=/var/lib --mandir=/usr/share/man --infodir=/usr/share/info --enable-debug --enable-notifications
configure: WARNING: unrecognized options: --disable-dependency-tracking
checking for a BSD-compatible install... /usr/bin/install -c
checking for x86_64-redhat-linux-gnu-pkg-config... /usr/bin/x86_64-redhat-linux-gnu-pkg-config
checking pkg-config is at least version 0.9.0... yes
checking for dmd... dmd
checking version of D compiler... 2.088.0
checking for curl... yes
checking for sqlite... yes
checking for notify... yes
configure: creating ./config.status
config.status: creating Makefile
config.status: creating contrib/pacman/PKGBUILD
config.status: creating contrib/spec/onedrive.spec
config.status: creating onedrive.1
config.status: creating contrib/systemd/onedrive.service
config.status: creating contrib/systemd/onedrive@.service
configure: WARNING: unrecognized options: --disable-dependency-tracking
+ make
if [ -f .git/HEAD ] ; then \
        git describe --tags > version ; \
else \
        echo v2.5.0 > version ; \
fi
dmd -w -J. -g -debug -gs -version=NoPragma -version=NoGdk -version=Notifications -L-lcurl -L-lsqlite3 -L-lnotify -L-lgdk_pixbuf-2.0 -L-lgio-2.0 -L-lgobject-2.0 -L-lglib-2.0 -L-ldl src/main.d src/config.d src/log.d src/util.d src/qxor.d src/curlEngine.d src/onedrive.d src/webhook.d src/sync.d src/itemdb.d src/sqlite.d src/clientSideFiltering.d src/monitor.d src/arsd/cgi.d src/notifications/notify.d src/notifications/dnotify.d -ofonedrive
+ RPM_EC=0
++ jobs -p
+ exit 0
Executing(%install): /bin/sh -e /var/tmp/rpm-tmp.Oj0XhN
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ '[' /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64 '!=' / ']'
+ rm -rf /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64
++ dirname /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64
+ mkdir -p /home/alex/rpmbuild/BUILDROOT
+ mkdir /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64
+ cd onedrive-2.5.0
+ /usr/bin/make install DESTDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64 'INSTALL=/usr/bin/install -p' PREFIX=/home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64
/usr/bin/install -p -D onedrive /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/bin/onedrive
/usr/bin/install -p -D -m 0644 onedrive.1 /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/share/man/man1/onedrive.1
/usr/bin/install -p -D -m 0644 contrib/logrotate/onedrive.logrotate /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/etc/logrotate.d/onedrive
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/share/doc/onedrive
/usr/bin/install -p -D -m 0644 readme.md config LICENSE changelog.md docs/advanced-usage.md docs/application-config-options.md docs/application-security.md docs/business-shared-items.md docs/client-architecture.md docs/contributing.md docs/docker.md docs/install.md docs/national-cloud-deployments.md docs/podman.md docs/privacy-policy.md docs/sharepoint-libraries.md docs/terms-of-service.md docs/ubuntu-package-install.md docs/usage.md docs/known-issues.md  /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/share/doc/onedrive
/usr/bin/install -p -d -m 0755 /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/lib/systemd/user /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/lib/systemd/system
/usr/bin/install -p -m 0644 contrib/systemd/onedrive@.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/lib/systemd/system
/usr/bin/install -p -m 0644 contrib/systemd/onedrive.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/lib/systemd/system
+ /usr/lib/rpm/check-buildroot
+ /usr/lib/rpm/redhat/brp-ldconfig
+ /usr/lib/rpm/brp-compress
+ /usr/lib/rpm/brp-strip /usr/bin/strip
+ /usr/lib/rpm/brp-strip-comment-note /usr/bin/strip /usr/bin/objdump
+ /usr/lib/rpm/redhat/brp-strip-lto /usr/bin/strip
+ /usr/lib/rpm/brp-strip-static-archive /usr/bin/strip
+ /usr/lib/rpm/redhat/brp-python-bytecompile '' 1 0
+ /usr/lib/rpm/brp-python-hardlink
+ /usr/lib/rpm/redhat/brp-mangle-shebangs
Processing files: onedrive-2.5.0-1.el9.x86_64
Executing(%doc): /bin/sh -e /var/tmp/rpm-tmp.vy1y65
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.5.0
+ DOCDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/share/doc/onedrive
+ export LC_ALL=C
+ LC_ALL=C
+ export DOCDIR
+ /usr/bin/mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/share/doc/onedrive
+ cp -pr readme.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/share/doc/onedrive
+ cp -pr LICENSE /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/share/doc/onedrive
+ cp -pr changelog.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64/usr/share/doc/onedrive
+ RPM_EC=0
++ jobs -p
+ exit 0
warning: File listed twice: /usr/share/doc/onedrive
warning: File listed twice: /usr/share/doc/onedrive/LICENSE
warning: File listed twice: /usr/share/doc/onedrive/changelog.md
warning: File listed twice: /usr/share/doc/onedrive/readme.md
Provides: config(onedrive) = 2.5.0-1.el9 onedrive = 2.5.0-1.el9 onedrive(x86-64) = 2.5.0-1.el9
Requires(rpmlib): rpmlib(CompressedFileNames) <= 3.0.4-1 rpmlib(FileDigests) <= 4.6.0-1 rpmlib(PayloadFilesHavePrefix) <= 4.0-1
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Requires: ld-linux-x86-64.so.2()(64bit) ld-linux-x86-64.so.2(GLIBC_2.3)(64bit) libc.so.6()(64bit) libc.so.6(GLIBC_2.14)(64bit) libc.so.6(GLIBC_2.15)(64bit) libc.so.6(GLIBC_2.17)(64bit) libc.so.6(GLIBC_2.2.5)(64bit) libc.so.6(GLIBC_2.3.2)(64bit) libc.so.6(GLIBC_2.3.4)(64bit) libc.so.6(GLIBC_2.32)(64bit) libc.so.6(GLIBC_2.33)(64bit) libc.so.6(GLIBC_2.34)(64bit) libc.so.6(GLIBC_2.4)(64bit) libc.so.6(GLIBC_2.6)(64bit) libc.so.6(GLIBC_2.7)(64bit) libc.so.6(GLIBC_2.8)(64bit) libc.so.6(GLIBC_2.9)(64bit) libcurl.so.4()(64bit) libgcc_s.so.1()(64bit) libgcc_s.so.1(GCC_3.0)(64bit) libgcc_s.so.1(GCC_4.2.0)(64bit) libgdk_pixbuf-2.0.so.0()(64bit) libgio-2.0.so.0()(64bit) libglib-2.0.so.0()(64bit) libgobject-2.0.so.0()(64bit) libm.so.6()(64bit) libm.so.6(GLIBC_2.2.5)(64bit) libnotify.so.4()(64bit) libsqlite3.so.0()(64bit) rtld(GNU_HASH)
Checking for unpackaged file(s): /usr/lib/rpm/check-files /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.0-1.el9.x86_64
Wrote: /home/alex/rpmbuild/SRPMS/onedrive-2.5.0-1.el9.src.rpm
Wrote: /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.5.0-1.el9.x86_64.rpm
Executing(%clean): /bin/sh -e /var/tmp/rpm-tmp.pM33Kl
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.5.0
+ RPM_EC=0
++ jobs -p
+ exit 0
```

### CentOS Stream release 9 RPM Package Install Process
```text
[alex@centos9stream ~]$ sudo yum -y install /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.5.0-1.el9.x86_64.rpm
[sudo] password for alex: 
Last metadata expiration check: 0:33:14 ago on Mon 19 Aug 2024 17:22:48.
Dependencies resolved.
===============================================================================================================================================================================================
 Package                                     Architecture                              Version                                           Repository                                       Size
===============================================================================================================================================================================================
Installing:
 onedrive                                    x86_64                                    2.5.0-1.el9                                       @commandline                                    1.5 M

Transaction Summary
===============================================================================================================================================================================================
Install  1 Package

Total size: 1.5 M
Installed size: 7.6 M
Downloading Packages:
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                                                                                                       1/1 
  Installing       : onedrive-2.5.0-1.el9.x86_64                                                                                                                                           1/1 
  Running scriptlet: onedrive-2.5.0-1.el9.x86_64                                                                                                                                           1/1 
  Verifying        : onedrive-2.5.0-1.el9.x86_64                                                                                                                                           1/1 

Installed:
  onedrive-2.5.0-1.el9.x86_64                                                                                                                                                                  

Complete!
[alex@centos9stream ~]$ onedrive --version
onedrive v2.5.0
[alex@centos9stream ~]$ onedrive --display-config
WARNING: D-Bus message bus daemon is not available; GUI notifications are disabled
Application version                          = onedrive v2.5.0
Compiled with                                = DMD 2088
User Application Config path                 = /home/alex/.config/onedrive
System Application Config path               = /etc/onedrive
Applicable Application 'config' location     = /home/alex/.config/onedrive/config
Configuration file found in config location  = false - using application defaults
Applicable 'sync_list' location              = /home/alex/.config/onedrive/sync_list
Applicable 'items.sqlite3' location          = /home/alex/.config/onedrive/items.sqlite3
Config option 'drive_id'                     = 
Config option 'sync_dir'                     = ~/OneDrive
Config option 'enable_logging'               = false
Config option 'log_dir'                      = /var/log/onedrive
Config option 'disable_notifications'        = false
Config option 'skip_dir'                     = 
Config option 'skip_dir_strict_match'        = false
Config option 'skip_file'                    = ~*|.~*|*.tmp|*.swp|*.partial
Config option 'skip_dotfiles'                = false
Config option 'skip_symlinks'                = false
Config option 'monitor_interval'             = 300
Config option 'monitor_log_frequency'        = 12
Config option 'monitor_fullscan_frequency'   = 12
Config option 'read_only_auth_scope'         = false
Config option 'dry_run'                      = false
Config option 'upload_only'                  = false
Config option 'download_only'                = false
Config option 'local_first'                  = false
Config option 'check_nosync'                 = false
Config option 'check_nomount'                = false
Config option 'resync'                       = false
Config option 'resync_auth'                  = false
Config option 'cleanup_local_files'          = false
Config option 'classify_as_big_delete'       = 1000
Config option 'disable_upload_validation'    = false
Config option 'disable_download_validation'  = false
Config option 'bypass_data_preservation'     = false
Config option 'no_remote_delete'             = false
Config option 'remove_source_files'          = false
Config option 'sync_dir_permissions'         = 700
Config option 'sync_file_permissions'        = 600
Config option 'space_reservation'            = 52428800
Config option 'application_id'               = d50ca740-c83f-4d1b-b616-12c519384f0c
Config option 'azure_ad_endpoint'            = 
Config option 'azure_tenant_id'              = 
Config option 'user_agent'                   = ISV|abraunegg|OneDrive Client for Linux/v2.5.0
Config option 'force_http_11'                = false
Config option 'debug_https'                  = false
Config option 'rate_limit'                   = 0
Config option 'operation_timeout'            = 3600
Config option 'dns_timeout'                  = 60
Config option 'connect_timeout'              = 10
Config option 'data_timeout'                 = 60
Config option 'ip_protocol_version'          = 0
Config option 'threads'                      = 8
Environment var 'XDG_RUNTIME_DIR'            = true
Environment var 'DBUS_SESSION_BUS_ADDRESS'   = true

Selective sync 'sync_list' configured        = false

Config option 'sync_business_shared_items'   = false

Config option 'webhook_enabled'              = false
```