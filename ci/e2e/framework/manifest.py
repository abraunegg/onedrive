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