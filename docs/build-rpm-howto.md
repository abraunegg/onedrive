# RPM Package Build Process
The instructions below have been tested on the following systems:
*   CentOS Stream release 9

These instructions should also be applicable for RedHat & Fedora platforms, or any other RedHat RPM based distribution.

## Prepare Package Development Environment

### Install Development Dependencies
Install the following dependencies on your build system:
```text
sudo yum groupinstall -y 'Development Tools'
sudo yum install -y libcurl-devel
sudo yum install -y sqlite-devel
sudo yum install -y libnotify-devel
sudo yum install -y dbus-devel
sudo yum install -y wget
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
```

### Install DMD Compiler for Linux
Install the latest DMD Compiler for Linux from https://dlang.org/download.html using the Fedora/CentOS x86_64 link.

Illustrated below is the installation using the minimum supported compiler. You should always install the latest version of the compiler for your platform when manually building an RPM.
```text
sudo yum install -y https://downloads.dlang.org/releases/2.x/2.091.1/dmd-2.091.1-0.fedora.x86_64.rpm
```

## Build RPM from spec file using the DMD Compiler
Build the RPM from the provided spec file:
```text
wget https://github.com/abraunegg/onedrive/archive/refs/tags/v2.5.6.tar.gz -O ~/rpmbuild/SOURCES/v2.5.6.tar.gz
wget https://raw.githubusercontent.com/abraunegg/onedrive/master/contrib/spec/onedrive.spec.in -O ~/rpmbuild/SPECS/onedrive.spec
rpmbuild -ba ~/rpmbuild/SPECS/onedrive.spec --define 'dcompiler dmd'
```

### RPM Build Example Results
Below are example output results of building, installing and running the RPM package on the respective platforms:

#### CentOS Stream release 9 RPM Build Process
```text
setting SOURCE_DATE_EPOCH=1749081600
Executing(%prep): /bin/sh -e /var/tmp/rpm-tmp.ZhVuOR
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd /home/alex/rpmbuild/BUILD
+ rm -rf onedrive-2.5.6
+ /usr/bin/tar -xof -
+ /usr/bin/gzip -dc /home/alex/rpmbuild/SOURCES/v2.5.6.tar.gz
+ STATUS=0
+ '[' 0 -ne 0 ']'
+ cd onedrive-2.5.6
+ /usr/bin/chmod -Rf a+rX,u+w,g-w,o-w .
+ RPM_EC=0
++ jobs -p
+ exit 0
Executing(%build): /bin/sh -e /var/tmp/rpm-tmp.b9tkxJ
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.5.6
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
checking version of D compiler... 2.091.1
checking for curl... yes
checking for sqlite... yes
checking whether to enable dbus support... yes (on Linux)
checking for dbus... yes
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
        echo v2.5.6 > version ; \
fi
dmd -J. -version=NoPragma -version=NoGdk -version=Notifications -w -g -debug -gs src/main.d src/config.d src/log.d src/util.d src/qxor.d src/curlEngine.d src/onedrive.d src/webhook.d src/sync.d src/itemdb.d src/sqlite.d src/clientSideFiltering.d src/monitor.d src/arsd/cgi.d src/xattr.d src/intune.d src/notifications/notify.d src/notifications/dnotify.d -L-lcurl -L-lsqlite3 -L-ldbus-1 -L-lnotify -L-lgdk_pixbuf-2.0 -L-lgio-2.0 -L-lgobject-2.0 -L-lglib-2.0 -L-ldl -ofonedrive
+ RPM_EC=0
++ jobs -p
+ exit 0
Executing(%install): /bin/sh -e /var/tmp/rpm-tmp.Pwy2mS
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ '[' /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64 '!=' / ']'
+ rm -rf /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64
++ dirname /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64
+ mkdir -p /home/alex/rpmbuild/BUILDROOT
+ mkdir /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64
+ cd onedrive-2.5.6
+ /usr/bin/make install DESTDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64 'INSTALL=/usr/bin/install -p' PREFIX=/home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/bin
/usr/bin/install -p onedrive /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/bin/onedrive
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/man/man1
/usr/bin/install -p -m 0644 onedrive.1 /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/man/man1/onedrive.1
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/etc/logrotate.d
/usr/bin/install -p -m 0644 contrib/logrotate/onedrive.logrotate /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/etc/logrotate.d/onedrive
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive
for file in readme.md config LICENSE changelog.md docs/advanced-usage.md docs/application-config-options.md docs/application-security.md docs/business-shared-items.md docs/client-architecture.md docs/contributing.md docs/docker.md docs/install.md docs/national-cloud-deployments.md docs/podman.md docs/privacy-policy.md docs/sharepoint-libraries.md docs/terms-of-service.md docs/ubuntu-package-install.md docs/usage.md docs/known-issues.md docs/webhooks.md; do \
        /usr/bin/install -p -m 0644 $file /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive; \
done
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/lib/systemd/user
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/lib/systemd/system
/usr/bin/install -p -m 0644 contrib/systemd/onedrive@.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/lib/systemd/system
/usr/bin/install -p -m 0644 contrib/systemd/onedrive.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/lib/systemd/system
+ install -D -m 0644 contrib/systemd/onedrive.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/lib/systemd/system/onedrive.service
+ install -D -m 0644 contrib/systemd/onedrive@.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/lib/systemd/system/onedrive@.service
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
Processing files: onedrive-2.5.6-1.el9.x86_64
Executing(%doc): /bin/sh -e /var/tmp/rpm-tmp.2YAn9k
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.5.6
+ DOCDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive
+ export LC_ALL=C
+ LC_ALL=C
+ export DOCDIR
+ /usr/bin/mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive
+ cp -pr readme.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive
+ cp -pr LICENSE /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive
+ cp -pr changelog.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive
+ cp -pr docs/advanced-usage.md docs/application-config-options.md docs/application-security.md docs/build-rpm-howto.md docs/business-shared-items.md docs/client-architecture.md docs/contributing.md docs/docker.md docs/install.md docs/known-issues.md docs/national-cloud-deployments.md docs/podman.md docs/privacy-policy.md docs/sharepoint-libraries.md docs/terms-of-service.md docs/ubuntu-package-install.md docs/usage.md docs/webhooks.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive
+ cp -pr config /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64/usr/share/doc/onedrive
+ RPM_EC=0
++ jobs -p
+ exit 0
Provides: config(onedrive) = 2.5.6-1.el9 onedrive = 2.5.6-1.el9 onedrive(x86-64) = 2.5.6-1.el9
Requires(rpmlib): rpmlib(CompressedFileNames) <= 3.0.4-1 rpmlib(FileDigests) <= 4.6.0-1 rpmlib(PayloadFilesHavePrefix) <= 4.0-1
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Requires: ld-linux-x86-64.so.2()(64bit) ld-linux-x86-64.so.2(GLIBC_2.3)(64bit) libc.so.6()(64bit) libc.so.6(GLIBC_2.14)(64bit) libc.so.6(GLIBC_2.15)(64bit) libc.so.6(GLIBC_2.17)(64bit) libc.so.6(GLIBC_2.2.5)(64bit) libc.so.6(GLIBC_2.3)(64bit) libc.so.6(GLIBC_2.3.2)(64bit) libc.so.6(GLIBC_2.3.4)(64bit) libc.so.6(GLIBC_2.32)(64bit) libc.so.6(GLIBC_2.33)(64bit) libc.so.6(GLIBC_2.34)(64bit) libc.so.6(GLIBC_2.4)(64bit) libc.so.6(GLIBC_2.6)(64bit) libc.so.6(GLIBC_2.7)(64bit) libc.so.6(GLIBC_2.8)(64bit) libc.so.6(GLIBC_2.9)(64bit) libcurl.so.4()(64bit) libdbus-1.so.3()(64bit) libdbus-1.so.3(LIBDBUS_1_3)(64bit) libgcc_s.so.1()(64bit) libgcc_s.so.1(GCC_3.0)(64bit) libgcc_s.so.1(GCC_4.2.0)(64bit) libgdk_pixbuf-2.0.so.0()(64bit) libgio-2.0.so.0()(64bit) libglib-2.0.so.0()(64bit) libgobject-2.0.so.0()(64bit) libm.so.6()(64bit) libm.so.6(GLIBC_2.2.5)(64bit) libnotify.so.4()(64bit) libsqlite3.so.0()(64bit) rtld(GNU_HASH)
Checking for unpackaged file(s): /usr/lib/rpm/check-files /home/alex/rpmbuild/BUILDROOT/onedrive-2.5.6-1.el9.x86_64
Wrote: /home/alex/rpmbuild/SRPMS/onedrive-2.5.6-1.el9.src.rpm
Wrote: /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.5.6-1.el9.x86_64.rpm
Executing(%clean): /bin/sh -e /var/tmp/rpm-tmp.tGKXPN
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.5.6
+ RPM_EC=0
++ jobs -p
+ exit 0
```

#### CentOS Stream release 9 RPM Package Install Process
```text
[alex@centos9stream ~]$ sudo yum -y install /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.5.6-1.el9.x86_64.rpm
[sudo] password for alex: 
Last metadata expiration check: 1:21:53 ago on Tue 10 Jun 2025 06:41:27.
Dependencies resolved.
==========================================================================================================================================================================================
 Package                                    Architecture                             Version                                         Repository                                      Size
==========================================================================================================================================================================================
Installing:
 onedrive                                   x86_64                                   2.5.6-1.el9                                     @commandline                                   1.6 M

Transaction Summary
==========================================================================================================================================================================================
Install  1 Package

Total size: 1.6 M
Installed size: 8.3 M
Downloading Packages:
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                                                                                                  1/1 
  Installing       : onedrive-2.5.6-1.el9.x86_64                                                                                                                                      1/1 
  Running scriptlet: onedrive-2.5.6-1.el9.x86_64                                                                                                                                      1/1 
  Verifying        : onedrive-2.5.6-1.el9.x86_64                                                                                                                                      1/1 

Installed:
  onedrive-2.5.6-1.el9.x86_64                                                                                                                                                             

Complete!
[alex@centos9stream ~]$ 
[alex@centos9stream ~]$ onedrive --version
onedrive v2.5.6
[alex@centos9stream ~]$ onedrive --display-config
WARNING: Configured 'threads = 8' exceeds available CPU cores (1). Capping to 'threads' to 1.
Application version                          = onedrive v2.5.6
Compiled with                                = DMD 2091
Curl version                                 = libcurl/7.76.1 OpenSSL/3.5.0 zlib/1.2.11 brotli/1.0.9 libidn2/2.3.0 libpsl/0.21.1 (+libidn2/2.3.0) libssh/0.10.4/openssl/zlib nghttp2/1.43.0
User Application Config path                 = /home/alex/.config/onedrive
System Application Config path               = /etc/onedrive
Applicable Application 'config' location     = /home/alex/.config/onedrive/config
Configuration file found in config location  = false - using application defaults
Applicable 'sync_list' location              = /home/alex/.config/onedrive/sync_list
Applicable 'items.sqlite3' location          = /home/alex/.config/onedrive/items.sqlite3
Config option 'drive_id'                     = 
Config option 'sync_dir'                     = ~/OneDrive
Config option 'use_intune_sso'               = false
Config option 'use_device_auth'              = false
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
Config option 'disable_permission_set'       = false
Config option 'transfer_order'               = default
Config option 'classify_as_big_delete'       = 1000
Config option 'disable_upload_validation'    = false
Config option 'disable_download_validation'  = false
Config option 'bypass_data_preservation'     = false
Config option 'no_remote_delete'             = false
Config option 'remove_source_files'          = false
Config option 'sync_dir_permissions'         = 700
Config option 'sync_file_permissions'        = 600
Config option 'space_reservation'            = 52428800
Config option 'permanent_delete'             = false
Config option 'write_xattr_data'             = false
Config option 'application_id'               = d50ca740-c83f-4d1b-b616-12c519384f0c
Config option 'azure_ad_endpoint'            = 
Config option 'azure_tenant_id'              = 
Config option 'user_agent'                   = ISV|abraunegg|OneDrive Client for Linux/v2.5.6
Config option 'force_http_11'                = false
Config option 'debug_https'                  = false
Config option 'rate_limit'                   = 0
Config option 'operation_timeout'            = 3600
Config option 'dns_timeout'                  = 60
Config option 'connect_timeout'              = 10
Config option 'data_timeout'                 = 60
Config option 'ip_protocol_version'          = 0
Config option 'threads'                      = 1
Config option 'max_curl_idle'                = 120
Environment var 'XDG_RUNTIME_DIR'            = true
Environment var 'DBUS_SESSION_BUS_ADDRESS'   = true
Config option 'notify_file_actions'          = false
Config option 'use_recycle_bin'              = false
Config option 'recycle_bin_path'             = /home/alex/.local/share/Trash/

Selective sync 'sync_list' configured        = false

Config option 'sync_business_shared_items'   = false

Config option 'webhook_enabled'              = false
```


## Build RPM from SRPM using mock

### Install mock on your platform
Use the following installation instructions to install 'mock' on your platform:
```text
sudo yum install epel-release
sudo yum install mock
sudo yum install -y wget
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
```

### Configure mock
Add your user to the mock group:
```text
sudo usermod -a -G mock $USER
```
> [!NOTE]
> Log out and back in for the group membership changes to take effect.

### Build a Source RPM (SRPM) file
Build the SRPM from the provided spec file:
```text
wget https://github.com/abraunegg/onedrive/archive/refs/tags/v2.5.6.tar.gz -O ~/rpmbuild/SOURCES/v2.5.6.tar.gz
wget https://raw.githubusercontent.com/abraunegg/onedrive/master/contrib/spec/onedrive.spec.in -O ~/rpmbuild/SPECS/onedrive.spec
rpmbuild -bs ~/rpmbuild/SPECS/onedrive.spec
```
> [!NOTE]
> This will build a SRPM to the following location: `/home/alex/rpmbuild/SRPMS/onedrive-2.5.6-1.el9.src.rpm` 
> 
> This SRPM will be used in the examples below:

### Build Fedora 42 RPM using mock

```text
[alex@centos9stream ~]$ mock -r fedora-42-x86_64 /home/alex/rpmbuild/SRPMS/onedrive-2.5.6-1.el9.src.rpm
INFO: mock.py version 6.2 starting (python version = 3.9.21, NVR = mock-6.2-1.el9), args: /usr/libexec/mock/mock -r fedora-42-x86_64 /home/alex/rpmbuild/SRPMS/onedrive-2.5.6-1.el9.src.rpm
Start(bootstrap): init plugins
INFO: selinux enabled
Finish(bootstrap): init plugins
Start: init plugins
INFO: selinux enabled
Finish: init plugins
INFO: Signal handler active
Start: run
INFO: Start(/home/alex/rpmbuild/SRPMS/onedrive-2.5.6-1.el9.src.rpm)  Config(fedora-42-x86_64)
Start: clean chroot
Finish: clean chroot
Mock Version: 6.2
INFO: Mock Version: 6.2
Start(bootstrap): chroot init
INFO: calling preinit hooks
INFO: enabled root cache
INFO: enabled package manager cache
Start(bootstrap): cleaning package manager metadata
Finish(bootstrap): cleaning package manager metadata
INFO: Package manager dnf5 detected and used (fallback)
Finish(bootstrap): chroot init
Start: chroot init
INFO: calling preinit hooks
INFO: enabled root cache
Start: unpacking root cache
Finish: unpacking root cache
INFO: enabled package manager cache
Start: cleaning package manager metadata
Finish: cleaning package manager metadata
INFO: enabled HW Info plugin
INFO: Package manager dnf5 detected and used (direct choice)
INFO: Buildroot is handled by package management downloaded with a bootstrap image:
  rpm-4.20.1-1.fc42.x86_64
  rpm-sequoia-1.7.0-5.fc42.x86_64
  dnf5-5.2.13.1-1.fc42.x86_64
  dnf5-plugins-5.2.13.1-1.fc42.x86_64
Start: dnf5 update
Updating and loading repositories:
 updates                                100% |   5.5 KiB/s |   5.6 KiB |  00m01s
 fedora                                 100% |   5.8 KiB/s |   4.2 KiB |  00m01s
Repositories loaded.
Nothing to do.
Finish: dnf5 update
Finish: chroot init
Start: build phase for onedrive-2.5.6-1.el9.src.rpm
Start: build setup for onedrive-2.5.6-1.el9.src.rpm
Building target platforms: x86_64
Building for target x86_64
setting SOURCE_DATE_EPOCH=1749081600
Wrote: /builddir/build/SRPMS/onedrive-2.5.6-1.fc42.src.rpm
Updating and loading repositories:
 updates                                100% |  16.5 KiB/s |   5.6 KiB |  00m00s
 fedora                                 100% |   8.3 KiB/s |   4.2 KiB |  00m01s
Repositories loaded.
Package               Arch   Version                 Repository      Size
Installing:
 dbus-devel           x86_64 1:1.16.0-3.fc42         fedora     131.7 KiB
 ldc                  x86_64 1:1.40.0-3.fc42         fedora      27.3 MiB
 libcurl-devel        x86_64 8.11.1-4.fc42           fedora       1.3 MiB
 sqlite-devel         x86_64 3.47.2-2.fc42           fedora     673.4 KiB
Installing dependencies:
 annobin-docs         noarch 12.94-1.fc42            updates     98.9 KiB
 annobin-plugin-gcc   x86_64 12.94-1.fc42            updates    993.5 KiB
 brotli               x86_64 1.1.0-6.fc42            fedora      31.6 KiB
 brotli-devel         x86_64 1.1.0-6.fc42            fedora      65.6 KiB
 cmake-filesystem     x86_64 3.31.6-2.fc42           fedora       0.0   B
 cpp                  x86_64 15.1.1-2.fc42           updates     37.9 MiB
 dbus-libs            x86_64 1:1.16.0-3.fc42         fedora     349.5 KiB
 gcc                  x86_64 15.1.1-2.fc42           updates    111.1 MiB
 gcc-plugin-annobin   x86_64 15.1.1-2.fc42           updates     57.1 KiB
 glibc-devel          x86_64 2.41-5.fc42             updates      2.3 MiB
 kernel-headers       x86_64 6.14.3-300.fc42         updates      6.5 MiB
 keyutils-libs-devel  x86_64 1.6.3-5.fc42            fedora      48.2 KiB
 krb5-devel           x86_64 1.21.3-6.fc42           updates    705.9 KiB
 ldc-libs             x86_64 1:1.40.0-3.fc42         fedora      11.6 MiB
 libcom_err-devel     x86_64 1.47.2-3.fc42           fedora      16.7 KiB
 libedit              x86_64 3.1-55.20250104cvs.fc42 fedora     244.1 KiB
 libidn2-devel        x86_64 2.3.8-1.fc42            fedora     149.1 KiB
 libkadm5             x86_64 1.21.3-6.fc42           updates    213.9 KiB
 libmpc               x86_64 1.3.1-7.fc42            fedora     164.5 KiB
 libnghttp2-devel     x86_64 1.64.0-3.fc42           fedora     295.4 KiB
 libpsl-devel         x86_64 0.21.5-5.fc42           fedora     110.3 KiB
 libselinux-devel     x86_64 3.8-2.fc42              updates    126.8 KiB
 libsepol-devel       x86_64 3.8-1.fc42              fedora     120.8 KiB
 libssh-devel         x86_64 0.11.1-4.fc42           fedora     178.0 KiB
 libverto-devel       x86_64 0.3.2-10.fc42           fedora      25.7 KiB
 libxcrypt-devel      x86_64 4.4.38-7.fc42           updates     30.8 KiB
 llvm19-filesystem    x86_64 19.1.7-13.fc42          updates      0.0   B
 llvm19-libs          x86_64 19.1.7-13.fc42          updates    124.0 MiB
 make                 x86_64 1:4.4.1-10.fc42         fedora       1.8 MiB
 openssl-devel        x86_64 1:3.2.4-3.fc42          fedora       4.3 MiB
 pcre2-devel          x86_64 10.45-1.fc42            fedora       2.1 MiB
 pcre2-utf16          x86_64 10.45-1.fc42            fedora     626.3 KiB
 pcre2-utf32          x86_64 10.45-1.fc42            fedora     598.2 KiB
 publicsuffix-list    noarch 20250116-1.fc42         fedora     329.8 KiB
 sqlite               x86_64 3.47.2-2.fc42           fedora       1.8 MiB
 systemd-devel        x86_64 257.6-1.fc42            updates    612.3 KiB
 systemd-rpm-macros   noarch 257.6-1.fc42            updates     10.7 KiB
 xml-common           noarch 0.6.3-66.fc42           fedora      78.4 KiB
 zlib-ng-compat-devel x86_64 2.2.4-3.fc42            fedora     107.0 KiB

Transaction Summary:
 Installing:        43 packages

Total size of inbound packages is 103 MiB. Need to download 0 B.
After this operation, 339 MiB extra will be used (install 339 MiB, remove 0 B).
[ 1/43] ldc-1:1.40.0-3.fc42.x86_64      100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[ 2/43] dbus-devel-1:1.16.0-3.fc42.x86_ 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[ 3/43] libcurl-devel-0:8.11.1-4.fc42.x 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[ 4/43] sqlite-devel-0:3.47.2-2.fc42.x8 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[ 5/43] ldc-libs-1:1.40.0-3.fc42.x86_64 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[ 6/43] cmake-filesystem-0:3.31.6-2.fc4 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[ 7/43] dbus-libs-1:1.16.0-3.fc42.x86_6 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[ 8/43] xml-common-0:0.6.3-66.fc42.noar 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[ 9/43] sqlite-0:3.47.2-2.fc42.x86_64   100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[10/43] krb5-devel-0:1.21.3-6.fc42.x86_ 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[11/43] libkadm5-0:1.21.3-6.fc42.x86_64 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[12/43] brotli-devel-0:1.1.0-6.fc42.x86 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[13/43] brotli-0:1.1.0-6.fc42.x86_64    100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[14/43] libidn2-devel-0:2.3.8-1.fc42.x8 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[15/43] libnghttp2-devel-0:1.64.0-3.fc4 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[16/43] libpsl-devel-0:0.21.5-5.fc42.x8 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[17/43] publicsuffix-list-0:20250116-1. 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[18/43] libssh-devel-0:0.11.1-4.fc42.x8 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[19/43] openssl-devel-1:3.2.4-3.fc42.x8 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[20/43] zlib-ng-compat-devel-0:2.2.4-3. 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[21/43] gcc-0:15.1.1-2.fc42.x86_64      100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[22/43] cpp-0:15.1.1-2.fc42.x86_64      100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[23/43] libmpc-0:1.3.1-7.fc42.x86_64    100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[24/43] make-1:4.4.1-10.fc42.x86_64     100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[25/43] llvm19-libs-0:19.1.7-13.fc42.x8 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[26/43] llvm19-filesystem-0:19.1.7-13.f 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[27/43] libedit-0:3.1-55.20250104cvs.fc 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[28/43] systemd-devel-0:257.6-1.fc42.x8 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[29/43] libselinux-devel-0:3.8-2.fc42.x 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[30/43] libsepol-devel-0:3.8-1.fc42.x86 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[31/43] keyutils-libs-devel-0:1.6.3-5.f 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[32/43] libcom_err-devel-0:1.47.2-3.fc4 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[33/43] libverto-devel-0:0.3.2-10.fc42. 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[34/43] glibc-devel-0:2.41-5.fc42.x86_6 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[35/43] pcre2-devel-0:10.45-1.fc42.x86_ 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[36/43] pcre2-utf16-0:10.45-1.fc42.x86_ 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[37/43] pcre2-utf32-0:10.45-1.fc42.x86_ 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[38/43] kernel-headers-0:6.14.3-300.fc4 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[39/43] libxcrypt-devel-0:4.4.38-7.fc42 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[40/43] gcc-plugin-annobin-0:15.1.1-2.f 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[41/43] systemd-rpm-macros-0:257.6-1.fc 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[42/43] annobin-plugin-gcc-0:12.94-1.fc 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
[43/43] annobin-docs-0:12.94-1.fc42.noa 100% |   0.0   B/s |   0.0   B |  00m00s
>>> Already downloaded                                                          
--------------------------------------------------------------------------------
[43/43] Total                           100% |   0.0   B/s |   0.0   B |  00m00s
Running transaction
[ 1/45] Verify package files            100% |  29.0   B/s |  43.0   B |  00m01s
[ 2/45] Prepare transaction             100% | 154.0   B/s |  43.0   B |  00m00s
[ 3/45] Installing cmake-filesystem-0:3 100% | 583.8 KiB/s |   7.6 KiB |  00m00s
[ 4/45] Installing libmpc-0:1.3.1-7.fc4 100% |  23.2 MiB/s | 166.1 KiB |  00m00s
[ 5/45] Installing cpp-0:15.1.1-2.fc42. 100% | 120.6 MiB/s |  37.9 MiB |  00m00s
[ 6/45] Installing libssh-devel-0:0.11. 100% |  19.6 MiB/s | 180.5 KiB |  00m00s
[ 7/45] Installing zlib-ng-compat-devel 100% |  15.1 MiB/s | 108.5 KiB |  00m00s
[ 8/45] Installing annobin-docs-0:12.94 100% |  10.9 MiB/s | 100.0 KiB |  00m00s
[ 9/45] Installing kernel-headers-0:6.1 100% |  36.6 MiB/s |   6.7 MiB |  00m00s
[10/45] Installing libxcrypt-devel-0:4. 100% |   2.9 MiB/s |  33.1 KiB |  00m00s
[11/45] Installing glibc-devel-0:2.41-5 100% |  15.3 MiB/s |   2.3 MiB |  00m00s
[12/45] Installing pcre2-utf32-0:10.45- 100% |  18.3 MiB/s | 599.1 KiB |  00m00s
[13/45] Installing pcre2-utf16-0:10.45- 100% |  30.6 MiB/s | 627.1 KiB |  00m00s
[14/45] Installing pcre2-devel-0:10.45- 100% |  33.8 MiB/s |   2.1 MiB |  00m00s
[15/45] Installing libverto-devel-0:0.3 100% |   5.1 MiB/s |  26.4 KiB |  00m00s
[16/45] Installing libcom_err-devel-0:1 100% | 761.4 KiB/s |  18.3 KiB |  00m00s
[17/45] Installing keyutils-libs-devel- 100% |   5.4 MiB/s |  55.2 KiB |  00m00s
[18/45] Installing libsepol-devel-0:3.8 100% |   9.6 MiB/s | 128.3 KiB |  00m00s
[19/45] Installing libselinux-devel-0:3 100% |   4.2 MiB/s | 161.6 KiB |  00m00s
[20/45] Installing systemd-devel-0:257. 100% |   6.2 MiB/s | 744.1 KiB |  00m00s
[21/45] Installing libedit-0:3.1-55.202 100% |  30.0 MiB/s | 245.8 KiB |  00m00s
[22/45] Installing llvm19-filesystem-0: 100% | 264.6 KiB/s |   1.1 KiB |  00m00s
[23/45] Installing llvm19-libs-0:19.1.7 100% | 137.8 MiB/s | 124.0 MiB |  00m01s
[24/45] Installing make-1:4.4.1-10.fc42 100% |  37.5 MiB/s |   1.8 MiB |  00m00s
[25/45] Installing gcc-0:15.1.1-2.fc42. 100% | 131.7 MiB/s | 111.2 MiB |  00m01s
[26/45] Installing openssl-devel-1:3.2. 100% |   9.0 MiB/s |   5.2 MiB |  00m01s
[27/45] Installing publicsuffix-list-0: 100% |  53.8 MiB/s | 330.8 KiB |  00m00s
[28/45] Installing libpsl-devel-0:0.21. 100% |  13.9 MiB/s | 113.6 KiB |  00m00s
[29/45] Installing libnghttp2-devel-0:1 100% |  48.3 MiB/s | 296.5 KiB |  00m00s
[30/45] Installing libidn2-devel-0:2.3. 100% |  11.8 MiB/s | 156.7 KiB |  00m00s
[31/45] Installing brotli-0:1.1.0-6.fc4 100% |   1.3 MiB/s |  32.3 KiB |  00m00s
[32/45] Installing brotli-devel-0:1.1.0 100% |   8.3 MiB/s |  68.0 KiB |  00m00s
[33/45] Installing libkadm5-0:1.21.3-6. 100% |  26.4 MiB/s | 215.9 KiB |  00m00s
[34/45] Installing krb5-devel-0:1.21.3- 100% |  18.4 MiB/s | 715.2 KiB |  00m00s
[35/45] Installing sqlite-0:3.47.2-2.fc 100% |  41.5 MiB/s |   1.8 MiB |  00m00s
[36/45] Installing xml-common-0:0.6.3-6 100% |   9.9 MiB/s |  81.1 KiB |  00m00s
[37/45] Installing dbus-libs-1:1.16.0-3 100% |  42.8 MiB/s | 350.6 KiB |  00m00s
[38/45] Installing ldc-libs-1:1.40.0-3. 100% |  85.7 MiB/s |  11.6 MiB |  00m00s
[39/45] Installing ldc-1:1.40.0-3.fc42. 100% |  83.0 MiB/s |  27.5 MiB |  00m00s
[40/45] Installing dbus-devel-1:1.16.0- 100% |  13.3 MiB/s | 136.5 KiB |  00m00s
[41/45] Installing sqlite-devel-0:3.47. 100% |  54.9 MiB/s | 674.1 KiB |  00m00s
[42/45] Installing libcurl-devel-0:8.11 100% |   3.2 MiB/s |   1.4 MiB |  00m00s
[43/45] Installing gcc-plugin-annobin-0 100% |   1.1 MiB/s |  58.8 KiB |  00m00s
[44/45] Installing annobin-plugin-gcc-0 100% |  14.1 MiB/s | 995.1 KiB |  00m00s
[45/45] Installing systemd-rpm-macros-0 100% |   2.9 KiB/s |  11.3 KiB |  00m04s
Complete!
Finish: build setup for onedrive-2.5.6-1.el9.src.rpm
Start: rpmbuild onedrive-2.5.6-1.el9.src.rpm
Start: Outputting list of installed packages
Finish: Outputting list of installed packages
Building target platforms: x86_64
Building for target x86_64
setting SOURCE_DATE_EPOCH=1749081600
Executing(%mkbuilddir): /bin/sh -e /var/tmp/rpm-tmp.ApSQdT
Executing(%prep): /bin/sh -e /var/tmp/rpm-tmp.u4DE7z
+ umask 022
+ cd /builddir/build/BUILD/onedrive-2.5.6-build
+ cd /builddir/build/BUILD/onedrive-2.5.6-build
+ rm -rf onedrive-2.5.6
+ /usr/lib/rpm/rpmuncompress -x /builddir/build/SOURCES/v2.5.6.tar.gz
+ STATUS=0
+ '[' 0 -ne 0 ']'
+ cd onedrive-2.5.6
+ /usr/bin/chmod -Rf a+rX,u+w,g-w,o-w .
+ RPM_EC=0
++ jobs -p
+ exit 0
Executing(%build): /bin/sh -e /var/tmp/rpm-tmp.XgQE0g
+ umask 022
+ cd /builddir/build/BUILD/onedrive-2.5.6-build
+ CFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer '
+ export CFLAGS
+ CXXFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer '
+ export CXXFLAGS
+ FFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -I/usr/lib64/gfortran/modules '
+ export FFLAGS
+ FCFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -I/usr/lib64/gfortran/modules '
+ export FCFLAGS
+ VALAFLAGS=-g
+ export VALAFLAGS
+ RUSTFLAGS='-Copt-level=3 -Cdebuginfo=2 -Ccodegen-units=1 -Cstrip=none -Cforce-frame-pointers=yes -Clink-arg=-specs=/usr/lib/rpm/redhat/redhat-package-notes --cap-lints=warn'
+ export RUSTFLAGS
+ LDFLAGS='-Wl,-z,relro -Wl,--as-needed  -Wl,-z,pack-relative-relocs -Wl,-z,now -specs=/usr/lib/rpm/redhat/redhat-hardened-ld -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -Wl,--build-id=sha1 -specs=/usr/lib/rpm/redhat/redhat-package-notes '
+ export LDFLAGS
+ LT_SYS_LIBRARY_PATH=/usr/lib64:
+ export LT_SYS_LIBRARY_PATH
+ CC=gcc
+ export CC
+ CXX=g++
+ export CXX
+ cd onedrive-2.5.6
+ CFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer '
+ export CFLAGS
+ CXXFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer '
+ export CXXFLAGS
+ FFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -I/usr/lib64/gfortran/modules '
+ export FFLAGS
+ FCFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -I/usr/lib64/gfortran/modules '
+ export FCFLAGS
+ VALAFLAGS=-g
+ export VALAFLAGS
+ RUSTFLAGS='-Copt-level=3 -Cdebuginfo=2 -Ccodegen-units=1 -Cstrip=none -Cforce-frame-pointers=yes -Clink-arg=-specs=/usr/lib/rpm/redhat/redhat-package-notes --cap-lints=warn'
+ export RUSTFLAGS
+ LDFLAGS='-Wl,-z,relro -Wl,--as-needed  -Wl,-z,pack-relative-relocs -Wl,-z,now -specs=/usr/lib/rpm/redhat/redhat-hardened-ld -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -Wl,--build-id=sha1 -specs=/usr/lib/rpm/redhat/redhat-package-notes '
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
+ /usr/bin/sed -r --in-place=.backup '/lt_cv_sys_global_symbol_to_cdecl=/s#(".*"|'\''.*'\'')#"sed -n -e '\''s/^T .* \\(.*\\)$/extern int \\1();/p'\'' -e '\''s/^$symcode* .* \\(.*\\)$/extern char \\1;/p'\''"#' ./configure
+ diff -u ./configure.backup ./configure
+ mv ./configure.backup ./configure
+ '[' 1 = 1 ']'
+++ dirname ./configure
++ find . -name config.guess -o -name config.sub
+ '[' 1 = 1 ']'
+ '[' x '!=' 'x-Wl,-z,now -specs=/usr/lib/rpm/redhat/redhat-hardened-ld' ']'
++ find . -name ltmain.sh
++ grep -q runstatedir=DIR ./configure
+ ./configure --build=x86_64-redhat-linux --host=x86_64-redhat-linux --program-prefix= --disable-dependency-tracking --prefix=/usr --exec-prefix=/usr --bindir=/usr/bin --sbindir=/usr/bin --sysconfdir=/etc --datadir=/usr/share --includedir=/usr/include --libdir=/usr/lib64 --libexecdir=/usr/libexec --localstatedir=/var --sharedstatedir=/var/lib --mandir=/usr/share/man --infodir=/usr/share/info --enable-debug --enable-notifications
configure: WARNING: unrecognized options: --disable-dependency-tracking
checking for a BSD-compatible install... /usr/bin/install -c
checking for x86_64-redhat-linux-pkg-config... no
checking for pkg-config... /usr/bin/pkg-config
checking pkg-config is at least version 0.9.0... yes
checking for dmd... no
checking for ldmd2... ldmd2
checking version of D compiler... 1.40.0
checking for curl... yes
checking for sqlite... yes
checking whether to enable dbus support... yes (on Linux)
checking for dbus... yes
checking for notify... no
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
        echo v2.5.6 > version ; \
fi
ldmd2 -J.  -w -g -debug -gs src/main.d src/config.d src/log.d src/util.d src/qxor.d src/curlEngine.d src/onedrive.d src/webhook.d src/sync.d src/itemdb.d src/sqlite.d src/clientSideFiltering.d src/monitor.d src/arsd/cgi.d src/xattr.d src/intune.d -L-lcurl -L-lsqlite3 -L-L/usr/lib64/pkgconfig/../../lib64 -L-ldbus-1 -L-ldl -ofonedrive
+ RPM_EC=0
++ jobs -p
+ exit 0
Executing(%install): /bin/sh -e /var/tmp/rpm-tmp.jDHAO4
+ umask 022
+ cd /builddir/build/BUILD/onedrive-2.5.6-build
+ '[' /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT '!=' / ']'
+ rm -rf /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT
++ dirname /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT
+ mkdir -p /builddir/build/BUILD/onedrive-2.5.6-build
+ mkdir /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT
+ CFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer '
+ export CFLAGS
+ CXXFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer '
+ export CXXFLAGS
+ FFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -I/usr/lib64/gfortran/modules '
+ export FFLAGS
+ FCFLAGS='-O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -I/usr/lib64/gfortran/modules '
+ export FCFLAGS
+ VALAFLAGS=-g
+ export VALAFLAGS
+ RUSTFLAGS='-Copt-level=3 -Cdebuginfo=2 -Ccodegen-units=1 -Cstrip=none -Cforce-frame-pointers=yes -Clink-arg=-specs=/usr/lib/rpm/redhat/redhat-package-notes --cap-lints=warn'
+ export RUSTFLAGS
+ LDFLAGS='-Wl,-z,relro -Wl,--as-needed  -Wl,-z,pack-relative-relocs -Wl,-z,now -specs=/usr/lib/rpm/redhat/redhat-hardened-ld -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1  -Wl,--build-id=sha1 -specs=/usr/lib/rpm/redhat/redhat-package-notes '
+ export LDFLAGS
+ LT_SYS_LIBRARY_PATH=/usr/lib64:
+ export LT_SYS_LIBRARY_PATH
+ CC=gcc
+ export CC
+ CXX=g++
+ export CXX
+ cd onedrive-2.5.6
+ /usr/bin/make install DESTDIR=/builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT 'INSTALL=/usr/bin/install -p' PREFIX=/builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT
mkdir -p /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/bin
/usr/bin/install -p onedrive /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/bin/onedrive
mkdir -p /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/man/man1
/usr/bin/install -p -m 0644 onedrive.1 /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/man/man1/onedrive.1
mkdir -p /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/etc/logrotate.d
/usr/bin/install -p -m 0644 contrib/logrotate/onedrive.logrotate /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/etc/logrotate.d/onedrive
mkdir -p /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
for file in readme.md config LICENSE changelog.md docs/advanced-usage.md docs/application-config-options.md docs/application-security.md docs/business-shared-items.md docs/client-architecture.md docs/contributing.md docs/docker.md docs/install.md docs/national-cloud-deployments.md docs/podman.md docs/privacy-policy.md docs/sharepoint-libraries.md docs/terms-of-service.md docs/ubuntu-package-install.md docs/usage.md docs/known-issues.md docs/webhooks.md; do \
        /usr/bin/install -p -m 0644 $file /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive; \
done
+ install -D -m 0644 contrib/systemd/onedrive@.service /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/lib/systemd/system/onedrive@.service
+ install -D -m 0644 contrib/systemd/onedrive.service /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/lib/systemd/user/onedrive.service
+ /usr/lib/rpm/check-buildroot
+ /usr/lib/rpm/redhat/brp-ldconfig
+ /usr/lib/rpm/brp-compress
+ /usr/lib/rpm/brp-strip /usr/bin/strip
+ /usr/lib/rpm/brp-strip-comment-note /usr/bin/strip /usr/bin/objdump
+ /usr/lib/rpm/redhat/brp-strip-lto /usr/bin/strip
+ /usr/lib/rpm/brp-strip-static-archive /usr/bin/strip
+ /usr/lib/rpm/check-rpaths
+ /usr/lib/rpm/redhat/brp-mangle-shebangs
+ /usr/lib/rpm/brp-remove-la-files
+ env /usr/lib/rpm/redhat/brp-python-bytecompile '' 1 0 -j1
+ /usr/lib/rpm/redhat/brp-python-hardlink
+ /usr/bin/add-determinism --brp -j1 /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT
Scanned 14 directories and 26 files,
               processed 1 inodes,
               0 modified (0 replaced + 0 rewritten),
               0 unsupported format, 0 errors
Reading /builddir/build/BUILD/onedrive-2.5.6-build/SPECPARTS/rpm-debuginfo.specpart
Processing files: onedrive-2.5.6-1.fc42.x86_64
Executing(%doc): /bin/sh -e /var/tmp/rpm-tmp.2lS8Ty
+ umask 022
+ cd /builddir/build/BUILD/onedrive-2.5.6-build
+ cd onedrive-2.5.6
+ DOCDIR=/builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ export LC_ALL=C.UTF-8
+ LC_ALL=C.UTF-8
+ export DOCDIR
+ /usr/bin/mkdir -p /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/readme.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/LICENSE /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/changelog.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/advanced-usage.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/application-config-options.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/application-security.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/build-rpm-howto.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/business-shared-items.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/client-architecture.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/contributing.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/docker.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/install.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/known-issues.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/national-cloud-deployments.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/podman.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/privacy-policy.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/sharepoint-libraries.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/terms-of-service.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/ubuntu-package-install.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/usage.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/docs/webhooks.md /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ cp -pr /builddir/build/BUILD/onedrive-2.5.6-build/onedrive-2.5.6/config /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT/usr/share/doc/onedrive
+ RPM_EC=0
++ jobs -p
+ exit 0
Provides: config(onedrive) = 2.5.6-1.fc42 onedrive = 2.5.6-1.fc42 onedrive(x86-64) = 2.5.6-1.fc42
Requires(rpmlib): rpmlib(CompressedFileNames) <= 3.0.4-1 rpmlib(FileDigests) <= 4.6.0-1 rpmlib(PayloadFilesHavePrefix) <= 4.0-1
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Requires: ld-linux-x86-64.so.2()(64bit) ld-linux-x86-64.so.2(GLIBC_2.3)(64bit) libc.so.6()(64bit) libc.so.6(GLIBC_2.14)(64bit) libc.so.6(GLIBC_2.15)(64bit) libc.so.6(GLIBC_2.17)(64bit) libc.so.6(GLIBC_2.2.5)(64bit) libc.so.6(GLIBC_2.3)(64bit) libc.so.6(GLIBC_2.3.2)(64bit) libc.so.6(GLIBC_2.33)(64bit) libc.so.6(GLIBC_2.34)(64bit) libc.so.6(GLIBC_2.4)(64bit) libc.so.6(GLIBC_2.7)(64bit) libc.so.6(GLIBC_2.8)(64bit) libcurl.so.4()(64bit) libdbus-1.so.3()(64bit) libdbus-1.so.3(LIBDBUS_1_3)(64bit) libdruntime-ldc-shared.so.110()(64bit) libgcc_s.so.1()(64bit) libgcc_s.so.1(GCC_3.0)(64bit) libm.so.6()(64bit) libm.so.6(GLIBC_2.2.5)(64bit) libphobos2-ldc-shared.so.110()(64bit) libsqlite3.so.0()(64bit) rtld(GNU_HASH)
Checking for unpackaged file(s): /usr/lib/rpm/check-files /builddir/build/BUILD/onedrive-2.5.6-build/BUILDROOT
Wrote: /builddir/build/RPMS/onedrive-2.5.6-1.fc42.x86_64.rpm
Finish: rpmbuild onedrive-2.5.6-1.el9.src.rpm
Finish: build phase for onedrive-2.5.6-1.el9.src.rpm
INFO: Done(/home/alex/rpmbuild/SRPMS/onedrive-2.5.6-1.el9.src.rpm) Config(fedora-42-x86_64) 0 minutes 54 seconds
INFO: Results and/or logs in: /var/lib/mock/fedora-42-x86_64/result
Finish: run
```




