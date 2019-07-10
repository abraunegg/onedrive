#compdef onedrive
#
# ZSH completion code for OneDrive Linux Client
# (c) 2019 Norbert Preining
# License: GPLv3+ (as with the rest of the OneDrive Linux client project)

local -a all_opts
all_opts=(
  '--check-for-nomount[Check for the presence of .nosync in the syncdir root. If found, do not perform sync.]'
  '--check-for-nosync[Check for the presence of .nosync in each directory. If found, skip directory from sync.]'
  '--confdir[Set the directory used to store the configuration files]:config directory:_files -/'
  '--create-directory[Create a directory on OneDrive - no sync will be performed.]:directory name:'
  '--debug-https[Debug OneDrive HTTPS communication.]'
  '--destination-directory[Destination directory for renamed or move on OneDrive - no sync will be performed.]:directory name:'
  '--disable-notifications[Do not use desktop notifications in monitor mode.]'
  '--display-config[Display what options the client will use as currently configured - no sync will be performed.]'
  '--display-sync-status[Display the sync status of the client - no sync will be performed.]'
  '--download-only[Only download remote changes]'
  '--disable-upload-validation[Disable upload validation when uploading to OneDrive]'
  '--dry-run[Perform a trial sync with no changes made]'
  '--enable-logging[Enable client activity to a separate log file]'
  '--force-http-1.1[Force the use of HTTP 1.1 for all operations]'
  '--get-O365-drive-id[Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library]:'
  '--local-first[Synchronize from the local directory source first, before downloading changes from OneDrive.]'
  '--logout[Logout the current user]'
  '(-m --monitor)'{-m,--monitor}'[Keep monitoring for local and remote changes]'
  '--no-remote-delete[Do not delete local file deletes from OneDrive when using --upload-only]'
  '--print-token[Print the access token, useful for debugging]'
  '--resync[Forget the last saved state, perform a full sync]'
  '--remove-directory[Remove a directory on OneDrive - no sync will be performed.]:directory name:'
  '--single-directory[Specify a single local directory within the OneDrive root to sync.]:source directory:_files -/'
  '--skip-dot-files[Skip dot files and folders from syncing]'
  '--skip-symlinks[Skip syncing of symlinks]'
  '--source-directory[Source directory to rename or move on OneDrive - no sync will be performed.]:source directory:'
  '--syncdir[Specify the local directory used for synchronization to OneDrive]:sync directory:_files -/'
  '--synchronize[Perform a synchronization]'
  '--upload-only[Only upload to OneDrive, do not sync changes from OneDrive locally]'
  '(-v --verbose)'{-v,--verbose}'[Print more details, useful for debugging (repeat for extra debugging)]'
  '--version[Print the version and exit]'
  '(-h --help)'{-h,--help}'[Print help information]'
)

_arguments -S "$all_opts[@]" && return 0

