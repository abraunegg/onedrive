from __future__ import annotations

from pathlib import Path


def build_manifest(root: Path) -> list[str]:
    """
    Build a deterministic manifest of all files and directories beneath root.

    Paths are returned relative to root using POSIX separators.
    """
    entries: list[str] = []

    if not root.exists():
        return entries

    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        entries.append(rel)

    return entries


def write_manifest(path: Path, entries: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(entries) + ("\n" if entries else ""), encoding="utf-8")


def compare_manifest(
    actual_entries: list[str],
    expected_present: list[str],
    expected_absent: list[str],
) -> list[str]:
    """
    Compare actual manifest entries against expected present/absent paths.

    Returns a list of diff lines. Empty list means success.
    """
    diffs: list[str] = []
    actual_set = set(actual_entries)

    for expected in expected_present:
        if expected not in actual_set:
            diffs.append(f"MISSING expected path: {expected}")

    for unexpected in expected_absent:
        if unexpected in actual_set:
            diffs.append(f"FOUND unexpected path: {unexpected}")

    return diffs