#!/bin/bash
#
# BASH completion code for OneDrive Linux Client
# (c) 2019 Norbert Preining
# License: GPLv3+ (as with the rest of the OneDrive Linux client project)

_onedrive()
{
	local cur prev

	COMPREPLY=()
	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD-1]}

	options='--check-for-nomount --check-for-nosync --debug-https --disable-notifications --display-config --display-sync-status --download-only --disable-upload-validation --dry-run --enable-logging --force-http-1.1 --force-http-2 --local-first --logout -m --monitor --no-remote-delete --print-token --resync --skip-dot-files --skip-symlinks --synchronize --upload-only -v --verbose --version -h --help'
	argopts='--create-directory --get-O365-drive-id --remove-directory --single-directory --source-directory'

	# Loop on the arguments to manage conflicting options
	for (( i=0; i < ${#COMP_WORDS[@]}-1; i++ )); do
		#exclude some mutually exclusive options
		[[ ${COMP_WORDS[i]} == '--synchronize' ]] && options=${options/--monitor}
		[[ ${COMP_WORDS[i]} == '--monitor' ]] && options=${options/--synchronize}
	done
    
	case "$prev" in
	--confdir|--syncdir)
		_filedir
		return 0
		;;
	--create-directory|--get-O365-drive-id|--remove-directory|--single-directory|--source-directory)
		return 0
		;;
	*)
		COMPREPLY=( $( compgen -W "$options $argopts" -- "$cur"))
		return 0
		;;
	esac
	
	# notreached
	return 0
}
complete -F _onedrive onedrive
