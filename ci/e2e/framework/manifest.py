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


def build_typed_manifest(root: Path) -> list[str]:
    """
    Build a deterministic manifest that preserves whether an entry is a file or
    directory by suffixing directories with '/'.
    """
    entries: list[str] = []

    if not root.exists():
        return entries

    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        if path.is_dir():
            rel += "/"
        entries.append(rel)

    return entries


def manifest_contains_prefix(entries: list[str], relative_path: str) -> bool:
    return any(entry == relative_path or entry.startswith(relative_path + "/") for entry in entries)


def write_manifest(path: Path, entries: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(entries) + ("\n" if entries else ""), encoding="utf-8")
