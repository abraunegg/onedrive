# Determine based on distribution & version what options & packages to include
%if 0%{?fedora} || 0%{?rhel} >= 7
%global with_systemd      1
%else
%global with_systemd      0
%endif

Name:       onedrive
Version:    2.3.2
Release:    1%{?dist}
Summary:    Microsoft OneDrive Client
Group:      System Environment/Network
License:    GPLv3
URL:        https://github.com/abraunegg/onedrive
#Source0:    %{name}-%{version}.tar.gz
BuildRoot:  %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

BuildRequires:	git
BuildRequires:	dmd >= 2.079.0
BuildRequires:	sqlite-devel >= 3.7.15
BuildRequires:	libcurl-devel
Requires:		sqlite >= 3.7.15
Requires:		libcurl

%if 0%{?with_systemd}
Requires(post):    systemd
Requires(preun):   systemd
Requires(postun):  systemd
%else
Requires(post):    chkconfig
Requires(preun):   chkconfig
Requires(preun):   initscripts
Requires(postun):  initscripts
%endif

%define debug_package %{nil}

%description
Microsoft OneDrive Client for Linux

%prep

%setup -c -D -T
# This creates cd %{_builddir}/%{name}-%{version}/
# clone the repository
git clone https://github.com/abraunegg/onedrive.git .
# We should now have %{_builddir}/%{name}-%{version} with the git clone

%build
cd %{_builddir}/%{name}-%{version}
make

%install
# Make the destination directories
%{__mkdir_p} %{buildroot}/etc/
%{__mkdir_p} %{buildroot}/usr/bin/
%{__mkdir_p} %{buildroot}/etc/logrotate.d
cp %{_builddir}/%{name}-%{version}/onedrive %{buildroot}/usr/bin/onedrive
cp %{_builddir}/%{name}-%{version}/logrotate/onedrive.logrotate %{buildroot}/etc/logrotate.d/onedrive
%if 0%{?with_systemd}
%{__mkdir_p} %{buildroot}/%{_unitdir}
cp %{_builddir}/%{name}-%{version}/onedrive.service %{buildroot}/%{_unitdir}/onedrive.service
cp %{_builddir}/%{name}-%{version}/onedrive.service %{buildroot}/%{_unitdir}/onedrive@.service
%else
%{__mkdir_p} %{buildroot}%{_initrddir}
cp %{_builddir}/%{name}-%{version}/init.d/onedrive_service.sh %{buildroot}/usr/bin/onedrive_service.sh
cp %{_builddir}/%{name}-%{version}/init.d/onedrive.init %{buildroot}%{_initrddir}/onedrive
%endif

%clean

%files
%defattr(0444,root,root,0755)
%attr(0555,root,root) /usr/bin/onedrive
%attr(0644,root,root) /etc/logrotate.d/onedrive
%if 0%{?with_systemd}
%attr(0555,root,root) %{_unitdir}/onedrive.service
%attr(0555,root,root) %{_unitdir}/onedrive@.service
%else
%attr(0555,root,root) /usr/bin/onedrive_service.sh
%attr(0555,root,root) %{_initrddir}/onedrive
%endif

%pre
rm -f /root/.config/onedrive/items.db
rm -f /root/.config/onedrive/items.sqlite3
rm -f /root/.config/onedrive/resume_upload

%post
mkdir -p /root/.config/onedrive
mkdir -p /root/OneDrive
mkdir -p /var/log/onedrive
chown root.users /var/log/onedrive
chmod 0775 /var/log/onedrive
%if 0%{?with_systemd}
%systemd_post onedrive.service
%else
chkconfig --add onedrive
chkconfig onedrive off
%endif

%preun
%if 0%{?with_systemd}
%systemd_preun onedrive.service
%else
if [ $1 -eq 0 ] ; then
    service onedrive stop &> /dev/null
    chkconfig --del onedrive &> /dev/null
fi
%endif

%changelog