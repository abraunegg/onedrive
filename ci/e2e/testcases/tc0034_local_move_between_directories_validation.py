#!/usr/bin/env python3
"""
Test Case 0034: local move between directories validation

Move a file from one local directory to another without renaming it and
validate the remote result.

This validates path reclassification rather than rename semantics.
"""

import os
import shutil
from pathlib import Path

from .base import TestCaseBase


class TestCase0034LocalMoveBetweenDirectories(TestCaseBase):
    def run(self):
        self.log("Test Case 0034: local move between directories validation")

        sync_dir = Path(self.sync_dir)

        source_dir = sync_dir / "TestRoot" / "SourceDirectory"
        dest_dir = sync_dir / "TestRoot" / "DestinationDirectory"

        source_dir.mkdir(parents=True, exist_ok=True)
        dest_dir.mkdir(parents=True, exist_ok=True)

        source_file = source_dir / "move-me.txt"
        dest_file = dest_dir / "move-me.txt"

        # -------------------------
        # Phase 1: Seed
        # -------------------------
        self.log("Seeding initial file structure")

        source_file.write_text("original-content\n")

        # Anchor file to ensure destination exists everywhere
        (dest_dir / "anchor.txt").write_text("anchor\n")

        rc = self.run_onedrive("--sync", "--verbose", "--display-running-config")
        if rc != 0:
            return self.fail("Seed phase failed")

        # -------------------------
        # Phase 2: Local Move
        # -------------------------
        self.log("Performing local move between directories")

        shutil.move(str(source_file), str(dest_file))

        if source_file.exists():
            return self.fail("Source file still exists after move")

        if not dest_file.exists():
            return self.fail("Destination file missing after move")

        # -------------------------
        # Phase 3: Upload Change
        # -------------------------
        rc = self.run_onedrive("--sync", "--verbose", "--display-running-config")
        if rc != 0:
            return self.fail("Upload phase failed")

        # -------------------------
        # Phase 4: Validation (fresh client)
        # -------------------------
        self.log("Validating remote state via fresh client")

        validator_dir = self.create_isolated_workdir("validator")

        rc = self.run_onedrive(
            "--sync",
            "--verbose",
            "--display-running-config",
            sync_dir=validator_dir,
        )
        if rc != 0:
            return self.fail("Validation sync failed")

        v_source = validator_dir / "TestRoot" / "SourceDirectory" / "move-me.txt"
        v_dest = validator_dir / "TestRoot" / "DestinationDirectory" / "move-me.txt"

        if v_source.exists():
            return self.fail("File still present in source directory remotely")

        if not v_dest.exists():
            return self.fail("File not present in destination directory remotely")

        content = v_dest.read_text()
        if content != "original-content\n":
            return self.fail("File content mismatch after move")

        return self.pass_test()