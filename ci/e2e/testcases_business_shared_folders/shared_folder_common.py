from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.utils import command_to_string, ensure_directory, write_text_file


# Keep this suite intentionally focused on the canonical immutable Business
# Shared Folder fixture. This fixture intentionally contains a mix of:
#   - SharePoint-backed Business Shared Folders below Data/
#   - SharePoint-backed Business Shared Folders at the account root
#   - user-owned Business Shared Folders at the account root
#   - user-owned Business Shared Folders below a renamed container folder
#   - default-drive/owned content below Data/BSF_FILTER_MATRIX
#
# Do not replace this with a whole-account assertion unless the online fixture
# is intentionally changed. The backing Business account may contain other
# ad-hoc / legacy data; validating only this known immutable topology keeps the
# test deterministic while still proving the critical path handling.

def _dir(path: str) -> str:
    return path.rstrip("/") + "/"


def _files(prefix: str, names: list[str]) -> list[str]:
    return [f"{prefix.rstrip('/')}/{name}" for name in names]


def _dirs(*paths: str) -> list[str]:
    return [_dir(path) for path in paths]


REQUIRED_TYPED_MANIFEST_ENTRIES = sorted(set(
    _dirs(
        "Data",
        "Data/BSF_CORE",
        "Data/BSF_CORE/DATASET_A",
        "Data/BSF_CORE/DATASET_B",
        "Data/BSF_CORE/DATASET_B/empty-dir",
        "Data/BSF_CORE/DATASET_B/files",
        "Data/BSF_CORE/DATASET_B/nested",
        "Data/BSF_CORE/DATASET_B/nested/exclude",
        "Data/BSF_CORE/DATASET_B/nested/keep",
        "Data/BSF_CORE/DATASET_B/nested/upload-target",
        "Data/BSF_CORE/TOP_LEVEL",
        "Data/BSF_CORE/TOP_LEVEL/PROJECTS",
        "Data/BSF_CORE/TOP_LEVEL/PROJECTS/2026",
        "Data/BSF_CORE/TOP_LEVEL/PROJECTS/2026/Week10",
        "Data/BSF_FILTER_MATRIX",
        "Data/BSF_FILTER_MATRIX/CORE",
        "Data/BSF_FILTER_MATRIX/CORE/empty-dir",
        "Data/BSF_FILTER_MATRIX/CORE/files",
        "Data/BSF_FILTER_MATRIX/CORE/nested",
        "Data/BSF_FILTER_MATRIX/CORE/nested/exclude",
        "Data/BSF_FILTER_MATRIX/CORE/nested/keep",
        "Data/BSF_FILTER_MATRIX/CORE/nested/upload-target",
        "Data/BSF_FILTER_MATRIX/DEEP_SOURCE",
        "Data/BSF_FILTER_MATRIX/DEEP_SOURCE/L1",
        "Data/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/L2",
        "Data/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/L2/L3",
        "Data/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/L2/L3/upload-target",
        "Data/BSF_FILTER_MATRIX/MINIMAL",
        "Data/BSF_FILTER_MATRIX/RENAME_ME",
        "Data/BSF_FILTER_MATRIX/RENAME_ME/upload-target",
        "Data/BSF_FILTER_MATRIX/TREE",
        "Data/BSF_FILTER_MATRIX/TREE/A",
        "Data/BSF_FILTER_MATRIX/TREE/A/B",
        "Data/BSF_FILTER_MATRIX/TREE/A/B/C",
        "Data/BSF_FILTER_MATRIX/WIDE_SET",
        "Data/BSF_MIXED_FILES",
        "Data/BSF_MIXED_FILES/DATASET_A",
        "Data/BSF_MIXED_FILES/DATASET_B",
        "Data/BSF_MIXED_FILES/DATASET_B/L1",
        "Data/BSF_MIXED_FILES/DATASET_B/L1/L2",
        "Data/BSF_MIXED_FILES/DATASET_B/L1/L2/L3",
        "Data/BSF_MIXED_FILES/DATASET_B/L1/L2/L3/upload-target",
        "Data Monitoring - Documents",
        "Data Monitoring - Documents/Data Monitoring",
        "Data Monitoring - Documents/Data Monitoring/Updates",
        "Issue_3613 - Folder with ' in it",
        "Jenkins_1",
        "Jenkins_1/LatestBuilds",
        "Jenkins_1/LatestBuilds/8-11-2021",
        "Jenkins_1/LatestBuilds/9-11-2021",
        "Jenkins_1/LatestBuilds/today",
        "Jenkins_1/LatestBuilds/yesterday",
        "Jenkins_1/OldBuilds",
        "Jenkins_1/OldBuilds/7-11-2021",
        "Jenkins_1/upload_only",
        "Jenkins_2",
        "Jenkins_2/another_new_dir_renamed",
        "Jenkins_2/asdfasdfasdf",
        "Jenkins_2/different_set_of_data",
        "Jenkins_2/new_directory",
        "test user's files - Empty_Folder",
        "test user's files - Sub Folder 3",
        "test user's files - Sub Folder 3/awerqwerqwer",
        "User Shared Folders",
        "User Shared Folders/test user's files - Top Folder",
        "User Shared Folders/test user's files - Top Folder/Logging",
        "User Shared Folders/test user's files - Top Folder/samba4",
        "User Shared Folders/test user's files - Top Folder/samba4-dependancies",
        "User Shared Folders/test user's files - Top Folder/samba4-dependancies/Logging Update",
    )
    + _files(
        "Data/BSF_CORE/DATASET_A",
        ["Document1.docx", "image0.png", "image1.png", "image2.png", "image3.png", "image4.png"],
    )
    + _files("Data/BSF_CORE/DATASET_B", ["README.txt"])
    + _files("Data/BSF_CORE/DATASET_B/files", ["data.txt", "image0.png", "image1.png"])
    + _files("Data/BSF_CORE/DATASET_B/nested/exclude", ["exclude.txt"])
    + _files("Data/BSF_CORE/DATASET_B/nested/keep", ["keep.txt"])
    + _files("Data/BSF_CORE/TOP_LEVEL/PROJECTS/2026/Week10", ["debug_output.log"])
    + _files("Data/BSF_FILTER_MATRIX/CORE", ["README.txt"])
    + _files("Data/BSF_FILTER_MATRIX/CORE/files", ["data.txt", "image0.png", "image1.png"])
    + _files("Data/BSF_FILTER_MATRIX/CORE/nested/exclude", ["exclude.txt"])
    + _files("Data/BSF_FILTER_MATRIX/CORE/nested/keep", ["keep.txt"])
    + _files("Data/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/L2/L3", ["deepfile.txt"])
    + _files("Data/BSF_FILTER_MATRIX/MINIMAL", ["single.txt"])
    + _files("Data/BSF_FILTER_MATRIX/RENAME_ME", ["original.txt"])
    + _files("Data/BSF_FILTER_MATRIX/TREE/A/B/C", ["tree.txt"])
    + _files("Data/BSF_FILTER_MATRIX/WIDE_SET", [f"file{i:02d}.txt" for i in range(50)])
    + _files(
        "Data/BSF_MIXED_FILES/DATASET_A",
        [
            "Document2.docx",
            "Presentation1.pptx",
            "Presentation2.pptx",
            "Presentation3.pptx",
            "Presentation4.pptx",
            "Presentation5.pptx",
        ],
    )
    + _files("Data/BSF_MIXED_FILES/DATASET_B/L1/L2/L3", ["deepfile.txt"])
    + _files("Data Monitoring - Documents/Data Monitoring/Updates", ["debug_output.log"])
    + _files(
        "Issue_3613 - Folder with ' in it",
        ["file10.data", "file11.data", "file12.data", "file13.data", "file14.data", "local-file.txt"],
    )
    + _files("Jenkins_1/LatestBuilds/8-11-2021", ["dummy.file"])
    + _files("Jenkins_1/LatestBuilds/9-11-2021", ["dummy.file"])
    + _files("Jenkins_1/LatestBuilds/today", ["dummy.file"])
    + _files("Jenkins_1/LatestBuilds/yesterday", ["dummy.file"])
    + _files("Jenkins_1/OldBuilds/7-11-2021", ["dummy.file"])
    + _files("Jenkins_1/upload_only", ["asdfasdfasdf.txt"])
    + _files("Jenkins_2/another_new_dir_renamed", ["asdfasdfasdfasdfasdf.txt"])
    + _files("Jenkins_2/asdfasdfasdf", ["asdfasdfasd.txt"])
    + _files("Jenkins_2/different_set_of_data", ["file0.data"])
    + _files("Jenkins_2/new_directory", ["another_new_file.txt"])
    + _files("Jenkins_2", ["newfile.txt"])
    + _files("test user's files - Sub Folder 3/awerqwerqwer", [f"file{i}.data" for i in range(5)])
    + _files(
        "User Shared Folders/test user's files - Top Folder",
        ["asdfasdfasdf.txt", "FirstBackup.spg", "qewrqwerwqer.txt"],
    )
    + _files("User Shared Folders/test user's files - Top Folder/Logging", ["multidownload.d", "progressBar.d", "sync.d"])
    + _files("User Shared Folders/test user's files - Top Folder/samba4", ["samba-4.9.18-1.el6.src.rpm"])
    + _files(
        "User Shared Folders/test user's files - Top Folder/samba4-dependancies",
        [
            "cmocka-1.1.1-0.el7.src.rpm",
            "jansson-2.11-1.el6.src.rpm",
            "jansson-2.11-2.el7.src.rpm",
            "libldb-1.4.3-1.el6.src.rpm",
            "libldb-1.4.3-2.el6.src.rpm",
            "libldb-1.4.3-3.el6.src.rpm",
            "libldb-1.4.6-1.el6.src.rpm",
            "libldb-1.4.7-1.el6.src.rpm",
            "libldb-1.4.8-1.el6.src.rpm",
            "libldb-1.4.8-2.el6.src.rpm",
            "libtalloc-2.1.14-1.el6.src.rpm",
            "libtdb-1.3.16-1.el6.src.rpm",
            "libtevent-0.9.37-1.el6.src.rpm",
            "libtevent-0.9.37-2.el6.src.rpm",
            "lmdb-0.9.18-1.el6.src.rpm",
        ],
    )
    + _files(
        "User Shared Folders/test user's files - Top Folder/samba4-dependancies/Logging Update",
        ["dnotify.d", "log.d", "notify.d", "README.md"],
    )
))

REQUIRED_STDOUT_MARKERS = [
    'Account Type:          business',
    'Syncing this OneDrive Business Shared Folder: Data/BSF_CORE',
    'Syncing this OneDrive Business Shared Folder: Data/BSF_MIXED_FILES',
    'Syncing this OneDrive Business Shared Folder: Data Monitoring - Documents',
    "Syncing this OneDrive Business Shared Folder: Issue_3613 - Folder with ' in it",
    "Syncing this OneDrive Business Shared Folder: User Shared Folders/test user's files - Top Folder",
    "Syncing this OneDrive Business Shared Folder: test user's files - Empty_Folder",
    "Syncing this OneDrive Business Shared Folder: test user's files - Sub Folder 3",
    'Syncing this OneDrive Business Shared Folder: Jenkins_2',
    'Syncing this OneDrive Business Shared Folder: Jenkins_1',
    'Sync with Microsoft OneDrive is complete',
]


def case_sync_root(case_id: str) -> Path:
    home = os.environ.get("HOME", "").strip()
    if not home:
        raise RuntimeError("HOME is not set")
    return Path(home) / case_id


def reset_local_sync_root(sync_root: Path) -> None:
    if sync_root.exists():
        shutil.rmtree(sync_root)
    ensure_directory(sync_root)


def write_case_config(context: E2EContext, config_dir: Path, case_id: str) -> Path:
    """Create a per-test config directory using a per-test sync_dir under HOME."""
    sync_dir_config_value = f"~/{case_id}/"
    return context.prepare_minimal_config_dir(
        config_dir,
        f"# {case_id} Business Shared Folder config\n"
        f'sync_dir = "{sync_dir_config_value}"\n'
        'sync_business_shared_items = "true"\n'
        'threads = "2"\n'
    )


def wait_for_stdout_marker(stdout_file: Path, marker: str, timeout_seconds: int = 600, poll_interval: float = 0.5) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if stdout_file.exists():
            try:
                if marker in stdout_file.read_text(encoding="utf-8", errors="replace"):
                    return True
            except OSError:
                pass
        time.sleep(poll_interval)
    return False


def validate_required_manifest(
    *,
    sync_root: Path,
    stdout_text: str,
    manifest_file: Path,
    expected_manifest_file: Path,
    missing_manifest_file: Path,
) -> dict[str, object]:
    actual_manifest = build_typed_manifest(sync_root)
    expected_manifest = sorted(REQUIRED_TYPED_MANIFEST_ENTRIES)
    write_manifest(manifest_file, actual_manifest)
    write_manifest(expected_manifest_file, expected_manifest)

    actual_set = set(actual_manifest)
    expected_set = set(expected_manifest)
    missing_entries = sorted(expected_set - actual_set)
    write_manifest(missing_manifest_file, missing_entries)

    missing_stdout_markers = [
        marker for marker in REQUIRED_STDOUT_MARKERS if marker not in stdout_text
    ]

    return {
        "expected_required_entries": len(expected_manifest),
        "actual_entries": len(actual_manifest),
        "missing_entries": missing_entries,
        "missing_stdout_markers": missing_stdout_markers,
    }


def write_common_metadata(
    metadata_file: Path,
    *,
    case_id: str,
    name: str,
    command: list[str],
    returncode: int | None,
    sync_root: Path,
    config_dir: Path,
    validation: dict[str, object],
    extra_lines: list[str] | None = None,
) -> None:
    lines = [
        f"case_id={case_id}",
        f"name={name}",
        f"command={command_to_string(command)}",
        f"returncode={returncode}",
        f"sync_root={sync_root}",
        f"config_dir={config_dir}",
        f"expected_required_entries={validation['expected_required_entries']}",
        f"actual_entries={validation['actual_entries']}",
        f"missing_entries={len(validation['missing_entries'])}",
        f"missing_stdout_markers={validation['missing_stdout_markers']!r}",
    ]
    if extra_lines:
        lines.extend(extra_lines)
    write_text_file(metadata_file, "\n".join(lines) + "\n")


def manifest_failure_reason(validation: dict[str, object]) -> str:
    if validation["missing_stdout_markers"]:
        return "Expected Business Shared Folder sync markers were not present in stdout"
    if validation["missing_entries"]:
        return "Expected Business shared-folder local paths were missing after sync"
    return ""


def stop_monitor_process(process: subprocess.Popen, timeout_seconds: int = 30) -> int | None:
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=timeout_seconds)
    return process.returncode
