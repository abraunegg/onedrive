
userservicedir = get_option('systemd_user_unit_dir')
if userservicedir == ''
  systemd_dep = dependency('systemd')
  userservicedir = systemd_dep.get_pkgconfig_variable('systemduserunitdir')
endif


systemservicedir = get_option('systemd_system_unit_dir')
if systemservicedir == ''
  systemd_dep = dependency('systemd')
  systemservicedir = systemd_dep.get_pkgconfig_variable('systemdsystemunitdir')
endif


if systemservicedir == ''
  error('Couldn\'t determine systemd user unit service directory: not installing system service unit')
else
  configure_file(input: 'onedrive@.service.in',
                 output: 'onedrive@.service',
                 configuration: conf_data,
	         install_dir: systemservicedir)
endif

if userservicedir == ''
  warning('Couldn\'t determine systemd user unit service directory: not installing user service unit')
else
  configure_file(input: 'onedrive.service.in',
                 output: 'onedrive.service',
                 configuration: conf_data,
	         install_dir: userservicedir)
endif

