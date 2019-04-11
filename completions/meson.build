

bash_completion_dir = get_option('bash_completion_dir')
if bash_completion_dir == ''
  # try to find via pkg-config
  bash_completion_dep = dependency('bash-completion')
  if bash_completion_dep.found()
    bash_completion_dir = bash_completion_dep.get_pkgconfig_variable('completionsdir')
  endif
endif
if bash_completion_dir == ''
  # still not found, make it install into PREFIX
  bash_completion_dir = join_paths(get_option('datadir'), 'bash-completion', 'completions')
endif

zsh_completion_dir = get_option('zsh_completion_dir')
if zsh_completion_dir == ''
  zsh_completion_dir = '/usr/local/share/zsh/site-functions'
endif

install_data('complete.zsh',
             install_dir: zsh_completion_dir,
             rename: '_onedrive')
install_data('complete.bash',
             install_dir: bash_completion_dir,
             rename: 'onedrive')

