from __future__ import annotations

import os
import shutil
import sqlite3
from contextlib import closing
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

    The same reconciliation pass also receives genuine online deletions and a
    genuine online content modification from the independent mutator, beside an
    untouched control tree. Both modes must apply the modification, leave the
    control tree and its database records intact, and converge without feedback.
    The receiver runs --download-only, so native /delta identifies the online
    deletions but deliberately retains the local copies and their records, while
    the generated /children response applies them through its syncStatus sweep.
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
            # Control tree. 'stable' is never touched online, so its files and database
            # records are the negative control. 'mutable' receives the genuine online
            # modification and deletions made by the independent mutator.
            stable_files = {
                f"{root_name}/control/stable/keep-a.txt": "TC0083 stable top-level control file\n",
                f"{root_name}/control/stable/Nested/keep-b.txt": "TC0083 stable nested control file\n",
            }
            mutable_survivor = f"{root_name}/control/mutable/keep-d.txt"
            changed_file = f"{root_name}/control/mutable/change-me.txt"
            changed_before = "TC0083 control content before the online modification\n"
            changed_after = "TC0083 control content after the online modification, which must be applied\n"
            deleted_files = {
                f"{root_name}/control/mutable/delete-me.txt": "TC0083 control file deleted online\n",
                f"{root_name}/control/mutable/RemoveTree/Deep/child.txt": "TC0083 control file inside a subtree deleted online\n",
            }
            deleted_directories = [
                f"{root_name}/control/mutable/RemoveTree",
                f"{root_name}/control/mutable/EmptyRemoved",
            ]
            deleted_paths = sorted([*deleted_files, *deleted_directories, f"{root_name}/control/mutable/RemoveTree/Deep"])
            expected_files.update({
                **stable_files,
                mutable_survivor: "TC0083 control file beside the online deletions\n",
                changed_file: changed_after,
            })
            control_manifest = [
                f"{root_name}/control/", f"{root_name}/control/stable/", f"{root_name}/control/stable/Nested/",
                f"{root_name}/control/mutable/", *stable_files, mutable_survivor, changed_file,
            ]
            expected_manifest = sorted([
                f"{root_name}/", f"{root_name}/incoming/", f"{root_name}/moved/",
                f"{destination_relative}/", f"{destination_relative}/Nested/",
                f"{destination_relative}/Nested/Deep/", expected_text,
                expected_xlsx, large_xlsx_relative(expected_xlsx), survivor, destination_anchor,
                *control_manifest,
            ])
            # A --download-only receiver using native /delta does not delete local data for
            # online deletions (only --cleanup-local-files would), so it retains these paths.
            deleted_manifest = [*deleted_files, f"{deleted_directories[0]}/", f"{deleted_directories[1]}/", f"{root_name}/control/mutable/RemoveTree/Deep/"]
            subject_expected_manifest = expected_manifest if force_children else sorted([*expected_manifest, *deleted_manifest])

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
            for relative, contents in {
                **stable_files, **deleted_files,
                mutable_survivor: expected_files[mutable_survivor],
                changed_file: changed_before,
            }.items():
                write_text_file(mutator_root / relative, contents)
            (mutator_root / deleted_directories[1]).mkdir(parents=True, exist_ok=True)
            create_random_xlsx_pair(
                mutator_root / moved_xlsx, xlsx_seed,
                revision=REVISION_0, payload_rows=32,
                title="TC0083 remote directory move workbook",
            )

            phase_names = (
                "seed", "subject_initial", "mutator_monitor", "mutator_changes",
                "subject_reconcile", "subject_converge", "verify",
            )
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
            initial_control_missing = [
                relative for relative in (
                    *stable_files, mutable_survivor, changed_file, *deleted_files, deleted_directories[1],
                ) if not (subject_root / relative).exists()
            ]
            if initial_control_missing:
                scenario_details["initial_control_missing"] = initial_control_missing
                fail("receiver did not establish the control tree before the online changes")
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

            # Genuine online deletions and a modification, made by the independent mutator
            # through its own tracked database. The receiver then reconciles them in the
            # same pass as the directory move.
            (mutator_root / list(deleted_files)[0]).unlink()
            shutil.rmtree(mutator_root / deleted_directories[0])
            (mutator_root / deleted_directories[1]).rmdir()
            write_text_file(mutator_root / changed_file, changed_after)
            mutator_changes = phase_run("mutator_changes", [
                context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
                "--verbose", "--single-directory", root_name, "--confdir", str(conf_mutator),
            ])
            if mutator_changes.returncode != 0:
                fail("independent mutator failed to apply the online deletions and modification")
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
            scenario_details["online_deleted_manifest"] = sorted(deleted_manifest)
            if subject_manifest != subject_expected_manifest or verify_manifest != expected_manifest:
                fail("receiver or independent remote manifest differs from expected moved tree")
                continue
            if not force_children:
                # Native /delta must still identify every online file deletion while retaining the local copy.
                reconcile_output = phase_files["subject_reconcile"][0].read_text(encoding="utf-8", errors="replace")
                unidentified = [
                    relative for relative in deleted_files
                    if f"Skipping local deletion for file {relative}" not in reconcile_output
                ]
                if unidentified:
                    scenario_details["online_deletions_not_identified"] = unidentified
                    fail("native /delta did not identify the online deletions for the download-only receiver")
            for root in (subject_root, verify_root):
                for relative, content in expected_files.items():
                    if (root / relative).read_text(encoding="utf-8") != content:
                        fail(f"content mismatch in {root.name}: {relative}")
                if validate_xlsx_pair(root / expected_xlsx, REVISION_0):
                    fail(f"XLSX structure/revision mismatch in {root.name}")
                if (root / source_relative).exists():
                    fail(f"stale source directory in {root.name}")
                present_deleted = [relative for relative in deleted_paths if (root / relative).exists()]
                if present_deleted and (force_children or root is verify_root):
                    scenario_details[f"{root.name}_deleted_paths_still_present"] = present_deleted
                    fail(f"online deletions were not applied in {root.name}")
                if any("safeBackup" in p.name or ".partial" in p.name for p in root.rglob("*")):
                    fail(f"unexpected backup/partial artifact in {root.name}")
            for phase in ("subject_reconcile", "subject_converge"):
                combined = "\n".join((phase_files[phase][0].read_text(encoding="utf-8", errors="replace"),
                                       phase_files[phase][1].read_text(encoding="utf-8", errors="replace")))
                if any(marker in combined for marker in (
                    "Uploading new file:", "Uploading changed file:",
                    "Uploading modified file:", "Uploading file:",
                    "Deleting item from Microsoft OneDrive:",
                    "Successfully deleted the item from Microsoft OneDrive",
                    "OneDrive Client requested to create this directory online:",
                    "Successfully created the remote directory",
                )):
                    fail(f"unintended remote mutation detected in {phase}")
            # The unchanged convergence pass must not download, recycle or delete anything in the
            # control tree. The check is limited to that tree because SharePoint may legitimately
            # re-download Office documents that it enriched after upload.
            converge_output = "\n".join((phase_files["subject_converge"][0].read_text(encoding="utf-8", errors="replace"),
                                         phase_files["subject_converge"][1].read_text(encoding="utf-8", errors="replace")))
            feedback = [
                line.strip() for line in converge_output.splitlines()
                if f"{root_name}/control" in line and any(marker in line for marker in (
                    "Downloading file:", "Moving this local file to the configured 'Recycle Bin'",
                    "Moving this local directory to the configured 'Recycle Bin'",
                    "Uploading new file:", "Uploading modified file:", "Deleting item from Microsoft OneDrive:",
                ))
            ]
            if feedback:
                scenario_details["converge_feedback_lines"] = feedback
                fail("the unchanged convergence pass performed unintended operations on the control tree")

            # Read the receiver database only after the client has exited, without modifying it.
            try:
                records = self._subtree_records(conf_subject / "items.sqlite3", root_name)
            except (sqlite3.Error, AssertionError) as exc:
                scenario_details["database_read_error"] = repr(exc)
                fail(f"receiver database could not be read after the client exited: {exc}")
                records = {}
            scenario_details["database_record_count"] = len(records)
            if records:
                missing_records = [path for path in (*stable_files, mutable_survivor, changed_file, destination_relative) if path not in records]
                lingering_records = [path for path in deleted_paths if path in records]
                untracked_retained = [path for path in deleted_paths if path not in records]
                out_of_sync = sorted(path for path, record in records.items() if record["syncStatus"] != "Y")
                if missing_records:
                    scenario_details["database_missing_records"] = missing_records
                    fail("records for untouched or moved items are missing from the receiver database")
                if force_children and lingering_records:
                    scenario_details["database_lingering_records"] = lingering_records
                    fail("records for items deleted online remain in the receiver database")
                if not force_children and untracked_retained:
                    # The retained local copies must stay tracked rather than become untracked local data.
                    scenario_details["database_untracked_retained_records"] = untracked_retained
                    fail("records for the local copies retained after online deletion are missing from the receiver database")
                if out_of_sync:
                    scenario_details["database_out_of_sync_records"] = out_of_sync
                    fail("receiver database records were left flagged as out-of-sync after convergence")
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
            # Root names differ by scenario; compare only paths underneath each root. The online
            # deletions are excluded because only CH-0001 retains them, as asserted above.
            retained = {p.split("/", 1)[-1] for p in details["CH-0001"].get("online_deleted_manifest", [])}
            if left is None or right is None or [
                p.split("/", 1)[-1] for p in left if p.split("/", 1)[-1] not in retained
            ] != [p.split("/", 1)[-1] for p in right if p.split("/", 1)[-1] not in retained]:
                return self.fail_result(self.case_id, self.name, "delta/children relative manifests differ", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)

    @staticmethod
    def _subtree_records(database: Path, root_name: str) -> dict[str, dict[str, object]]:
        # Return every database record beneath (and including) the test-owned root, keyed by its
        # path relative to the sync root. The database is opened read-only after the client has
        # exited, and its schema is never modified.
        with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as connection:
            connection.row_factory = sqlite3.Row
            roots = connection.execute(
                "SELECT driveId, id, name, type, syncStatus FROM item WHERE name = ? AND type = 'dir'", (root_name,),
            ).fetchall()
            if len(roots) != 1:
                raise AssertionError(f"expected exactly one database record for {root_name}, found {len(roots)}")
            records: dict[str, dict[str, object]] = {root_name: dict(roots[0])}
            pending = [(roots[0]["driveId"], roots[0]["id"], root_name)]
            while pending:
                drive_id, item_id, path = pending.pop()
                for child in connection.execute(
                    "SELECT driveId, id, name, type, syncStatus FROM item WHERE driveId = ? AND parentId = ?",
                    (drive_id, item_id),
                ).fetchall():
                    child_path = f"{path}/{child['name']}"
                    records[child_path] = dict(child)
                    if child["type"] != "file":
                        pending.append((child["driveId"], child["id"], child_path))
        return records
