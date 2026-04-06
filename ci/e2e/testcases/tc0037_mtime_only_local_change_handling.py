from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Tuple

from framework import E2EContext, E2ETestCase, TestResult


class TestCase0037MtimeOnlyLocalChangeHandling(E2ETestCase):
    """
    tc0037 — mtime-only local change handling

    Create a file, upload it, then modify only the local mtime without changing
    content. Validate that:
      * sync completes successfully
      * no duplicate / backup / conflict artefacts are created
      * remote content remains unchanged
      * remote mtime does not move forward purely because the local mtime changed
      * the second sync does not attempt a content upload for the touched file
    """

    TEST_ID = "0037"
    TEST_NAME = "mtime-only local change handling"

    def run(self, context: E2EContext) -> TestResult:
        artifacts: List[str] = []

        try:
            testcase_root = Path(context.test_root) / "tc0037"
            seeder_root = testcase_root / "seeder"
            verifier_before_root = testcase_root / "verifier_before"
            verifier_after_root = testcase_root / "verifier_after"

            self._reset_dir(testcase_root)
            self._reset_dir(seeder_root)
            self._reset_dir(verifier_before_root)
            self._reset_dir(verifier_after_root)

            seeder_sync_dir = seeder_root / "sync_dir"
            verifier_before_sync_dir = verifier_before_root / "sync_dir"
            verifier_after_sync_dir = verifier_after_root / "sync_dir"

            seeder_sync_dir.mkdir(parents=True, exist_ok=True)
            verifier_before_sync_dir.mkdir(parents=True, exist_ok=True)
            verifier_after_sync_dir.mkdir(parents=True, exist_ok=True)

            target_relpath = Path("mtime-only.txt")
            seeder_target = seeder_sync_dir / target_relpath
            verifier_before_target = verifier_before_sync_dir / target_relpath
            verifier_after_target = verifier_after_sync_dir / target_relpath

            initial_content = (
                "tc0037 baseline file content\n"
                "This file is intentionally unchanged after initial upload.\n"
                "Only the local mtime will be modified.\n"
            )

            seeder_target.write_text(initial_content, encoding="utf-8")

            seeder_config_dir = seeder_root / "config"
            verifier_before_config_dir = verifier_before_root / "config"
            verifier_after_config_dir = verifier_after_root / "config"

            self._write_config(
                context=context,
                config_dir=seeder_config_dir,
                sync_dir=seeder_sync_dir,
                extra_config_lines=[],
            )
            self._write_config(
                context=context,
                config_dir=verifier_before_config_dir,
                sync_dir=verifier_before_sync_dir,
                extra_config_lines=[],
            )
            self._write_config(
                context=context,
                config_dir=verifier_after_config_dir,
                sync_dir=verifier_after_sync_dir,
                extra_config_lines=[],
            )

            #
            # Phase 1: upload baseline file
            #
            rc, stdout, stderr = self._run_onedrive(
                context=context,
                config_dir=seeder_config_dir,
                extra_args=["--sync", "--verbose"],
            )
            artifacts.extend(
                self._write_phase_artifacts(
                    testcase_root,
                    "phase1_seed_upload",
                    rc,
                    stdout,
                    stderr,
                )
            )
            if rc != 0:
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — initial upload failed with exit code {rc}",
                    artifacts=artifacts,
                )

            #
            # Phase 2: fresh verifier downloads remote baseline state
            #
            rc, stdout, stderr = self._run_onedrive(
                context=context,
                config_dir=verifier_before_config_dir,
                extra_args=["--sync", "--download-only", "--resync", "--resync-auth", "--verbose"],
            )
            artifacts.extend(
                self._write_phase_artifacts(
                    testcase_root,
                    "phase2_verify_remote_baseline",
                    rc,
                    stdout,
                    stderr,
                )
            )
            if rc != 0:
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — baseline verifier download failed with exit code {rc}",
                    artifacts=artifacts,
                )

            if not verifier_before_target.exists():
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — baseline verifier did not download {target_relpath}",
                    artifacts=artifacts,
                )

            baseline_remote_content = verifier_before_target.read_text(encoding="utf-8")
            if baseline_remote_content != initial_content:
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — baseline verifier content mismatch for {target_relpath}",
                    artifacts=artifacts,
                )

            baseline_remote_mtime = int(verifier_before_target.stat().st_mtime)

            #
            # Phase 3: touch local file only - no content change
            #
            touched_local_mtime = baseline_remote_mtime + 300
            os.utime(seeder_target, (touched_local_mtime, touched_local_mtime))

            local_content_after_touch = seeder_target.read_text(encoding="utf-8")
            if local_content_after_touch != initial_content:
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — local file content changed unexpectedly after mtime touch",
                    artifacts=artifacts,
                )

            #
            # Phase 4: normal sync after mtime-only change
            #
            rc, stdout, stderr = self._run_onedrive(
                context=context,
                config_dir=seeder_config_dir,
                extra_args=["--sync", "--verbose"],
            )
            artifacts.extend(
                self._write_phase_artifacts(
                    testcase_root,
                    "phase4_sync_after_mtime_touch",
                    rc,
                    stdout,
                    stderr,
                )
            )
            if rc != 0:
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — sync after mtime-only touch failed with exit code {rc}",
                    artifacts=artifacts,
                )

            upload_indicators = [
                f"Uploading new file {target_relpath.name}",
                f"Uploading differences of {target_relpath.name}",
                f"Uploading file {target_relpath.name}",
            ]
            combined_log = f"{stdout}\n{stderr}"
            matched_upload_indicators = [
                indicator for indicator in upload_indicators if indicator in combined_log
            ]
            if matched_upload_indicators:
                return TestResult.fail_result(
                    self.TEST_ID,
                    (
                        f"{self.TEST_NAME} — mtime-only change triggered upload behaviour "
                        f"for {target_relpath}: {', '.join(matched_upload_indicators)}"
                    ),
                    artifacts=artifacts,
                )

            unexpected_local_entries = self._find_unexpected_entries(
                seeder_sync_dir,
                allowed_relative_paths={str(target_relpath)},
            )
            if unexpected_local_entries:
                return TestResult.fail_result(
                    self.TEST_ID,
                    (
                        f"{self.TEST_NAME} — unexpected local artefacts created after mtime-only sync: "
                        f"{', '.join(unexpected_local_entries)}"
                    ),
                    artifacts=artifacts,
                )

            #
            # Phase 5: fresh verifier downloads final remote state
            #
            rc, stdout, stderr = self._run_onedrive(
                context=context,
                config_dir=verifier_after_config_dir,
                extra_args=["--sync", "--download-only", "--resync", "--resync-auth", "--verbose"],
            )
            artifacts.extend(
                self._write_phase_artifacts(
                    testcase_root,
                    "phase5_verify_remote_final_state",
                    rc,
                    stdout,
                    stderr,
                )
            )
            if rc != 0:
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — final verifier download failed with exit code {rc}",
                    artifacts=artifacts,
                )

            if not verifier_after_target.exists():
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — final verifier did not download {target_relpath}",
                    artifacts=artifacts,
                )

            final_remote_content = verifier_after_target.read_text(encoding="utf-8")
            if final_remote_content != initial_content:
                return TestResult.fail_result(
                    self.TEST_ID,
                    f"{self.TEST_NAME} — remote content changed after mtime-only local touch",
                    artifacts=artifacts,
                )

            final_remote_mtime = int(verifier_after_target.stat().st_mtime)

            if final_remote_mtime >= touched_local_mtime:
                return TestResult.fail_result(
                    self.TEST_ID,
                    (
                        f"{self.TEST_NAME} — remote mtime moved forward to {final_remote_mtime} "
                        f"after local mtime-only touch at {touched_local_mtime}"
                    ),
                    artifacts=artifacts,
                )

            if abs(final_remote_mtime - baseline_remote_mtime) > 2:
                return TestResult.fail_result(
                    self.TEST_ID,
                    (
                        f"{self.TEST_NAME} — remote mtime changed unexpectedly: "
                        f"baseline={baseline_remote_mtime}, final={final_remote_mtime}"
                    ),
                    artifacts=artifacts,
                )

            metadata = {
                "testcase": self.TEST_ID,
                "target_relpath": str(target_relpath),
                "baseline_remote_mtime": baseline_remote_mtime,
                "touched_local_mtime": touched_local_mtime,
                "final_remote_mtime": final_remote_mtime,
                "baseline_remote_content_length": len(baseline_remote_content),
                "final_remote_content_length": len(final_remote_content),
            }
            metadata_path = testcase_root / "tc0037_metadata.json"
            metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True), encoding="utf-8")
            artifacts.append(str(metadata_path))

            return TestResult.pass_result(
                self.TEST_ID,
                (
                    f"{self.TEST_NAME} — mtime-only local change was ignored as expected; "
                    f"content remained unchanged and remote mtime was not updated"
                ),
                artifacts=artifacts,
            )

        except Exception as exc:
            return TestResult.fail_result(
                self.TEST_ID,
                f"{self.TEST_NAME} — unhandled exception: {exc}",
                artifacts=artifacts,
            )

    def _run_onedrive(
        self,
        context: E2EContext,
        config_dir: Path,
        extra_args: List[str],
    ) -> Tuple[int, str, str]:
        command = [str(context.onedrive_path), "--confdir", str(config_dir)]
        command.extend(extra_args)

        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        return completed.returncode, completed.stdout, completed.stderr

    def _write_phase_artifacts(
        self,
        testcase_root: Path,
        phase_name: str,
        returncode: int,
        stdout: str,
        stderr: str,
    ) -> List[str]:
        phase_dir = testcase_root / "artifacts" / phase_name
        phase_dir.mkdir(parents=True, exist_ok=True)

        stdout_path = phase_dir / "stdout.log"
        stderr_path = phase_dir / "stderr.log"
        rc_path = phase_dir / "returncode.txt"

        stdout_path.write_text(stdout, encoding="utf-8")
        stderr_path.write_text(stderr, encoding="utf-8")
        rc_path.write_text(str(returncode), encoding="utf-8")

        return [str(stdout_path), str(stderr_path), str(rc_path)]

    def _find_unexpected_entries(self, root: Path, allowed_relative_paths: set[str]) -> List[str]:
        unexpected: List[str] = []

        for path in sorted(root.rglob("*")):
            if path.is_dir():
                continue
            rel = str(path.relative_to(root))
            if rel not in allowed_relative_paths:
                unexpected.append(rel)

        return unexpected

    def _reset_dir(self, path: Path) -> None:
        if path.exists():
            shutil.rmtree(path)
        path.mkdir(parents=True, exist_ok=True)