from __future__ import annotations

import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, ensure_directory, run_command, write_text_file


EXPECTED_TYPED_MANIFEST = [
    "Documents/",
    "Family pictures/",
    "Family pictures/Annas pictures/",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image0.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image1.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image2.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image3.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image4.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image5.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image6.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image7.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image8.png",
    "Family pictures/Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image9.png",
    "Family pictures/Bens pictures/",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image0.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image1.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image2.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image3.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image4.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image5.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image6.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image7.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image8.png",
    "Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image9.png",
    "Getting started with OneDrive.pdf",
    "Pictures/",
]

REQUIRED_STDOUT_MARKERS = [
    "Account Type:          personal",
    "Syncing this OneDrive Personal Shared Folder: ./Family pictures/Annas pictures",
    "Syncing this OneDrive Personal Shared Folder: ./Family pictures/Bens pictures",
    "Sync with Microsoft OneDrive is complete",
]


class SharedFolderPersonalTestCase0001CleanSyncPullDown(E2ETestCase):
    case_id = "sfptc0001"
    name = "personal shared folders clean sync pull down"
    description = "Validate that --sync --verbose pulls down the preserved Personal Account shared-folder topology without ghost folders"

    def _reset_default_sync_dir(self, sync_root: Path) -> None:
        if sync_root.exists():
            shutil.rmtree(sync_root)
        ensure_directory(sync_root)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name=self.case_id,
            ensure_refresh_token=True,
        )

        sync_root = context.default_sync_dir
        self._reset_default_sync_dir(sync_root)

        stdout_file = layout.log_dir / "stdout.log"
        stderr_file = layout.log_dir / "stderr.log"
        manifest_file = layout.state_dir / "local_typed_manifest.txt"
        expected_manifest_file = layout.state_dir / "expected_typed_manifest.txt"
        missing_manifest_file = layout.state_dir / "missing_expected_entries.txt"
        unexpected_manifest_file = layout.state_dir / "unexpected_extra_entries.txt"
        metadata_file = layout.state_dir / "metadata.txt"

        command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
        ]

        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)

        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        actual_manifest = build_typed_manifest(sync_root)
        expected_manifest = sorted(EXPECTED_TYPED_MANIFEST)
        write_manifest(manifest_file, actual_manifest)
        write_manifest(expected_manifest_file, expected_manifest)

        actual_set = set(actual_manifest)
        expected_set = set(expected_manifest)
        missing_entries = sorted(expected_set - actual_set)
        unexpected_entries = sorted(actual_set - expected_set)
        write_manifest(missing_manifest_file, missing_entries)
        write_manifest(unexpected_manifest_file, unexpected_entries)

        missing_stdout_markers = [
            marker for marker in REQUIRED_STDOUT_MARKERS if marker not in result.stdout
        ]

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"name={self.name}",
                    f"command={command_to_string(command)}",
                    f"returncode={result.returncode}",
                    f"sync_root={sync_root}",
                    f"expected_entries={len(expected_manifest)}",
                    f"actual_entries={len(actual_manifest)}",
                    f"missing_entries={len(missing_entries)}",
                    f"unexpected_entries={len(unexpected_entries)}",
                    f"missing_stdout_markers={missing_stdout_markers!r}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(stdout_file),
            str(stderr_file),
            str(manifest_file),
            str(expected_manifest_file),
            str(missing_manifest_file),
            str(unexpected_manifest_file),
            str(metadata_file),
        ]
        details = {
            "command": command,
            "returncode": result.returncode,
            "sync_root": str(sync_root),
            "expected_entries": len(expected_manifest),
            "actual_entries": len(actual_manifest),
            "missing_entries": missing_entries,
            "unexpected_entries": unexpected_entries,
            "missing_stdout_markers": missing_stdout_markers,
        }

        if result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"onedrive exited with non-zero status {result.returncode}",
                artifacts,
                details,
            )

        if missing_stdout_markers:
            return self.fail_result(
                self.case_id,
                self.name,
                "Expected Personal Shared Folder sync markers were not present in stdout",
                artifacts,
                details,
            )

        if missing_entries:
            return self.fail_result(
                self.case_id,
                self.name,
                "Expected shared-folder local paths were missing after sync",
                artifacts,
                details,
            )

        if unexpected_entries:
            return self.fail_result(
                self.case_id,
                self.name,
                "Unexpected local paths were created after sync; possible ghost folder regression",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
