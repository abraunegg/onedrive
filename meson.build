project('onedrive', 'd', version: '2.2.1')

prefix = get_option('prefix')
docdir = join_paths(get_option('datadir'), 'doc', meson.project_name())
mandir = join_paths(get_option('mandir'), 'man1')

conf_data = configuration_data()
conf_data.set('PREFIX',  prefix)
conf_data.set('DOCDIR',  join_paths(prefix, docdir))
conf_data.set('VERSION', meson.project_version())

version = run_command('generate_version', meson.build_root(), meson.project_version())
if version.returncode() != 0
  error('Cannot create version file!')
endif

# compile the binaries
subdir('src')

# install systemd stuff
subdir('systemd.units')


configure_file(input: 'onedrive.1.in',
               output: 'onedrive.1',
               configuration: conf_data,
               install_dir: mandir)


docfiles = [ 'README.md', 'README.Office365.md', 'config', 'LICENSE', 'CHANGELOG.md' ]
install_data(docfiles, install_dir: docdir)

install_data('logrotate/onedrive.logrotate',
             install_dir: join_paths(get_option('sysconfdir'), 'logrotate.d'))


