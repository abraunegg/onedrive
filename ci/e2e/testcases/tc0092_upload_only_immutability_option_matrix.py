from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import diff_tree_snapshots, snapshot_tree, write_tree_snapshot
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


@dataclass(frozen=True)
class UploadOnlyScenario:
    scenario_id: str
    local_first: bool
    disable_upload_validation: bool
    bypass_data_preservation: bool


class TestCase0092UploadOnlyImmutabilityOptionMatrix(SafeBackupCaseBase):
    case_id = "0092"
    name = "upload-only immutable local filesystem option matrix"
    description = (
        "Enforce local-tree immutability across source authority, upload validation "
        "and preservation bypass, with untracked collision, identical, zero-byte, "
        "new-local and remote-only TXT fixtures"
    )

    @staticmethod
    def _scenarios() -> list[UploadOnlyScenario]:
        # Fixed IDs allow a failed combination to be rerun in isolation.
        return [
            UploadOnlyScenario(f"UP-{index:04d}", local_first, validation_off, bypass)
            for index, (local_first, validation_off, bypass) in enumerate(
                (
                    (False, False, False),
                    (False, False, True),
                    (False, True, False),
                    (False, True, True),
                    (True, False, False),
                    (True, False, True),
                    (True, True, False),
                    (True, True, True),
                ), start=1,
            )
        ]

    @staticmethod
    def _remote_content(scenario_id: str) -> dict[str, bytes]:
        return {
            "different.txt": f"remote authoritative conflict {scenario_id}\n".encode(),
            "identical.txt": f"same bytes on both sides {scenario_id}\n".encode(),
            "empty.txt": b"",
            "remote-only.txt": f"remote-only must not be downloaded {scenario_id}\n".encode(),
        }

    @staticmethod
    def _local_content(scenario_id: str) -> dict[str, bytes]:
        return {
            "different.txt": f"local authoritative conflict {scenario_id}\n".encode(),
            "identical.txt": f"same bytes on both sides {scenario_id}\n".encode(),
            "empty.txt": b"",
            "local-only.txt": f"local-only must upload {scenario_id}\n".encode(),
        }

    @staticmethod
    def _write_files(root: Path, values: dict[str, bytes]) -> None:
        root.mkdir(parents=True, exist_ok=True)
        for filename, content in values.items():
            (root / filename).write_bytes(content)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0092", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir
        selected = [s for s in self._scenarios() if context.should_run_scenario(self.case_id, s.scenario_id)]
        if not selected:
            return self.fail_result(reason="No TC0092 scenarios selected", artifacts=[], details={})

        seed_root = work / "seedroot"
        conf_seed = work / "conf-seed"
        reset_directory(seed_root)
        root_prefix = f"ZZ_E2E_TC0092_{context.run_id}_{os.getpid()}"
        root_names = {s.scenario_id: f"{root_prefix}/{s.scenario_id}" for s in selected}
        for scenario in selected:
            self._write_files(seed_root / root_names[scenario.scenario_id], self._remote_content(scenario.scenario_id))
        self._prepare_config(context, conf_seed, seed_root)
        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        seed_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
            "--verbose", "--resync", "--resync-auth",
            "--single-directory", root_prefix, "--confdir", str(conf_seed),
        ]
        seeded = self._run_phase(
            context, label="seed matrix roots", command=seed_command,
            stdout_file=seed_stdout, stderr_file=seed_stderr,
        )
        artifacts: list[str] = [str(seed_stdout), str(seed_stderr)]
        details: dict[str, object] = {
            "selected_scenarios": [s.scenario_id for s in selected],
            "executed_scenario_ids": [],
            "failed_scenario_ids": [],
            "seed_returncode": seeded.returncode,
            "scenarios": {},
        }
        metadata_file = state / "metadata.txt"
        artifacts.append(str(metadata_file))
        if seeded.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"TC0092 remote fixture seed failed (status {seeded.returncode}); no option scenarios were run",
                artifacts=artifacts, details=details,
            )

        failures: list[str] = []
        for scenario in selected:
            sid = scenario.scenario_id
            name = root_names[sid]
            local_root = work / f"local-{sid}"
            conf_local = work / f"conf-{sid}"
            verify_root = work / f"verify-{sid}"
            conf_verify = work / f"verify-conf-{sid}"
            reset_directory(local_root)
            reset_directory(verify_root)

            # No local DB exists. This explicitly exercises the new-file collision
            # branch. Tracked collisions remain covered by the existing TC0068.
            self._write_files(local_root / name, self._local_content(sid))
            old_mtime = int(time.time()) - 3600
            for candidate in (local_root / name).iterdir():
                os.utime(candidate, (old_mtime, old_mtime))
            self._prepare_config(context, conf_local, local_root, extra_lines=[
                'upload_only = "true"',
                f'local_first = "{str(scenario.local_first).lower()}"',
                f'disable_upload_validation = "{str(scenario.disable_upload_validation).lower()}"',
                f'bypass_data_preservation = "{str(scenario.bypass_data_preservation).lower()}"',
            ])
            self._prepare_config(context, conf_verify, verify_root)

            before_file = state / f"{sid}_local_before.json"
            after_file = state / f"{sid}_local_after.json"
            repeat_file = state / f"{sid}_local_after_repeat.json"
            difference_file = state / f"{sid}_local_differences.txt"
            command_stdout, command_stderr = logs / f"{sid}_upload_stdout.log", logs / f"{sid}_upload_stderr.log"
            repeat_stdout, repeat_stderr = logs / f"{sid}_repeat_stdout.log", logs / f"{sid}_repeat_stderr.log"
            verify_stdout, verify_stderr = logs / f"{sid}_verify_stdout.log", logs / f"{sid}_verify_stderr.log"
            artifacts.extend(map(str, (
                before_file, after_file, repeat_file, difference_file,
                command_stdout, command_stderr, repeat_stdout, repeat_stderr,
                verify_stdout, verify_stderr,
            )))

            before = snapshot_tree(local_root)
            write_tree_snapshot(before_file, before)
            command = self._single_directory_command(
                context, root_name=name, config_dir=conf_local, mode="upload-only", verbose_count=2,
            )
            uploaded = self._run_phase(
                context, label=f"{sid} upload-only collision", command=command,
                stdout_file=command_stdout, stderr_file=command_stderr,
            )
            after = snapshot_tree(local_root)
            write_tree_snapshot(after_file, after)
            differences = diff_tree_snapshots(before, after)
            repeat_result = None
            if uploaded.returncode == 0 and not differences:
                repeat_result = self._run_phase(
                    context, label=f"{sid} unchanged repeat", command=command,
                    stdout_file=repeat_stdout, stderr_file=repeat_stderr,
                )
                after_repeat = snapshot_tree(local_root)
                write_tree_snapshot(repeat_file, after_repeat)
                differences.extend(diff_tree_snapshots(before, after_repeat))
            else:
                write_text_file(repeat_stdout, "SKIPPED: first upload-only run failed the immutability gate\n")
                write_text_file(repeat_stderr, "")
                write_text_file(repeat_file, '{"skipped": true, "reason": "first run failed"}\n')
            write_text_file(difference_file, "\n".join(differences) + ("\n" if differences else ""))

            verified = self._run_phase(
                context, label=f"{sid} independent remote verification",
                command=self._single_directory_command(
                    context, root_name=name, config_dir=conf_verify,
                    mode="download-only", resync=True,
                ),
                stdout_file=verify_stdout, stderr_file=verify_stderr,
            )
            remote_dir = verify_root / name
            remote_expected = self._remote_content(sid)
            remote_expected["different.txt"] = (
                self._local_content(sid)["different.txt"]
                if scenario.local_first else remote_expected["different.txt"]
            )
            remote_expected["local-only.txt"] = self._local_content(sid)["local-only.txt"]
            scenario_errors: list[str] = []
            if uploaded.returncode != 0:
                scenario_errors.append(f"upload exited {uploaded.returncode}")
            if repeat_result is not None and repeat_result.returncode != 0:
                scenario_errors.append(f"unchanged repeat exited {repeat_result.returncode}")
            if differences:
                scenario_errors.append(f"local tree mutated ({len(differences)} differences): {differences[0]}")
            unexpected_downloads = self._unexpected_download_activity(uploaded.stdout)
            if unexpected_downloads:
                scenario_errors.append(f"upload-only attempted download-side reconciliation: {unexpected_downloads}")
            if repeat_result is not None:
                unexpected_uploads = self._unexpected_upload_activity(repeat_result.stdout)
                if unexpected_uploads:
                    scenario_errors.append(f"unchanged repeat attempted uploads: {unexpected_uploads}")
                repeated_downloads = self._unexpected_download_activity(repeat_result.stdout)
                if repeated_downloads:
                    scenario_errors.append(f"unchanged repeat attempted download-side reconciliation: {repeated_downloads}")
            if verified.returncode != 0:
                scenario_errors.append(f"independent download exited {verified.returncode}")
            else:
                for relative, expected in remote_expected.items():
                    path = remote_dir / relative
                    if not path.is_file() or path.read_bytes() != expected:
                        scenario_errors.append(f"remote canonical {relative} does not match selected authority")
                remote_backup_paths = sorted(p.relative_to(remote_dir).as_posix() for p in remote_dir.rglob("*safeBackup*"))
                if remote_backup_paths:
                    scenario_errors.append(f"unexpected remote safeBackup: {remote_backup_paths[:4]}")

            record = {
                "local_first": scenario.local_first,
                "disable_upload_validation": scenario.disable_upload_validation,
                "bypass_data_preservation": scenario.bypass_data_preservation,
                "upload_returncode": uploaded.returncode,
                "repeat_returncode": repeat_result.returncode if repeat_result else "skipped_after_first_failure",
                "verify_returncode": verified.returncode,
                "local_immutability_differences": differences,
                "errors": scenario_errors,
            }
            details["scenarios"][sid] = record
            details["executed_scenario_ids"].append(sid)
            if scenario_errors:
                details["failed_scenario_ids"].append(sid)
                failures.append(f"{sid}: {'; '.join(scenario_errors[:3])}")
            self._write_metadata(metadata_file, details)

        details["scenario_count"] = len(details["executed_scenario_ids"])
        details["failed_scenarios"] = len(details["failed_scenario_ids"])
        self._write_metadata(metadata_file, details)
        if failures:
            return self.fail_result(
                reason=f"TC0092 {len(failures)}/{len(selected)} failed: " + " | ".join(failures[:4]),
                artifacts=artifacts, details=details,
            )
        return self.pass_result(artifacts=artifacts, details=details)
