# RPM Package Build Process
The instuctions below have been tested on the following systems:
*   CentOS 6 x86_64
*   CentOS 7 x86_64
*   CentOS 8 x86_64

These instructions should also be applicable for RedHat & Fedora platforms, or any other RedHat RPM based distribution.

## Prepare Package Development Environment (CentOS 6, 7, 8)
Install the following dependencies on your build system:
```text
sudo yum groupinstall -y 'Development Tools'
sudo yum install -y libcurl-devel
sudo yum install -y sqlite-devel
sudo yum install -y libnotify-devel
sudo yum install -y wget
sudo yum install -y http://downloads.dlang.org/releases/2.x/2.091.0/dmd-2.091.0-0.fedora.x86_64.rpm
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
```

### CentOS 6 Only
In addition to the above requirements, the `sqlite` version used on CentOS 6.x / RHEL 6.x needs to be upgraded. Use the following instructions to update your version of `sqlite` so that it can support this client:
```text
sudo yum -y install epel-release
sudo yum -y install mock
wget https://kojipkgs.fedoraproject.org//packages/sqlite/3.7.15.2/2.fc19/src/sqlite-3.7.15.2-2.fc19.src.rpm -O ~/rpmbuild/SRPMS/sqlite-3.7.15.2-2.fc19.src.rpm
mock -r epel-6-x86_64 --rebuild ~/rpmbuild/SRPMS/sqlite-3.7.15.2-2.fc19.src.rpm
mock -r epel-6-i386 --rebuild ~/rpmbuild/SRPMS/sqlite-3.7.15.2-2.fc19.src.rpm
mkdir ~/sqlite-upgrade
mv /var/lib/mock/epel-6-x86_64/result/sqlite-*.rpm ~/sqlite-upgrade/
mv /var/lib/mock/epel-6-i386/result/sqlite-*.i686.rpm ~/sqlite-upgrade/
sudo yum -y upgrade ~/sqlite-upgrade/sqlite-*
```

## Build RPM from spec file
Build the RPM from the provided spec file:
```text
wget https://github.com/abraunegg/onedrive/archive/v2.4.0.tar.gz -O ~/rpmbuild/SOURCES/v2.4.0.tar.gz
wget https://raw.githubusercontent.com/abraunegg/onedrive/master/contrib/spec/onedrive.spec.in -O ~/rpmbuild/SPECS/onedrive.spec
rpmbuild -ba ~/rpmbuild/SPECS/onedrive.spec
```

## RPM Build Results
Below are output results of building, installing and running the RPM package on the respective platforms:

### CentOS 6
```text
[alex@localhost ~]$ rpmbuild -ba ~/rpmbuild/SPECS/onedrive.spec
Executing(%prep): /bin/sh -e /var/tmp/rpm-tmp.Ve7WYf
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ LANG=C
+ export LANG
+ unset DISPLAY
+ cd /home/alex/rpmbuild/BUILD
+ rm -rf onedrive-2.4.0
+ /bin/tar -xf -
+ /usr/bin/gzip -dc /home/alex/rpmbuild/SOURCES/v2.4.0.tar.gz
+ STATUS=0
+ '[' 0 -ne 0 ']'
+ cd onedrive-2.4.0
+ /bin/chmod -Rf a+rX,u+w,g-w,o-w .
+ exit 0
Executing(%build): /bin/sh -e /var/tmp/rpm-tmp.iB40rK
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ LANG=C
+ export LANG
+ unset DISPLAY
+ CFLAGS='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic'
+ export CFLAGS
+ CXXFLAGS='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic'
+ export CXXFLAGS
+ FFLAGS='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic -I/usr/lib64/gfortran/modules'
+ export FFLAGS
+ ./configure --build=x86_64-redhat-linux-gnu --host=x86_64-redhat-linux-gnu --target=x86_64-redhat-linux-gnu --program-prefix= --prefix=/usr --exec-prefix=/usr --bindir=/usr/bin --sbindir=/usr/sbin --sysconfdir=/etc --datadir=/usr/share --includedir=/usr/include --libdir=/usr/lib64 --libexecdir=/usr/libexec --localstatedir=/var --sharedstatedir=/var/lib --mandir=/usr/share/man --infodir=/usr/share/info
checking for a BSD-compatible install... /usr/bin/install -c
checking for x86_64-redhat-linux-gnu-pkg-config... no
checking for pkg-config... /usr/bin/pkg-config
checking pkg-config is at least version 0.9.0... yes
checking for dmd... dmd
checking version of D compiler... 2.091.0
checking for curl... yes
checking for sqlite... yes
configure: creating ./config.status
config.status: creating Makefile
config.status: creating contrib/pacman/PKGBUILD
config.status: creating contrib/spec/onedrive.spec
config.status: creating onedrive.1
config.status: creating contrib/systemd/onedrive.service
config.status: creating contrib/systemd/onedrive@.service
+ make
if [ -f .git/HEAD ] ; then \
                git describe --tags > version ; \
        else \
                echo v2.4.0 > version ; \
        fi
dmd  -w -g -O -J. -L-lcurl -L-lsqlite3  -L-ldl src/config.d src/itemdb.d src/log.d src/main.d src/monitor.d src/onedrive.d src/qxor.d src/selective.d src/sqlite.d src/sync.d src/upload.d src/util.d src/progress.d -ofonedrive
+ exit 0
Executing(%install): /bin/sh -e /var/tmp/rpm-tmp.VP7LUb
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ '[' /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64 '!=' / ']'
+ rm -rf /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64
++ dirname /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64
+ mkdir -p /home/alex/rpmbuild/BUILDROOT
+ mkdir /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64
+ cd onedrive-2.4.0
+ LANG=C
+ export LANG
+ unset DISPLAY
+ make install DESTDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64 PREFIX=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64
/usr/bin/install -c -D onedrive /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/bin/onedrive
/usr/bin/install -c -D onedrive.1 /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/share/man/man1/onedrive.1
/usr/bin/install -c -D -m 644 contrib/logrotate/onedrive.logrotate /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/etc/logrotate.d/onedrive
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/share/doc/onedrive
/usr/bin/install -c -D -m 644 README.md config LICENSE CHANGELOG.md docs/Docker.md docs/INSTALL.md docs/Office365.md docs/USAGE.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/share/doc/onedrive
install -D contrib/init.d/onedrive.init /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/etc/init.d/onedrive
install -D contrib/init.d/onedrive_service.sh /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/bin/onedrive_service.sh
+ /usr/lib/rpm/check-buildroot
+ /usr/lib/rpm/redhat/brp-compress
+ /usr/lib/rpm/redhat/brp-strip /usr/bin/strip
+ /usr/lib/rpm/redhat/brp-strip-static-archive /usr/bin/strip
+ /usr/lib/rpm/redhat/brp-strip-comment-note /usr/bin/strip /usr/bin/objdump
+ /usr/lib/rpm/brp-python-bytecompile /usr/bin/python
+ /usr/lib/rpm/redhat/brp-python-hardlink
+ /usr/lib/rpm/redhat/brp-java-repack-jars
Processing files: onedrive-2.4.0-1.el6.x86_64
Executing(%doc): /bin/sh -e /var/tmp/rpm-tmp.6wsc3O
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ DOCDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/share/doc/onedrive-2.4.0
+ export DOCDIR
+ rm -rf /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/share/doc/onedrive-2.4.0
+ /bin/mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/share/doc/onedrive-2.4.0
+ cp -pr README.md LICENSE CHANGELOG.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64/usr/share/doc/onedrive-2.4.0
+ exit 0
Provides: config(onedrive) = 2.4.0-1.el6
Requires(rpmlib): rpmlib(CompressedFileNames) <= 3.0.4-1 rpmlib(FileDigests) <= 4.6.0-1 rpmlib(PayloadFilesHavePrefix) <= 4.0-1
Requires(post): chkconfig
Requires(preun): chkconfig initscripts
Requires(postun): initscripts
Requires: /bin/bash /bin/sh ld-linux-x86-64.so.2()(64bit) ld-linux-x86-64.so.2(GLIBC_2.3)(64bit) libc.so.6()(64bit) libc.so.6(GLIBC_2.2.5)(64bit) libc.so.6(GLIBC_2.3.2)(64bit) libc.so.6(GLIBC_2.4)(64bit) libc.so.6(GLIBC_2.6)(64bit) libcurl.so.4()(64bit) libdl.so.2()(64bit) libdl.so.2(GLIBC_2.2.5)(64bit) libgcc_s.so.1()(64bit) libgcc_s.so.1(GCC_3.0)(64bit) libgcc_s.so.1(GCC_4.2.0)(64bit) libm.so.6()(64bit) libm.so.6(GLIBC_2.2.5)(64bit) libpthread.so.0()(64bit) libpthread.so.0(GLIBC_2.2.5)(64bit) libpthread.so.0(GLIBC_2.3.2)(64bit) libpthread.so.0(GLIBC_2.3.3)(64bit) libpthread.so.0(GLIBC_2.3.4)(64bit) librt.so.1()(64bit) librt.so.1(GLIBC_2.2.5)(64bit) libsqlite3.so.0()(64bit) rtld(GNU_HASH)
Checking for unpackaged file(s): /usr/lib/rpm/check-files /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el6.x86_64
Wrote: /home/alex/rpmbuild/SRPMS/onedrive-2.4.0-1.el6.src.rpm
Wrote: /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el6.x86_64.rpm
Executing(%clean): /bin/sh -e /var/tmp/rpm-tmp.MuVJDP
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ exit 0
[alex@localhost ~]$ sudo yum -y install /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el6.x86_64.rpm
Loaded plugins: fastestmirror
Setting up Install Process
Examining /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el6.x86_64.rpm: onedrive-2.4.0-1.el6.x86_64
Marking /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el6.x86_64.rpm to be installed
Loading mirror speeds from cached hostfile
 * base: mirror.internode.on.net
 * epel: fedora.mirror.serversaustralia.com.au
 * extras: mirror.internode.on.net
 * updates: mirror.colocity.com
Resolving Dependencies
--> Running transaction check
---> Package onedrive.x86_64 0:2.4.0-1.el6 will be installed
--> Finished Dependency Resolution

Dependencies Resolved

==============================================================================================================================================================================================
 Package                                 Arch                                  Version                                      Repository                                                   Size
==============================================================================================================================================================================================
Installing:
 onedrive                                x86_64                                2.4.0-1.el6                                  /onedrive-2.4.0-1.el6.x86_64                                5.8 M

Transaction Summary
==============================================================================================================================================================================================
Install       1 Package(s)

Total size: 5.8 M
Installed size: 5.8 M
Downloading Packages:
Running rpm_check_debug
Running Transaction Test
Transaction Test Succeeded
Running Transaction
  Installing : onedrive-2.4.0-1.el6.x86_64                                                                                                                                                1/1 
  Verifying  : onedrive-2.4.0-1.el6.x86_64                                                                                                                                                1/1 

Installed:
  onedrive.x86_64 0:2.4.0-1.el6                                                                                                                                                               

Complete!
[alex@localhost ~]$ which onedrive
/usr/bin/onedrive
[alex@localhost ~]$ onedrive --version
onedrive v2.4.0
[alex@localhost ~]$ onedrive --display-config
onedrive version                       = v2.4.0
Config path                            = /home/alex/.config/onedrive
Config file found in config path       = false
Config option 'check_nosync'           = false
Config option 'sync_dir'               = /home/alex/OneDrive
Config option 'skip_dir'               = 
Config option 'skip_file'              = ~*|.~*|*.tmp
Config option 'skip_dotfiles'          = false
Config option 'skip_symlinks'          = false
Config option 'monitor_interval'       = 45
Config option 'min_notify_changes'     = 5
Config option 'log_dir'                = /var/log/onedrive/
Config option 'classify_as_big_delete' = 1000
Config option 'sync_root_files'        = false
Selective sync configured              = false
[alex@localhost ~]$ 
```

### CentOS 7
```text
[alex@localhost ~]$ rpmbuild -ba ~/rpmbuild/SPECS/onedrive.spec
Executing(%prep): /bin/sh -e /var/tmp/rpm-tmp.BEprc0
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd /home/alex/rpmbuild/BUILD
+ rm -rf onedrive-2.4.0
+ /usr/bin/gzip -dc /home/alex/rpmbuild/SOURCES/v2.4.0.tar.gz
+ /usr/bin/tar -xf -
+ STATUS=0
+ '[' 0 -ne 0 ']'
+ cd onedrive-2.4.0
+ /usr/bin/chmod -Rf a+rX,u+w,g-w,o-w .
+ exit 0
Executing(%build): /bin/sh -e /var/tmp/rpm-tmp.CSy74N
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ CFLAGS='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches   -m64 -mtune=generic'
+ export CFLAGS
+ CXXFLAGS='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches   -m64 -mtune=generic'
+ export CXXFLAGS
+ FFLAGS='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches   -m64 -mtune=generic -I/usr/lib64/gfortran/modules'
+ export FFLAGS
+ FCFLAGS='-O2 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches   -m64 -mtune=generic -I/usr/lib64/gfortran/modules'
+ export FCFLAGS
+ LDFLAGS='-Wl,-z,relro '
+ export LDFLAGS
+ '[' 1 == 1 ']'
+ '[' x86_64 == ppc64le ']'
++ find . -name config.guess -o -name config.sub
+ ./configure --build=x86_64-redhat-linux-gnu --host=x86_64-redhat-linux-gnu --program-prefix= --disable-dependency-tracking --prefix=/usr --exec-prefix=/usr --bindir=/usr/bin --sbindir=/usr/sbin --sysconfdir=/etc --datadir=/usr/share --includedir=/usr/include --libdir=/usr/lib64 --libexecdir=/usr/libexec --localstatedir=/var --sharedstatedir=/var/lib --mandir=/usr/share/man --infodir=/usr/share/info
configure: WARNING: unrecognized options: --disable-dependency-tracking
checking for a BSD-compatible install... /usr/bin/install -c
checking for x86_64-redhat-linux-gnu-pkg-config... no
checking for pkg-config... /usr/bin/pkg-config
checking pkg-config is at least version 0.9.0... yes
checking for dmd... dmd
checking version of D compiler... 2.091.0
checking for curl... yes
checking for sqlite... yes
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
        echo v2.4.0 > version ; \
fi
dmd  -w -g -O -J. -L-lcurl -L-lsqlite3  -L-ldl src/config.d src/itemdb.d src/log.d src/main.d src/monitor.d src/onedrive.d src/qxor.d src/selective.d src/sqlite.d src/sync.d src/upload.d src/util.d src/progress.d -ofonedrive
+ exit 0
Executing(%install): /bin/sh -e /var/tmp/rpm-tmp.Ffintx
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ '[' /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64 '!=' / ']'
+ rm -rf /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64
++ dirname /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64
+ mkdir -p /home/alex/rpmbuild/BUILDROOT
+ mkdir /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64
+ cd onedrive-2.4.0
+ /usr/bin/make install DESTDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64 PREFIX=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64
/usr/bin/install -c -D onedrive /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/bin/onedrive
/usr/bin/install -c -D onedrive.1 /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/share/man/man1/onedrive.1
/usr/bin/install -c -D -m 644 contrib/logrotate/onedrive.logrotate /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/etc/logrotate.d/onedrive
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/share/doc/onedrive
/usr/bin/install -c -D -m 644 README.md config LICENSE CHANGELOG.md docs/Docker.md docs/INSTALL.md docs/Office365.md docs/USAGE.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/share/doc/onedrive
/usr/bin/install -c -d -m 0755 /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/lib/systemd/user /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/lib/systemd/system
/usr/bin/install -c -m 0644 contrib/systemd/onedrive@.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/lib/systemd/system
/usr/bin/install -c -m 0644 contrib/systemd/onedrive.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/lib/systemd/system
+ /usr/lib/rpm/check-buildroot
+ /usr/lib/rpm/redhat/brp-compress
+ /usr/lib/rpm/redhat/brp-strip /usr/bin/strip
+ /usr/lib/rpm/redhat/brp-strip-comment-note /usr/bin/strip /usr/bin/objdump
+ /usr/lib/rpm/redhat/brp-strip-static-archive /usr/bin/strip
+ /usr/lib/rpm/brp-python-bytecompile /usr/bin/python 1
+ /usr/lib/rpm/redhat/brp-python-hardlink
+ /usr/lib/rpm/redhat/brp-java-repack-jars
Processing files: onedrive-2.4.0-1.el7.x86_64
Executing(%doc): /bin/sh -e /var/tmp/rpm-tmp.EB5XJj
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ DOCDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/share/doc/onedrive-2.4.0
+ export DOCDIR
+ /usr/bin/mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/share/doc/onedrive-2.4.0
+ cp -pr README.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/share/doc/onedrive-2.4.0
+ cp -pr LICENSE /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/share/doc/onedrive-2.4.0
+ cp -pr CHANGELOG.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64/usr/share/doc/onedrive-2.4.0
+ exit 0
Provides: config(onedrive) = 2.4.0-1.el7 onedrive = 2.4.0-1.el7 onedrive(x86-64) = 2.4.0-1.el7
Requires(rpmlib): rpmlib(CompressedFileNames) <= 3.0.4-1 rpmlib(FileDigests) <= 4.6.0-1 rpmlib(PayloadFilesHavePrefix) <= 4.0-1
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Requires: ld-linux-x86-64.so.2()(64bit) ld-linux-x86-64.so.2(GLIBC_2.3)(64bit) libc.so.6()(64bit) libc.so.6(GLIBC_2.14)(64bit) libc.so.6(GLIBC_2.2.5)(64bit) libc.so.6(GLIBC_2.3.2)(64bit) libc.so.6(GLIBC_2.4)(64bit) libc.so.6(GLIBC_2.6)(64bit) libcurl.so.4()(64bit) libdl.so.2()(64bit) libdl.so.2(GLIBC_2.2.5)(64bit) libgcc_s.so.1()(64bit) libgcc_s.so.1(GCC_3.0)(64bit) libgcc_s.so.1(GCC_4.2.0)(64bit) libm.so.6()(64bit) libm.so.6(GLIBC_2.2.5)(64bit) libpthread.so.0()(64bit) libpthread.so.0(GLIBC_2.2.5)(64bit) libpthread.so.0(GLIBC_2.3.2)(64bit) libpthread.so.0(GLIBC_2.3.3)(64bit) libpthread.so.0(GLIBC_2.3.4)(64bit) librt.so.1()(64bit) librt.so.1(GLIBC_2.2.5)(64bit) libsqlite3.so.0()(64bit) rtld(GNU_HASH)
Checking for unpackaged file(s): /usr/lib/rpm/check-files /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el7.x86_64
Wrote: /home/alex/rpmbuild/SRPMS/onedrive-2.4.0-1.el7.src.rpm
Wrote: /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el7.x86_64.rpm
Executing(%clean): /bin/sh -e /var/tmp/rpm-tmp.2VzBVJ
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ exit 0
[alex@localhost ~]$ sudo yum -y install /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el7.x86_64.rpm
Loaded plugins: fastestmirror
Examining /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el7.x86_64.rpm: onedrive-2.4.0-1.el7.x86_64
Marking /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el7.x86_64.rpm to be installed
Resolving Dependencies
--> Running transaction check
---> Package onedrive.x86_64 0:2.4.0-1.el7 will be installed
--> Finished Dependency Resolution

Dependencies Resolved

==============================================================================================================================================================================================
 Package                                 Arch                                  Version                                      Repository                                                   Size
==============================================================================================================================================================================================
Installing:
 onedrive                                x86_64                                2.4.0-1.el7                                  /onedrive-2.4.0-1.el7.x86_64                                5.8 M

Transaction Summary
==============================================================================================================================================================================================
Install  1 Package

Total size: 5.8 M
Installed size: 5.8 M
Downloading packages:
Running transaction check
Running transaction test
Transaction test succeeded
Running transaction
  Installing : onedrive-2.4.0-1.el7.x86_64                                                                                                                                                1/1 
  Verifying  : onedrive-2.4.0-1.el7.x86_64                                                                                                                                                1/1 

Installed:
  onedrive.x86_64 0:2.4.0-1.el7                                                                                                                                                               

Complete!
[alex@localhost ~]$ which onedrive
/usr/bin/onedrive
[alex@localhost ~]$ onedrive --version
onedrive v2.4.0
[alex@localhost ~]$ onedrive --display-config
onedrive version                       = v2.4.0
Config path                            = /home/alex/.config/onedrive
Config file found in config path       = false
Config option 'check_nosync'           = false
Config option 'sync_dir'               = /home/alex/OneDrive
Config option 'skip_dir'               = 
Config option 'skip_file'              = ~*|.~*|*.tmp
Config option 'skip_dotfiles'          = false
Config option 'skip_symlinks'          = false
Config option 'monitor_interval'       = 45
Config option 'min_notify_changes'     = 5
Config option 'log_dir'                = /var/log/onedrive/
Config option 'classify_as_big_delete' = 1000
Config option 'sync_root_files'        = false
Selective sync configured              = false
[alex@localhost ~]$ 
```

### CentOS 8
```text
[alex@localhost ~]$ rpmbuild -ba ~/rpmbuild/SPECS/onedrive.spec
Executing(%prep): /bin/sh -e /var/tmp/rpm-tmp.5LOfYv
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd /home/alex/rpmbuild/BUILD
+ rm -rf onedrive-2.4.0
+ /usr/bin/gzip -dc /home/alex/rpmbuild/SOURCES/v2.4.0.tar.gz
+ /usr/bin/tar -xof -
+ STATUS=0
+ '[' 0 -ne 0 ']'
+ cd onedrive-2.4.0
+ /usr/bin/chmod -Rf a+rX,u+w,g-w,o-w .
+ exit 0
Executing(%build): /bin/sh -e /var/tmp/rpm-tmp.HRIOjX
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ CFLAGS='-O2 -g -pipe -Wall -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -fexceptions -fstack-protector-strong -grecord-gcc-switches -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 -m64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection'
+ export CFLAGS
+ CXXFLAGS='-O2 -g -pipe -Wall -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -fexceptions -fstack-protector-strong -grecord-gcc-switches -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 -m64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection'
+ export CXXFLAGS
+ FFLAGS='-O2 -g -pipe -Wall -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -fexceptions -fstack-protector-strong -grecord-gcc-switches -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 -m64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -I/usr/lib64/gfortran/modules'
+ export FFLAGS
+ FCFLAGS='-O2 -g -pipe -Wall -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -Wp,-D_GLIBCXX_ASSERTIONS -fexceptions -fstack-protector-strong -grecord-gcc-switches -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 -m64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -I/usr/lib64/gfortran/modules'
+ export FCFLAGS
+ LDFLAGS='-Wl,-z,relro  -Wl,-z,now -specs=/usr/lib/rpm/redhat/redhat-hardened-ld'
+ export LDFLAGS
+ '[' 1 = 1 ']'
+++ dirname ./configure
++ find . -name config.guess -o -name config.sub
+ '[' 1 = 1 ']'
+ '[' x '!=' 'x-Wl,-z,now -specs=/usr/lib/rpm/redhat/redhat-hardened-ld' ']'
++ find . -name ltmain.sh
+ ./configure --build=x86_64-redhat-linux-gnu --host=x86_64-redhat-linux-gnu --program-prefix= --disable-dependency-tracking --prefix=/usr --exec-prefix=/usr --bindir=/usr/bin --sbindir=/usr/sbin --sysconfdir=/etc --datadir=/usr/share --includedir=/usr/include --libdir=/usr/lib64 --libexecdir=/usr/libexec --localstatedir=/var --sharedstatedir=/var/lib --mandir=/usr/share/man --infodir=/usr/share/info
configure: WARNING: unrecognized options: --disable-dependency-tracking
checking for a BSD-compatible install... /usr/bin/install -c
checking for x86_64-redhat-linux-gnu-pkg-config... /usr/bin/x86_64-redhat-linux-gnu-pkg-config
checking pkg-config is at least version 0.9.0... yes
checking for dmd... dmd
checking version of D compiler... 2.091.0
checking for curl... yes
checking for sqlite... yes
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
        echo v2.4.0 > version ; \
fi
dmd  -w -g -O -J. -L-lcurl -L-lsqlite3  -L-ldl src/config.d src/itemdb.d src/log.d src/main.d src/monitor.d src/onedrive.d src/qxor.d src/selective.d src/sqlite.d src/sync.d src/upload.d src/util.d src/progress.d -ofonedrive
+ exit 0
Executing(%install): /bin/sh -e /var/tmp/rpm-tmp.u9F8Hd
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ '[' /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64 '!=' / ']'
+ rm -rf /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64
++ dirname /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64
+ mkdir -p /home/alex/rpmbuild/BUILDROOT
+ mkdir /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64
+ cd onedrive-2.4.0
+ /usr/bin/make install DESTDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64 'INSTALL=/usr/bin/install -p' PREFIX=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64
/usr/bin/install -p -D onedrive /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/bin/onedrive
/usr/bin/install -p -D onedrive.1 /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/share/man/man1/onedrive.1
/usr/bin/install -p -D -m 644 contrib/logrotate/onedrive.logrotate /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/etc/logrotate.d/onedrive
mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/share/doc/onedrive
/usr/bin/install -p -D -m 644 README.md config LICENSE CHANGELOG.md docs/Docker.md docs/INSTALL.md docs/Office365.md docs/USAGE.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/share/doc/onedrive
/usr/bin/install -p -d -m 0755 /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/lib/systemd/user /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/lib/systemd/system
/usr/bin/install -p -m 0644 contrib/systemd/onedrive@.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/lib/systemd/system
/usr/bin/install -p -m 0644 contrib/systemd/onedrive.service /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/lib/systemd/system
+ /usr/lib/rpm/check-buildroot
+ /usr/lib/rpm/redhat/brp-ldconfig
/sbin/ldconfig: Warning: ignoring configuration file that cannot be opened: /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/etc/ld.so.conf: No such file or directory
+ /usr/lib/rpm/brp-compress
+ /usr/lib/rpm/brp-strip /usr/bin/strip
+ /usr/lib/rpm/brp-strip-comment-note /usr/bin/strip /usr/bin/objdump
+ /usr/lib/rpm/brp-strip-static-archive /usr/bin/strip
+ /usr/lib/rpm/brp-python-bytecompile 1
+ /usr/lib/rpm/brp-python-hardlink
+ PYTHON3=/usr/libexec/platform-python
+ /usr/lib/rpm/redhat/brp-mangle-shebangs
Processing files: onedrive-2.4.0-1.el8.x86_64
Executing(%doc): /bin/sh -e /var/tmp/rpm-tmp.zi889w
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ DOCDIR=/home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/share/doc/onedrive
+ export LC_ALL=C
+ LC_ALL=C
+ export DOCDIR
+ /usr/bin/mkdir -p /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/share/doc/onedrive
+ cp -pr README.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/share/doc/onedrive
+ cp -pr LICENSE /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/share/doc/onedrive
+ cp -pr CHANGELOG.md /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64/usr/share/doc/onedrive
+ exit 0
warning: File listed twice: /usr/share/doc/onedrive
warning: File listed twice: /usr/share/doc/onedrive/CHANGELOG.md
warning: File listed twice: /usr/share/doc/onedrive/LICENSE
warning: File listed twice: /usr/share/doc/onedrive/README.md
Provides: config(onedrive) = 2.4.0-1.el8 onedrive = 2.4.0-1.el8 onedrive(x86-64) = 2.4.0-1.el8
Requires(rpmlib): rpmlib(CompressedFileNames) <= 3.0.4-1 rpmlib(FileDigests) <= 4.6.0-1 rpmlib(PayloadFilesHavePrefix) <= 4.0-1
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Requires: ld-linux-x86-64.so.2()(64bit) ld-linux-x86-64.so.2(GLIBC_2.3)(64bit) libc.so.6()(64bit) libc.so.6(GLIBC_2.14)(64bit) libc.so.6(GLIBC_2.2.5)(64bit) libc.so.6(GLIBC_2.3.2)(64bit) libc.so.6(GLIBC_2.4)(64bit) libc.so.6(GLIBC_2.6)(64bit) libcurl.so.4()(64bit) libdl.so.2()(64bit) libdl.so.2(GLIBC_2.2.5)(64bit) libgcc_s.so.1()(64bit) libgcc_s.so.1(GCC_3.0)(64bit) libgcc_s.so.1(GCC_4.2.0)(64bit) libm.so.6()(64bit) libm.so.6(GLIBC_2.2.5)(64bit) libpthread.so.0()(64bit) libpthread.so.0(GLIBC_2.2.5)(64bit) libpthread.so.0(GLIBC_2.3.2)(64bit) libpthread.so.0(GLIBC_2.3.3)(64bit) libpthread.so.0(GLIBC_2.3.4)(64bit) librt.so.1()(64bit) librt.so.1(GLIBC_2.2.5)(64bit) libsqlite3.so.0()(64bit) rtld(GNU_HASH)
Checking for unpackaged file(s): /usr/lib/rpm/check-files /home/alex/rpmbuild/BUILDROOT/onedrive-2.4.0-1.el8.x86_64
Wrote: /home/alex/rpmbuild/SRPMS/onedrive-2.4.0-1.el8.src.rpm
Wrote: /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el8.x86_64.rpm
Executing(%clean): /bin/sh -e /var/tmp/rpm-tmp.XEoFDV
+ umask 022
+ cd /home/alex/rpmbuild/BUILD
+ cd onedrive-2.4.0
+ exit 0
[alex@localhost ~]$ sudo yum -y install /home/alex/rpmbuild/RPMS/x86_64/onedrive-2.4.0-1.el8.x86_64.rpm
Last metadata expiration check: 0:34:12 ago on Fri 17 Apr 2020 18:11:23 EDT.
Dependencies resolved.
==============================================================================================================================================================================================
 Package                                     Architecture                              Version                                          Repository                                       Size
==============================================================================================================================================================================================
Installing:
 onedrive                                    x86_64                                    2.4.0-1.el8                                      @commandline                                    1.2 M

Transaction Summary
==============================================================================================================================================================================================
Install  1 Package

Total size: 1.2 M
Installed size: 5.7 M
Downloading Packages:
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                                                                                                                                      1/1 
  Installing       : onedrive-2.4.0-1.el8.x86_64                                                                                                                                          1/1 
  Running scriptlet: onedrive-2.4.0-1.el8.x86_64                                                                                                                                          1/1 
  Verifying        : onedrive-2.4.0-1.el8.x86_64                                                                                                                                          1/1 

Installed:
  onedrive-2.4.0-1.el8.x86_64                                                                                                                                                                 

Complete!
[alex@localhost ~]$ which onedrive
/usr/bin/onedrive
[alex@localhost ~]$ onedrive --version
onedrive v2.4.0
[alex@localhost ~]$ onedrive --display-config
onedrive version                       = v2.4.0
Config path                            = /home/alex/.config/onedrive
Config file found in config path       = false
Config option 'check_nosync'           = false
Config option 'sync_dir'               = /home/alex/OneDrive
Config option 'skip_dir'               = 
Config option 'skip_file'              = ~*|.~*|*.tmp
Config option 'skip_dotfiles'          = false
Config option 'skip_symlinks'          = false
Config option 'monitor_interval'       = 45
Config option 'min_notify_changes'     = 5
Config option 'log_dir'                = /var/log/onedrive/
Config option 'classify_as_big_delete' = 1000
Config option 'sync_root_files'        = false
Selective sync configured              = false
[alex@localhost ~]$ 
```