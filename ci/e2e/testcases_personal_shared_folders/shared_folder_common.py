from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, ensure_directory, write_text_file


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
        f"# {case_id} Personal Shared Folder config\n"
        f'sync_dir = "{sync_dir_config_value}"\n'
        'threads = "2"\n'
    )


def wait_for_stdout_marker(stdout_file: Path, marker: str, timeout_seconds: int = 180, poll_interval: float = 0.5) -> bool:
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


def validate_expected_manifest(
    *,
    sync_root: Path,
    stdout_text: str,
    manifest_file: Path,
    expected_manifest_file: Path,
    missing_manifest_file: Path,
    unexpected_manifest_file: Path,
) -> dict[str, object]:
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
        marker for marker in REQUIRED_STDOUT_MARKERS if marker not in stdout_text
    ]

    return {
        "expected_entries": len(expected_manifest),
        "actual_entries": len(actual_manifest),
        "missing_entries": missing_entries,
        "unexpected_entries": unexpected_entries,
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
        f"expected_entries={validation['expected_entries']}",
        f"actual_entries={validation['actual_entries']}",
        f"missing_entries={len(validation['missing_entries'])}",
        f"unexpected_entries={len(validation['unexpected_entries'])}",
        f"missing_stdout_markers={validation['missing_stdout_markers']!r}",
    ]
    if extra_lines:
        lines.extend(extra_lines)
    write_text_file(metadata_file, "\n".join(lines) + "\n")


def manifest_failure_reason(validation: dict[str, object]) -> str:
    if validation["missing_stdout_markers"]:
        return "Expected Personal Shared Folder sync markers were not present in stdout"
    if validation["missing_entries"]:
        return "Expected shared-folder local paths were missing after sync"
    if validation["unexpected_entries"]:
        return "Unexpected local paths were created after sync; possible ghost folder regression"
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
