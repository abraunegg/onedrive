
sqlite_dep = dependency('sqlite3')
curl_dep   = dependency('libcurl')
deps = [ sqlite_dep, curl_dep ]

onedrive_src = [ 
  'config.d',
  'itemdb.d',
  'log.d',
  'main.d',
  'monitor.d',
  'onedrive.d',
  'qxor.d',
  'selective.d',
  'sqlite.d',
  'sync.d',
  'upload.d',
  'util.d',
  'progress.d',
]

dargs = [ '-J' + meson.build_root() ]

notifications_dep = dependency('libnotify', required : get_option('notifications'))
if notifications_dep.found()
  deps += [ notifications_dep ]
  onedrive_src += [ 'notifications/dnotify.d', 'notifications/notify.d' ]
  dargs += [ '-I' + join_paths(meson.current_source_dir(), 'notifications') ]
endif

executable('onedrive', onedrive_src, 
           dependencies: deps,
	   d_args : dargs )

