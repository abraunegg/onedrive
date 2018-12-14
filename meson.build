project('onedrive', 'd', version: '2.2.1')

version = run_command('generate_version', meson.build_root(), meson.project_version())
if version.returncode() != 0
  error('Cannot create version file!')
endif
subdir('src')

