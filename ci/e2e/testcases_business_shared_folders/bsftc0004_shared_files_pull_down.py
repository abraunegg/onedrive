from __future__ import annotations

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file
from testcases_business_shared_folders.shared_folder_common import (
    REQUIRED_TYPED_MANIFEST_ENTRIES,
    case_sync_root,
    reset_local_sync_root,
    write_case_config,
    write_common_metadata,
)


def _dir(path: str) -> str:
    return path.rstrip("/") + "/"


def _dirs(*paths: str) -> list[str]:
    return [_dir(path) for path in paths]


def _files(prefix: str, names: list[str]) -> list[str]:
    return [f"{prefix.rstrip('/')}/{name}" for name in names]


REQUIRED_SHARED_FILE_TYPED_MANIFEST_ENTRIES = sorted(set(
    _dirs(
        "Files Shared With Me",
        "Files Shared With Me/Alex Braunegg (alex.braunegg@mynasau3.onmicrosoft.com)",
        "Files Shared With Me/testuser2 testuser2 (testuser2@mynasau3.onmicrosoft.com)",
        "Files Shared With Me/test user (testuser@mynasau3.onmicrosoft.com)",
    )
    + _files(
        "Files Shared With Me/Alex Braunegg (alex.braunegg@mynasau3.onmicrosoft.com)",
        ["new-local-file.txt"],
    )
    + _files(
        "Files Shared With Me/testuser2 testuser2 (testuser2@mynasau3.onmicrosoft.com)",
        ["dummy_file_to_share.docx"],
    )
    + _files(
        "Files Shared With Me/test user (testuser@mynasau3.onmicrosoft.com)",
        [
            "file to share.docx",
            "large_document_shared.docx",
            "no_download_access.docx",
        ],
    )
))


REQUIRED_SHARED_FILE_STDOUT_MARKERS = [
    "Account Type:          business",
    "Using Microsoft Graph Search API to enumerate OneDrive Business Shared Files",
    "Checking for any applicable OneDrive Business Shared Files which need to be synced locally",
    "Files Shared With Me/testuser2 testuser2 (testuser2@mynasau3.onmicrosoft.com)/dummy_file_to_share.docx",
    "Files Shared With Me/test user (testuser@mynasau3.onmicrosoft.com)/file to share.docx",
    "Files Shared With Me/test user (testuser@mynasau3.onmicrosoft.com)/large_document_shared.docx",
    "Files Shared With Me/test user (testuser@mynasau3.onmicrosoft.com)/no_download_access.docx",
    "Files Shared With Me/Alex Braunegg (alex.braunegg@mynasau3.onmicrosoft.com)/new-local-file.txt",
    "Sync with Microsoft OneDrive is complete",
]


class BusinessSharedFolderTestCase0004SharedFilesPullDown(E2ETestCase):
    case_id = "bsftc0004"
    name = "business shared files clean sync pull down"
    description = (
        "Validate that --sync --verbose --sync-shared-files pulls down the preserved "
        "Business Account shared-files topology into Files Shared With Me"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name=self.case_id,
            ensure_refresh_token=True,
        )

        sync_root = case_sync_root(self.case_id)
        confdir = layout.work_dir / "conf"
        reset_local_sync_root(sync_root)
        write_case_config(context, confdir, self.case_id)

        stdout_file = layout.log_dir / "stdout.log"
        stderr_file = layout.log_dir / "stderr.log"
        manifest_file = layout.state_dir / "local_typed_manifest.txt"
        expected_manifest_file = layout.state_dir / "expected_required_typed_manifest.txt"
        missing_manifest_file = layout.state_dir / "missing_expected_entries.txt"
        missing_shared_file_manifest_file = layout.state_dir / "missing_expected_shared_file_entries.txt"
        missing_stdout_markers_file = layout.state_dir / "missing_stdout_markers.txt"
        metadata_file = layout.state_dir / "metadata.txt"

        command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--sync-shared-files",
            "--confdir",
            str(confdir),
        ]

        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)

        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        validation = self._validate_manifest_and_stdout(
            sync_root=sync_root,
            stdout_text=result.stdout,
            manifest_file=manifest_file,
            expected_manifest_file=expected_manifest_file,
            missing_manifest_file=missing_manifest_file,
            missing_shared_file_manifest_file=missing_shared_file_manifest_file,
            missing_stdout_markers_file=missing_stdout_markers_file,
        )

        write_common_metadata(
            metadata_file,
            case_id=self.case_id,
            name=self.name,
            command=command,
            returncode=result.returncode,
            sync_root=sync_root,
            config_dir=confdir,
            validation=validation,
            extra_lines=[
                f"expected_shared_file_entries={validation['expected_shared_file_entries']}",
                f"missing_shared_file_entries={len(validation['missing_shared_file_entries'])}",
            ],
        )

        artifacts = [
            str(stdout_file),
            str(stderr_file),
            str(manifest_file),
            str(expected_manifest_file),
            str(missing_manifest_file),
            str(missing_shared_file_manifest_file),
            str(missing_stdout_markers_file),
            str(metadata_file),
        ]
        details = {
            "command": command,
            "returncode": result.returncode,
            "sync_root": str(sync_root),
            "config_dir": str(confdir),
            **validation,
        }

        if result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"onedrive exited with non-zero status {result.returncode}",
                artifacts,
                details,
            )

        reason = self._failure_reason(validation)
        if reason:
            return self.fail_result(self.case_id, self.name, reason, artifacts, details)

        return self.pass_result(self.case_id, self.name, artifacts, details)

    def _validate_manifest_and_stdout(
        self,
        *,
        sync_root,
        stdout_text: str,
        manifest_file,
        expected_manifest_file,
        missing_manifest_file,
        missing_shared_file_manifest_file,
        missing_stdout_markers_file,
    ) -> dict[str, object]:
        actual_manifest = build_typed_manifest(sync_root)
        expected_manifest = sorted(set(
            REQUIRED_TYPED_MANIFEST_ENTRIES
            + REQUIRED_SHARED_FILE_TYPED_MANIFEST_ENTRIES
        ))

        write_manifest(manifest_file, actual_manifest)
        write_manifest(expected_manifest_file, expected_manifest)

        actual_set = set(actual_manifest)
        expected_set = set(expected_manifest)
        shared_file_expected_set = set(REQUIRED_SHARED_FILE_TYPED_MANIFEST_ENTRIES)

        missing_entries = sorted(expected_set - actual_set)
        missing_shared_file_entries = sorted(shared_file_expected_set - actual_set)
        missing_stdout_markers = [
            marker for marker in REQUIRED_SHARED_FILE_STDOUT_MARKERS if marker not in stdout_text
        ]

        write_manifest(missing_manifest_file, missing_entries)
        write_manifest(missing_shared_file_manifest_file, missing_shared_file_entries)
        write_manifest(missing_stdout_markers_file, missing_stdout_markers)

        return {
            "expected_required_entries": len(expected_manifest),
            "expected_shared_file_entries": len(REQUIRED_SHARED_FILE_TYPED_MANIFEST_ENTRIES),
            "actual_entries": len(actual_manifest),
            "missing_entries": missing_entries,
            "missing_shared_file_entries": missing_shared_file_entries,
            "missing_stdout_markers": missing_stdout_markers,
        }

    def _failure_reason(self, validation: dict[str, object]) -> str:
        if validation["missing_stdout_markers"]:
            return "Expected Business Shared Files sync markers were not present in stdout"
        if validation["missing_shared_file_entries"]:
            return "Expected Business shared-files local paths were missing after --sync-shared-files"
        if validation["missing_entries"]:
            return "Expected Business shared-folder local paths were missing after sync"
        return ""
