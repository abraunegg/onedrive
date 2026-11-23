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


def snapshot_tree(root: Path) -> dict[str, dict[str, object]]:
    """Capture the local payload tree without following symlinks.

    Unlike build_manifest(), this also detects in-place writes, timestamp and
    permission changes.  Atime is deliberately excluded: taking a SHA-256
    snapshot itself may update atime on filesystems without noatime.
    Include '.' so changes to the sync-root directory are not overlooked.
    """
    import hashlib
    import os
    import stat

    result: dict[str, dict[str, object]] = {}
    if not root.is_dir():
        raise RuntimeError(f"Local immutability root is missing: {root}")

    for path in [root, *sorted(root.rglob("*"))]:
        info = path.lstat()
        entry: dict[str, object] = {
            "mode": stat.S_IMODE(info.st_mode),
            "mtime_ns": info.st_mtime_ns,
            "ctime_ns": info.st_ctime_ns,
        }
        if stat.S_ISDIR(info.st_mode):
            entry["type"] = "directory"
        elif stat.S_ISLNK(info.st_mode):
            entry["type"] = "symlink"
            entry["target"] = os.readlink(path)
        elif stat.S_ISREG(info.st_mode):
            entry["type"] = "file"
            entry["size"] = info.st_size
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(block)
            entry["sha256"] = digest.hexdigest()
        else:
            entry["type"] = "special"
            entry["file_mode"] = stat.S_IFMT(info.st_mode)
        result["." if path == root else path.relative_to(root).as_posix()] = entry
    return result


def diff_tree_snapshots(
    before: dict[str, dict[str, object]],
    after: dict[str, dict[str, object]],
) -> list[str]:
    """Return actionable, deterministic mismatches between two local trees."""
    messages: list[str] = []
    for relative in sorted(set(before) | set(after)):
        if relative not in before:
            messages.append(f"CREATED {relative}: {after[relative]}")
        elif relative not in after:
            messages.append(f"REMOVED {relative}: {before[relative]}")
        else:
            for field in sorted(set(before[relative]) | set(after[relative])):
                old = before[relative].get(field)
                new = after[relative].get(field)
                if old != new:
                    messages.append(f"CHANGED {relative} {field}: {old!r} -> {new!r}")
    return messages


def write_tree_snapshot(path: Path, entries: dict[str, dict[str, object]]) -> None:
    """Write immutable-tree evidence alongside the existing manifest artifacts."""
    import json

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entries, indent=2, sort_keys=True) + "\n", encoding="utf-8")
