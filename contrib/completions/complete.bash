# BASH completion code for OneDrive Linux Client
# (c) 2019 Norbert Preining
# License: GPLv3+ (as with the rest of the OneDrive Linux client project)

_onedrive()
{
	local cur prev

	COMPREPLY=()
	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD-1]}

	options='--check-for-nomount --check-for-nosync --cleanup-local-files --debug-https --disable-notifications --display-config --display-quota --display-sync-status --disable-download-validation --disable-upload-validation --display-running-config --download-only --dry-run --enable-logging --force --force-http-11 --force-sync --list-shared-items --local-first --logout -m --monitor --no-remote-delete --print-access-token --reauth --remove-source-files --resync --resync-auth --skip-dir-strict-match --skip-dot-files --skip-symlinks -s --sync --sync-root-files --sync-shared-files --upload-only -v+ --verbose --version -h --help --with-editing-perms'
	argopts='--auth-files --auth-response --classify-as-big-delete --confdir --create-directory --create-share-link --destination-directory --get-O365-drive-id --get-file-link --get-sharepoint-drive-id --log-dir --modified-by --monitor-fullscan-frequency --monitor-interval --monitor-log-frequency --remove-directory --share-password --single-directory --skip-dir --skip-file --skip-size --source-directory --space-reservation --syncdir'

	# Loop on the arguments to manage conflicting options
	for (( i=0; i < ${#COMP_WORDS[@]}-1; i++ )); do
		#exclude some mutually exclusive options
		[[ ${COMP_WORDS[i]} == '--sync' ]] && options=${options/--monitor}
		[[ ${COMP_WORDS[i]} == '--monitor' ]] && options=${options/--synchronize}
	done

	case "$prev" in
	--confdir|--syncdir)
		_filedir
		return 0
		;;

	--get-file-link)
		if command -v sed &> /dev/null; then
			pushd "$(onedrive --display-config | sed -n "/sync_dir/s/.*= //p")" &> /dev/null
			_filedir
			popd &> /dev/null
		fi
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
