from __future__ import annotations

import shutil
from pathlib import Path

from framework.context import E2EContext


def _safe_path_fragment(value: str) -> str:
    text = str(value).strip().replace("\\", "/")
    text = text.strip("/")
    if not text:
        return "unknown"
    return "_".join(part for part in text.split("/") if part) or "unknown"


def capture_onedrive_databases(
    context: E2EContext,
    case_id: str,
    *,
    reason: str = "failure",
) -> list[str]:
    """
    Capture OneDrive item database files from the active E2E work root.

    The OneDrive client writes items.sqlite3 next to the refresh_token in the
    runtime --confdir. Those config directories are testcase/scenario specific
    and live under context.work_root for both the primary run and debug reruns.

    Capture from context.work_root rather than guessing a testcase-specific
    directory so this works consistently for:
      - normal account tests
      - SharePoint tests
      - Business tests
      - Personal 15-character driveId tests
      - Personal Shared Folder tests
      - primary failures and debug rerun failures
    """
    work_root = context.work_root
    if not work_root.exists():
        context.log(
            f"No OneDrive database capture performed for {case_id}: "
            f"work root does not exist: {work_root}"
        )
        return []

    run_label = _safe_path_fragment(context.run_label)
    reason_label = _safe_path_fragment(reason)
    case_label = _safe_path_fragment(case_id)

    capture_root = (
        context.state_dir
        / case_label
        / "_database_captures"
        / f"{run_label}-{reason_label}"
    )

    copied: list[str] = []
    for source in sorted(work_root.rglob("items.sqlite3*")):
        if not source.is_file():
            continue

        relative_source = source.relative_to(work_root)
        destination = capture_root / relative_source
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        copied.append(str(destination))

    if copied:
        context.log(
            f"Captured {len(copied)} OneDrive database file(s) for test case "
            f"{case_id} from {work_root} under {capture_root}"
        )
    else:
        context.log(
            f"No OneDrive database files found to capture for test case {case_id} "
            f"under active work root: {work_root}"
        )

    return copied
