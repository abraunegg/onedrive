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


# Keep this suite intentionally focused on the stable Business Shared Folder
# fixtures. The backing Business account contains other ad-hoc / legacy data;
# validating the entire account tree would make these tests brittle for no
# additional coverage value.
REQUIRED_TYPED_MANIFEST_ENTRIES = [
    'Documents/',
    'Documents/BSF_CORE/',
    'Documents/BSF_CORE/DATASET_A/',
    'Documents/BSF_CORE/DATASET_A/Document1.docx',
    'Documents/BSF_CORE/DATASET_A/image0.png',
    'Documents/BSF_CORE/DATASET_A/image1.png',
    'Documents/BSF_CORE/DATASET_A/image2.png',
    'Documents/BSF_CORE/DATASET_A/image3.png',
    'Documents/BSF_CORE/DATASET_A/image4.png',
    'Documents/BSF_CORE/DATASET_B/',
    'Documents/BSF_CORE/DATASET_B/README.txt',
    'Documents/BSF_CORE/DATASET_B/empty-dir/',
    'Documents/BSF_CORE/DATASET_B/files/',
    'Documents/BSF_CORE/DATASET_B/files/data.txt',
    'Documents/BSF_CORE/DATASET_B/files/image0.png',
    'Documents/BSF_CORE/DATASET_B/files/image1.png',
    'Documents/BSF_CORE/DATASET_B/nested/',
    'Documents/BSF_CORE/DATASET_B/nested/exclude/',
    'Documents/BSF_CORE/DATASET_B/nested/exclude/exclude.txt',
    'Documents/BSF_CORE/DATASET_B/nested/keep/',
    'Documents/BSF_CORE/DATASET_B/nested/keep/keep.txt',
    'Documents/BSF_CORE/DATASET_B/nested/upload-target/',
    'Documents/BSF_CORE/TOP_LEVEL/',
    'Documents/BSF_CORE/TOP_LEVEL/PROJECTS/',
    'Documents/BSF_CORE/TOP_LEVEL/PROJECTS/2026/',
    'Documents/BSF_CORE/TOP_LEVEL/PROJECTS/2026/Week10/',
    'Documents/BSF_CORE/TOP_LEVEL/PROJECTS/2026/Week10/debug_output.log',
    'Documents/BSF_FILTER_MATRIX/',
    'Documents/BSF_FILTER_MATRIX/CORE/',
    'Documents/BSF_FILTER_MATRIX/CORE/README.txt',
    'Documents/BSF_FILTER_MATRIX/CORE/empty-dir/',
    'Documents/BSF_FILTER_MATRIX/CORE/files/',
    'Documents/BSF_FILTER_MATRIX/CORE/files/data.txt',
    'Documents/BSF_FILTER_MATRIX/CORE/files/image0.png',
    'Documents/BSF_FILTER_MATRIX/CORE/files/image1.png',
    'Documents/BSF_FILTER_MATRIX/CORE/nested/',
    'Documents/BSF_FILTER_MATRIX/CORE/nested/exclude/',
    'Documents/BSF_FILTER_MATRIX/CORE/nested/exclude/exclude.txt',
    'Documents/BSF_FILTER_MATRIX/CORE/nested/keep/',
    'Documents/BSF_FILTER_MATRIX/CORE/nested/keep/keep.txt',
    'Documents/BSF_FILTER_MATRIX/CORE/nested/upload-target/',
    'Documents/BSF_FILTER_MATRIX/DEEP_SOURCE/',
    'Documents/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/',
    'Documents/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/L2/',
    'Documents/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/L2/L3/',
    'Documents/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/L2/L3/deepfile.txt',
    'Documents/BSF_FILTER_MATRIX/DEEP_SOURCE/L1/L2/L3/upload-target/',
    'Documents/BSF_FILTER_MATRIX/MINIMAL/',
    'Documents/BSF_FILTER_MATRIX/MINIMAL/single.txt',
    'Documents/BSF_FILTER_MATRIX/RENAME_ME/',
    'Documents/BSF_FILTER_MATRIX/RENAME_ME/original.txt',
    'Documents/BSF_FILTER_MATRIX/RENAME_ME/upload-target/',
    'Documents/BSF_FILTER_MATRIX/TREE/',
    'Documents/BSF_FILTER_MATRIX/TREE/A/',
    'Documents/BSF_FILTER_MATRIX/TREE/A/B/',
    'Documents/BSF_FILTER_MATRIX/TREE/A/B/C/',
    'Documents/BSF_FILTER_MATRIX/TREE/A/B/C/tree.txt',
    'Documents/BSF_FILTER_MATRIX/WIDE_SET/',
    *[f'Documents/BSF_FILTER_MATRIX/WIDE_SET/file{i:02d}.txt' for i in range(50)],
    'Documents/BSF_MIXED_FILES/',
    'Documents/BSF_MIXED_FILES/DATASET_A/',
    'Documents/BSF_MIXED_FILES/DATASET_A/Document2.docx',
    'Documents/BSF_MIXED_FILES/DATASET_A/Presentation1.pptx',
    'Documents/BSF_MIXED_FILES/DATASET_A/Presentation2.pptx',
    'Documents/BSF_MIXED_FILES/DATASET_A/Presentation3.pptx',
    'Documents/BSF_MIXED_FILES/DATASET_A/Presentation4.pptx',
    'Documents/BSF_MIXED_FILES/DATASET_A/Presentation5.pptx',
    'Documents/BSF_MIXED_FILES/DATASET_B/',
    'Documents/BSF_MIXED_FILES/DATASET_B/L1/',
    'Documents/BSF_MIXED_FILES/DATASET_B/L1/L2/',
    'Documents/BSF_MIXED_FILES/DATASET_B/L1/L2/L3/',
    'Documents/BSF_MIXED_FILES/DATASET_B/L1/L2/L3/deepfile.txt',
    'Documents/BSF_MIXED_FILES/DATASET_B/L1/L2/L3/upload-target/',
]

REQUIRED_STDOUT_MARKERS = [
    'Account Type:          business',
    # Only folders that the client identifies as shortcut-backed Business Shared
    # Folders are required to emit this marker. BSF_FILTER_MATRIX is validated
    # via manifest presence below, but the current online fixture is enumerated
    # as normal default-drive content rather than reported as a Business Shared
    # Folder marker in stdout.
    'Syncing this OneDrive Business Shared Folder: Documents/BSF_CORE',
    'Syncing this OneDrive Business Shared Folder: Documents/BSF_MIXED_FILES',
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
