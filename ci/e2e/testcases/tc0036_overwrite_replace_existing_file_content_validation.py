#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Test Case 0036: overwrite / replace existing file content validation

Create a file, sync it, then replace its contents locally with the same name
and validate that the remote item content updates correctly without metadata confusion.
"""

import os
from .base import TestCaseBase


class TestCase0036OverwriteReplaceExistingFileContentValidation(TestCaseBase):

    def run(self):
        self.log("Starting Test Case 0036: overwrite / replace existing file content validation")

        test_root = self.get_testcase_root_dir()

        file_path = os.path.join(test_root, "replace-me.txt")

        # ------------------------------------------------------------------
        # Phase 1: Create initial file
        # ------------------------------------------------------------------
        initial_content = "INITIAL_CONTENT_TC0036\n"
        self.write_file(file_path, initial_content)

        self.log(f"Created initial file: {file_path}")

        # ------------------------------------------------------------------
        # Phase 2: Sync initial content upstream
        # ------------------------------------------------------------------
        self.run_onedrive_sync()

        self.assert_remote_item_exists("replace-me.txt")

        # ------------------------------------------------------------------
        # Phase 3: Overwrite local file with new content
        # ------------------------------------------------------------------
        replacement_content = "REPLACED_CONTENT_TC0036\n"
        self.write_file(file_path, replacement_content)

        self.log("Overwrote local file with new content")

        # ------------------------------------------------------------------
        # Phase 4: Sync updated content upstream
        # ------------------------------------------------------------------
        self.run_onedrive_sync()

        # ------------------------------------------------------------------
        # Phase 5: Validate via fresh download-only instance
        # ------------------------------------------------------------------
        validator_dir = self.create_secondary_sync_dir()

        self.run_onedrive(
            [
                "--download-only",
                "--syncdir", validator_dir,
                "--resync",
                "--resync-auth",
                "--verbose",
                "--verbose",
                "--display-running-config"
            ]
        )

        validator_file = os.path.join(validator_dir, os.path.basename(test_root), "replace-me.txt")

        # ------------------------------------------------------------------
        # Assertions
        # ------------------------------------------------------------------
        if not os.path.exists(validator_file):
            raise Exception("Validated file does not exist after download")

        content = self.read_file(validator_file)

        if replacement_content not in content:
            raise Exception(
                "Replacement content not found in downloaded file - overwrite did not propagate"
            )

        if initial_content in content:
            raise Exception(
                "Initial content still present after overwrite - content replacement failed"
            )

        # Ensure only expected file exists
        files = self.list_all_files(validator_dir)

        expected_relative = os.path.join(os.path.basename(test_root), "replace-me.txt")

        if expected_relative not in files:
            raise Exception("Expected file missing from validator directory structure")

        if len(files) != 1:
            raise Exception(f"Unexpected files present after overwrite test: {files}")

        self.log("Test Case 0036 completed successfully")