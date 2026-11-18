#!/usr/bin/env python3
"""Fail closed before publishing E2E artifacts containing authentication state.

The OneDrive client keeps its OAuth refresh token in a file named
``refresh_token``. That file is not a diagnostic artifact. Tests must store
authentication directories under E2EContext.work_root, never under out/.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def check_artifact_dir(root: Path) -> list[str]:
    """Return unsafe relative artifact entries without reading their contents."""
    if not root.is_dir() or root.is_symlink():
        return ["artifact directory missing or a symbolic link"]

    unsafe: list[str] = []
    # Do not follow symlinks: an artifact link could point to a private token.
    for path in root.rglob("*"):
        if path.is_symlink():
            unsafe.append(f"symbolic link: {path.relative_to(root)}")
        elif path.name.casefold() == "refresh_token":
            unsafe.append(f"authentication file: {path.relative_to(root)}")
    return sorted(unsafe)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    args = parser.parse_args()

    unsafe = check_artifact_dir(args.artifact_dir)
    if unsafe:
        print("ERROR: E2E artifact upload blocked; unsafe entries detected:", file=sys.stderr)
        for item in unsafe:
            print(f"  {item}", file=sys.stderr)
        return 1

    print("PASS: E2E artifact directory contains no refresh_token files or symlinks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
