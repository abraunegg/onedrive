from __future__ import annotations

import os
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, large_xlsx_relative


class TestCase0083DeltaChildrenReconciliationParity(MonitorModeTestCaseBase):
    """Compare tracked remote-move reconciliation using /delta and forced /children.

    The independent upload-only monitor is essential: moving a directory while
    that monitor is running preserves the existing remote DriveItem identity.
    Standalone upload/delete cycles would not test the same reconciliation path.
    """

    case_id = "0083"
    name = "delta and children remote directory reconciliation parity"
    description = (
        "Compare normal /delta and forced /children handling of a genuine remote "
        "populated-directory move, with tracked database state and fresh remote verification"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0083", ensure_refresh_token=True)
        failures: list[str] = []
        artifacts: list[str] = []
        details: dict[str, object] = {}
        metadata_file = layout.state_dir / "metadata.txt"

        for mode, force_children in (("CH-0001", False), ("CH-0002", True)):
            if not context.should_run_scenario(self.case_id, mode):
                continue
            scenario_work = layout.work_dir / mode
            scenario_logs = layout.log_dir / mode
            scenario_state = layout.state_dir / mode
            reset_directory(scenario_work)
            reset_directory(scenario_logs)
            reset_directory(scenario_state)

            subject_root = scenario_work / "subject-root"
            mutator_root = scenario_work / "mutator-root"
            verify_root = scenario_work / "verify-root"
            conf_subject = scenario_work / "conf-subject"
            conf_mutator = scenario_work / "conf-mutator"
            conf_verify = scenario_work / "conf-verify"
            app_logs = scenario_logs / "mutator-app-logs"
            for root in (subject_root, mutator_root, verify_root):
                reset_directory(root)

            root_name = f"ZZ_E2E_TC0083_{mode.replace('-', '')}_{context.run_id}_{os.getpid()}"
            source_relative = f"{root_name}/incoming/Populated"
            destination_relative = f"{root_name}/moved/Populated"
            moved_text = f"{source_relative}/Nested/Deep/data.txt"
            moved_xlsx = f"{source_relative}/Nested/Deep/workbook.xlsx"
            expected_text = f"{destination_relative}/Nested/Deep/data.txt"
            expected_xlsx = f"{destination_relative}/Nested/Deep/workbook.xlsx"
            survivor = f"{root_name}/incoming/anchor.txt"
            destination_anchor = f"{root_name}/moved/anchor.txt"
            text_contents = "TC0083 tracked populated directory remote-move content\n"
            xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0083:{mode}"
            expected_files = {
                expected_text: text_contents,
                survivor: "TC0083 incoming anchor\n",
                destination_anchor: "TC0083 destination anchor\n",
            }
            expected_manifest = sorted([
                f"{root_name}/", f"{root_name}/incoming/", f"{root_name}/moved/",
                f"{destination_relative}/", f"{destination_relative}/Nested/",
                f"{destination_relative}/Nested/Deep/", expected_text,
                expected_xlsx, large_xlsx_relative(expected_xlsx), survivor, destination_anchor,
            ])

            # The subject must NOT use --single-directory: that option itself
            # selects /children, masking any difference between these modes.
            subject_config = (
                f'# tc0083 {mode} receiver\n'
                f'sync_dir = "{subject_root}"\n'
                'bypass_data_preservation = "false"\n'
                f'force_children_scan = "{str(force_children).lower()}"\n'
            )
            context.prepare_minimal_config_dir(conf_subject, subject_config)
            write_text_file(conf_subject / "sync_list", f"/{root_name}\n")
            context.prepare_minimal_config_dir(
                conf_mutator,
                self._build_config_text(mutator_root, app_logs),
            )
            context.prepare_minimal_config_dir(
                conf_verify,
                f'# tc0083 {mode} independent verifier\n'
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n',
            )
            write_text_file(mutator_root / moved_text, text_contents)
            write_text_file(mutator_root / survivor, expected_files[survivor])
            write_text_file(mutator_root / destination_anchor, expected_files[destination_anchor])
            create_random_xlsx_pair(
                mutator_root / moved_xlsx, xlsx_seed,
                revision=REVISION_0, payload_rows=32,
                title="TC0083 remote directory move workbook",
            )

            phase_names = ("seed", "subject_initial", "mutator_monitor", "subject_reconcile", "subject_converge", "verify")
            phase_files = {
                phase: (scenario_logs / f"{phase}_stdout.log", scenario_logs / f"{phase}_stderr.log")
                for phase in phase_names
            }
            artifacts.extend(str(p) for pair in phase_files.values() for p in pair)
            artifacts.extend([
                str(conf_subject / "sync_list"), str(app_logs),
                str(scenario_state / "subject_manifest.txt"),
                str(scenario_state / "verify_manifest.txt"),
                str(scenario_state / "metadata.txt"),
            ])
            scenario_details: dict[str, object] = {
                "mode": mode, "force_children_scan": force_children,
                "root_name": root_name, "source": source_relative,
                "destination": destination_relative,
                "subject_database": str(conf_subject / "items.sqlite3"),
            }
            details[mode] = scenario_details

            def phase_run(phase: str, command: list[str]):
                context.log(f"Executing Test Case {self.case_id} {mode} {phase}: {command_to_string(command)}")
                result = run_command(command, cwd=context.repo_root)
                write_text_file(phase_files[phase][0], result.stdout)
                write_text_file(phase_files[phase][1], result.stderr)
                scenario_details[f"{phase}_returncode"] = result.returncode
                scenario_details[f"{phase}_command"] = command_to_string(command)
                return result

            def fail(reason: str) -> None:
                failures.append(f"{mode}: {reason}")
                self.write_metadata(scenario_state / "metadata.txt", scenario_details)

            seed = phase_run("seed", [
                context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
                "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                "--confdir", str(conf_mutator),
            ])
            if seed.returncode != 0 or not (conf_mutator / "items.sqlite3").is_file():
                fail("mutator seed failed or did not establish an item database")
                continue

            subject_command = [
                context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
                "--verbose", "--confdir", str(conf_subject),
            ]
            initial = phase_run("subject_initial", subject_command + ["--resync", "--resync-auth"])
            if initial.returncode != 0 or not (conf_subject / "items.sqlite3").is_file():
                fail("receiver initial download failed or did not establish an item database")
                continue
            if not (subject_root / moved_text).is_file() or not (subject_root / moved_xlsx).is_file() or not (subject_root / large_xlsx_relative(moved_xlsx)).is_file():
                fail("receiver did not establish the populated pre-move tree")
                continue
            if validate_xlsx_pair(subject_root / moved_xlsx, REVISION_0):
                fail("receiver initial XLSX validation failed")
                continue

            monitor_command = [
                context.onedrive_bin, "--display-running-config", "--monitor",
                "--upload-only", "--verbose", "--verbose", "--single-directory", root_name,
                "--confdir", str(conf_mutator),
            ]
            context.log(f"Executing Test Case {self.case_id} {mode} mutator monitor: {command_to_string(monitor_command)}")
            monitor, ready = self._launch_monitor_process(
                context, monitor_command, *phase_files["mutator_monitor"],
                startup_timeout_seconds=300,
            )
            scenario_details["mutator_monitor_initial_sync_complete"] = ready
            moved = False
            try:
                if ready:
                    start_offset = self._prepare_monitor_for_local_mutation(
                        monitor, phase_files["mutator_monitor"][0], scenario_details,
                    )
                    if scenario_details.get("monitor_ready_after_initial_sync"):
                        (mutator_root / source_relative).rename(mutator_root / destination_relative)
                        # The post-PATCH database-save record avoids racing the
                        # receiving client against an uncommitted remote move.
                        moved, segment = self._wait_for_stdout_growth_patterns(
                            phase_files["mutator_monitor"][0],
                            start_offset=start_offset,
                            required_patterns=[
                                f"[M] Local item moved: ./{source_relative} -> ./{destination_relative}",
                                f"Moving ./{source_relative} to ./{destination_relative}",
                                '"Populated", "", dir,',
                            ],
                            timeout_seconds=180,
                        )
                        scenario_details["mutator_move_segment_length"] = len(segment)
            finally:
                self._shutdown_monitor_process(monitor, scenario_details)
            scenario_details["remote_identity_preserving_move_confirmed"] = moved
            if not moved:
                fail("genuine monitored existing-item remote move was not confirmed")
                continue

            reconciled = phase_run("subject_reconcile", subject_command)
            if reconciled.returncode != 0:
                fail("receiver remote reconciliation failed")
                continue
            converged = phase_run("subject_converge", subject_command)
            if converged.returncode != 0:
                fail("receiver convergence run failed")
                continue
            verified = phase_run("verify", [
                context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
                "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                "--confdir", str(conf_verify),
            ])
            if verified.returncode != 0:
                fail("independent remote verification failed")
                continue

            subject_manifest = build_typed_manifest(subject_root)
            verify_manifest = build_typed_manifest(verify_root)
            write_manifest(scenario_state / "subject_manifest.txt", subject_manifest)
            write_manifest(scenario_state / "verify_manifest.txt", verify_manifest)
            scenario_details["subject_manifest"] = subject_manifest
            scenario_details["verify_manifest"] = verify_manifest
            if subject_manifest != expected_manifest or verify_manifest != expected_manifest:
                fail("receiver or independent remote manifest differs from expected moved tree")
                continue
            for root in (subject_root, verify_root):
                for relative, content in expected_files.items():
                    if (root / relative).read_text(encoding="utf-8") != content:
                        fail(f"content mismatch in {root.name}: {relative}")
                if validate_xlsx_pair(root / expected_xlsx, REVISION_0):
                    fail(f"XLSX structure/revision mismatch in {root.name}")
                if (root / source_relative).exists():
                    fail(f"stale source directory in {root.name}")
                if any("safeBackup" in p.name or ".partial" in p.name for p in root.rglob("*")):
                    fail(f"unexpected backup/partial artifact in {root.name}")
            for phase in ("subject_reconcile", "subject_converge"):
                combined = "\n".join((phase_files[phase][0].read_text(encoding="utf-8", errors="replace"),
                                       phase_files[phase][1].read_text(encoding="utf-8", errors="replace")))
                if any(s in combined for s in (
                    f"Successfully created the remote directory ./{source_relative}",
                    f"Successfully created the remote directory ./{destination_relative}",
                    f"Uploading file: ./{moved_text}",
                )):
                    fail(f"unintended remote mutation detected in {phase}")
            self.write_metadata(scenario_state / "metadata.txt", scenario_details)

        details["executed_scenarios"] = [key for key in ("CH-0001", "CH-0002") if key in details]
        details["failed_scenarios"] = failures
        self.write_metadata(metadata_file, details)
        artifacts.append(str(metadata_file))
        if not details["executed_scenarios"]:
            return self.fail_result(self.case_id, self.name, "no scenarios selected", artifacts, details)
        if failures:
            return self.fail_result(self.case_id, self.name, "; ".join(failures), artifacts, details)
        if len(details["executed_scenarios"]) == 2:
            left = details["CH-0001"].get("subject_manifest")
            right = details["CH-0002"].get("subject_manifest")
            # Root names differ by scenario; compare only paths underneath each root.
            if left is None or right is None or [p.split("/", 1)[-1] for p in left] != [p.split("/", 1)[-1] for p in right]:
                return self.fail_result(self.case_id, self.name, "delta/children relative manifests differ", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
