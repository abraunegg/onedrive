from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0082SingleDirectoryDeleteReconciliation(E2ETestCase):
    case_id = "0082"
    name = "single-directory tracked deletion reconciliation"
    description = (
        "Validate that a scoped sync propagates tracked file and nested-directory "
        "deletions without restoring removed paths or changing surviving content"
    )

    # SD-0002 is the only gated scenario. The original local-deletion flow is always run.
    REMOTE_SCENARIO_ID = "SD-0002"
    FEEDBACK_MARKERS = (
        "Downloading file:", "Uploading new file:", "Uploading modified file:",
        "Deleting item from Microsoft OneDrive:",
        "Moving this local file to the configured 'Recycle Bin'",
        "Moving this local directory to the configured 'Recycle Bin'",
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0082", ensure_refresh_token=True)
        work_dir = layout.work_dir
        log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = work_dir / "syncroot"
        verify_root = work_dir / "verifyroot"
        conf_main = work_dir / "conf-main"
        conf_verify = work_dir / "conf-verify"
        root_name = f"ZZ_E2E_TC0082_{context.run_id}_{os.getpid()}"

        # These paths are all below the test-owned --single-directory scope.
        keep_files = {
            f"{root_name}/anchor.txt": "TC0082 anchor remains present\n",
            f"{root_name}/Survivor/Nested/keep.txt": "TC0082 nested survivor remains present\n",
        }
        deleted_files = {
            f"{root_name}/delete-top.txt": "TC0082 tracked top-level deletion\n",
            f"{root_name}/Survivor/delete-inside.txt": "TC0082 tracked nested deletion\n",
            f"{root_name}/RemoveTree/Deep/child.txt": "TC0082 tracked subtree deletion\n",
        }
        deleted_directories = [
            f"{root_name}/RemoveTree",
            f"{root_name}/EmptyToRemove",
        ]
        expected_final = sorted([
            f"{root_name}/",
            f"{root_name}/anchor.txt",
            f"{root_name}/Survivor/",
            f"{root_name}/Survivor/Nested/",
            f"{root_name}/Survivor/Nested/keep.txt",
        ])
        forbidden = list(deleted_files) + deleted_directories

        context.prepare_minimal_config_dir(
            conf_main,
            f'# tc0082 subject config\nsync_dir = "{sync_root}"\n'
            'bypass_data_preservation = "true"\n',
        )
        context.prepare_minimal_config_dir(
            conf_verify,
            f'# tc0082 verifier config\nsync_dir = "{verify_root}"\n'
            'bypass_data_preservation = "true"\n',
        )

        for relative, contents in {**keep_files, **deleted_files}.items():
            write_text_file(sync_root / relative, contents)
        (sync_root / root_name / "EmptyToRemove").mkdir(parents=True, exist_ok=True)

        phase_names = ("seed", "delete", "convergence", "verify")
        artifacts = [str(log_dir / f"{phase}_{stream}.log")
                     for phase in phase_names for stream in ("stdout", "stderr")]
        artifacts.extend(str(state_dir / name) for name in (
            "seed_manifest.txt", "mutated_manifest.txt", "final_manifest.txt",
            "remote_manifest.txt", "metadata.txt",
        ))
        details: dict[str, object] = {"root_name": root_name, "deleted_paths": forbidden}
        metadata_file = state_dir / "metadata.txt"

        subject_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--single-directory", root_name, "--confdir", str(conf_main),
        ]
        verify_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
            "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_verify),
        ]

        # Use the same run_command + captured stdout/stderr pattern as TC0040.
        # The subject deliberately retains its database between all three syncs.
        for phase in phase_names:
            if phase == "delete":
                for relative in deleted_files:
                    (sync_root / relative).unlink()
                shutil.rmtree(sync_root / deleted_directories[0])
                (sync_root / deleted_directories[1]).rmdir()
                write_manifest(state_dir / "mutated_manifest.txt", build_typed_manifest(sync_root))
            if phase == "convergence":
                write_manifest(state_dir / "final_manifest.txt", build_typed_manifest(sync_root))

            command = verify_command if phase == "verify" else subject_command
            context.log(f"Executing Test Case {self.case_id} {phase}: {command_to_string(command)}")
            result = run_command(command, cwd=context.repo_root)
            write_text_file(log_dir / f"{phase}_stdout.log", result.stdout)
            write_text_file(log_dir / f"{phase}_stderr.log", result.stderr)
            details[f"{phase}_returncode"] = result.returncode
            details[f"{phase}_command"] = command_to_string(command)
            if phase == "seed":
                write_manifest(state_dir / "seed_manifest.txt", build_typed_manifest(sync_root))
            if phase == "verify":
                write_manifest(state_dir / "remote_manifest.txt", build_typed_manifest(verify_root))

            if result.returncode != 0:
                write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
                return self.fail_result(self.case_id, self.name, f"{phase} sync failed with status {result.returncode}", artifacts, details)

            observed_root = verify_root if phase == "verify" else sync_root
            observed = build_typed_manifest(observed_root)
            details[f"{phase}_manifest"] = observed
            if phase == "seed":
                expected_seed = sorted(expected_final + [
                    f"{root_name}/delete-top.txt", f"{root_name}/Survivor/delete-inside.txt",
                    f"{root_name}/RemoveTree/", f"{root_name}/RemoveTree/Deep/",
                    f"{root_name}/RemoveTree/Deep/child.txt", f"{root_name}/EmptyToRemove/",
                ])
                if observed != expected_seed:
                    write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
                    return self.fail_result(self.case_id, self.name, "seed tree did not establish the expected tracked local state", artifacts, details)
                if not (conf_main / "items.sqlite3").is_file():
                    self.write_metadata(metadata_file, details)
                    return self.fail_result(self.case_id, self.name, "seed did not create the subject item database", artifacts, details)
            else:
                if observed != expected_final:
                    write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
                    return self.fail_result(self.case_id, self.name, f"{phase}: deleted paths were restored or surviving tree differs from expected state", artifacts, details)
                for relative, contents in keep_files.items():
                    path = observed_root / relative
                    if not path.is_file() or path.read_text(encoding="utf-8") != contents:
                        return self.fail_result(self.case_id, self.name, f"{phase}: surviving file changed: {relative}", artifacts, details)

        # A fresh independent remote enumeration has confirmed the deletions.
        # A repeated subject sync must also have converged without resurrecting them.
        if context.should_run_scenario(self.case_id, self.REMOTE_SCENARIO_ID):
            remote_failure = self._run_remote_reconcile_scenario(context, layout, artifacts, details)
            if remote_failure:
                write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
                return self.fail_result(self.case_id, self.name, f"{self.REMOTE_SCENARIO_ID}: {remote_failure}", artifacts, details)
        write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
        return self.pass_result(self.case_id, self.name, artifacts, details)

    def _run_remote_reconcile_scenario(self, context: E2EContext, layout, artifacts: list[str], details: dict[str, object]) -> str | None:
        """Scenario SD-0002: online changes reconciled through the generated /children response.

        --single-directory makes the client generate its own /delta response, where an item
        that is not seen online is detected as deleted through the 'syncStatus' flag. An
        independent upload-only mutator makes genuine online deletions and a modification
        beside an untouched control tree. The subject must apply them, keep the control tree,
        preserve a locally modified file whose online copy was deleted, survive an interrupted
        enumeration, and then converge without feedback operations.
        """
        scenario_work = layout.work_dir / "sd0002"
        scenario_logs = layout.log_dir / "sd0002"
        scenario_state = layout.state_dir / "sd0002"
        for directory in (scenario_work, scenario_logs, scenario_state):
            reset_directory(directory)
        subject_root = scenario_work / "subject-root"
        mutator_root = scenario_work / "mutator-root"
        verify_root = scenario_work / "verify-root"
        conf_subject = scenario_work / "conf-subject"
        conf_mutator = scenario_work / "conf-mutator"
        conf_verify = scenario_work / "conf-verify"
        for root in (subject_root, mutator_root, verify_root):
            reset_directory(root)

        root_name = f"ZZ_E2E_TC0082_SD0002_{context.run_id}_{os.getpid()}"
        stable_files = {
            f"{root_name}/Stable/keep-a.txt": "TC0082 SD-0002 stable top-level file\n",
            f"{root_name}/Stable/Nested/keep-b.txt": "TC0082 SD-0002 stable nested file\n",
            f"{root_name}/Stable/Nested/Deep/keep-c.txt": "TC0082 SD-0002 stable deep file\n",
        }
        # A dedicated bulk subtree keeps the online enumeration running long enough for SIGINT to land mid-way.
        for bulk_dir in range(10):
            for bulk_index in range(30):
                stable_files[f"{root_name}/Bulk/Dir{bulk_dir:02d}/file-{bulk_index:03d}.txt"] = f"TC0082 SD-0002 bulk file {bulk_dir}-{bulk_index}\n"
        survivor = f"{root_name}/Mutable/keep-d.txt"
        changed_file = f"{root_name}/Mutable/change-me.txt"
        changed_before = "TC0082 SD-0002 content before the online modification\n"
        changed_after = "TC0082 SD-0002 content after the online modification, which must be applied\n"
        preserved_file = f"{root_name}/Mutable/preserve-me.txt"
        preserved_baseline = "TC0082 SD-0002 baseline content of the file deleted online\n"
        preserved_local = "TC0082 SD-0002 locally modified content that must survive the online deletion\n"
        deleted_files = {
            f"{root_name}/Mutable/delete-me.txt": "TC0082 SD-0002 file deleted online\n",
            f"{root_name}/Mutable/RemoveTree/Deep/child.txt": "TC0082 SD-0002 file inside a subtree deleted online\n",
        }
        deleted_directories = [f"{root_name}/Mutable/RemoveTree", f"{root_name}/Mutable/EmptyRemoved"]
        surviving_files = {**stable_files, survivor: "TC0082 SD-0002 file beside the online deletions\n", changed_file: changed_after}
        expected_final = sorted([
            f"{root_name}/", f"{root_name}/Stable/", f"{root_name}/Stable/Nested/",
            f"{root_name}/Stable/Nested/Deep/", f"{root_name}/Mutable/", f"{root_name}/Bulk/",
            *(f"{root_name}/Bulk/Dir{bulk_dir:02d}/" for bulk_dir in range(10)), *surviving_files,
        ])
        expected_initial = sorted([
            *expected_final, preserved_file, *deleted_files, f"{root_name}/Mutable/RemoveTree/",
            f"{root_name}/Mutable/RemoveTree/Deep/", f"{root_name}/Mutable/EmptyRemoved/",
        ])

        context.prepare_minimal_config_dir(
            conf_subject,
            f'# tc0082 SD-0002 subject config\nsync_dir = "{subject_root}"\n'
            'bypass_data_preservation = "false"\n',
        )
        context.prepare_minimal_config_dir(
            conf_mutator,
            f'# tc0082 SD-0002 independent mutator\nsync_dir = "{mutator_root}"\n'
            'bypass_data_preservation = "true"\n',
        )
        context.prepare_minimal_config_dir(
            conf_verify,
            f'# tc0082 SD-0002 independent verifier\nsync_dir = "{verify_root}"\n'
            'bypass_data_preservation = "true"\n',
        )
        for relative, contents in {
            **stable_files, **deleted_files, survivor: surviving_files[survivor],
            changed_file: changed_before, preserved_file: preserved_baseline,
        }.items():
            write_text_file(mutator_root / relative, contents)
        (mutator_root / deleted_directories[1]).mkdir(parents=True, exist_ok=True)

        phase_names = (
            "seed", "subject_initial", "subject_settle", "subject_unchanged", "remote_mutation",
            "remote_verify", "subject_interrupted", "subject_reconcile", "subject_converge", "final_verify",
        )
        phase_files = {
            phase: (scenario_logs / f"{phase}_stdout.log", scenario_logs / f"{phase}_stderr.log")
            for phase in phase_names
        }
        artifacts.extend(str(path) for pair in phase_files.values() for path in pair)
        artifacts.append(str(scenario_state / "metadata.txt"))
        scenario_details: dict[str, object] = {"root_name": root_name}
        details[self.REMOTE_SCENARIO_ID] = scenario_details

        def phase_run(phase: str, command: list[str]):
            context.log(f"Executing Test Case {self.case_id} {self.REMOTE_SCENARIO_ID} {phase}: {command_to_string(command)}")
            result = run_command(command, cwd=context.repo_root)
            write_text_file(phase_files[phase][0], result.stdout)
            write_text_file(phase_files[phase][1], result.stderr)
            scenario_details[f"{phase}_returncode"] = result.returncode
            scenario_details[f"{phase}_command"] = command_to_string(command)
            return result

        def fail(reason: str) -> str:
            scenario_details["failure_reason"] = reason
            write_text_file(scenario_state / "metadata.txt", "\n".join(f"{k}={v!r}" for k, v in sorted(scenario_details.items())) + "\n")
            return reason

        def output_of(phase: str) -> str:
            return "\n".join(path.read_text(encoding="utf-8", errors="replace") for path in phase_files[phase])

        def feedback_lines(phase: str) -> list[str]:
            return [
                line.strip() for line in output_of(phase).splitlines()
                if root_name in line and any(marker in line for marker in self.FEEDBACK_MARKERS)
            ]

        def non_backup(manifest: list[str]) -> list[str]:
            return [entry for entry in manifest if "-safeBackup-" not in entry]

        def surviving_content_failure(root: Path) -> str | None:
            for relative, contents in surviving_files.items():
                path = root / relative
                if not path.is_file() or path.read_text(encoding="utf-8") != contents:
                    return f"surviving file is missing or has unexpected content in {root.name}: {relative}"
            return None

        subject_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--single-directory", root_name, "--confdir", str(conf_subject),
        ]
        mutator_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--upload-only", "--verbose",
            "--single-directory", root_name, "--confdir", str(conf_mutator),
        ]
        verify_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose",
            "--resync", "--resync-auth", "--single-directory", root_name, "--confdir", str(conf_verify),
        ]

        if phase_run("seed", mutator_command + ["--resync", "--resync-auth"]).returncode != 0:
            return fail("mutator seed failed")
        if phase_run("subject_initial", subject_command + ["--resync", "--resync-auth"]).returncode != 0:
            return fail("subject initial sync failed")
        initial_manifest = build_typed_manifest(subject_root)
        if initial_manifest != expected_initial:
            scenario_details["subject_initial_manifest"] = initial_manifest
            return fail("subject did not establish the expected tracked tree")

        # The first repeat sync settles any one-off adjustment that follows --resync.
        # The second repeat sync, with nothing changed anywhere, is the strict check.
        if phase_run("subject_settle", subject_command).returncode != 0:
            return fail("subject settle sync failed")
        if phase_run("subject_unchanged", subject_command).returncode != 0:
            return fail("subject unchanged sync failed")
        if build_typed_manifest(subject_root) != expected_initial:
            return fail("the local tree changed during a sync with no online or local changes")
        unchanged_feedback = feedback_lines("subject_unchanged")
        if unchanged_feedback:
            scenario_details["unchanged_feedback_lines"] = unchanged_feedback
            return fail("a sync with no changes performed unintended operations")
        for relative, contents in {**stable_files, survivor: surviving_files[survivor], changed_file: changed_before}.items():
            if (subject_root / relative).read_text(encoding="utf-8") != contents:
                return fail(f"tracked file changed during a sync with no changes: {relative}")

        # One file is modified locally while its online copy is deleted: data must be preserved.
        write_text_file(subject_root / preserved_file, preserved_local)

        # Genuine online changes through the independent mutator's own tracked database.
        (mutator_root / list(deleted_files)[0]).unlink()
        shutil.rmtree(mutator_root / deleted_directories[0])
        (mutator_root / deleted_directories[1]).rmdir()
        (mutator_root / preserved_file).unlink()
        write_text_file(mutator_root / changed_file, changed_after)
        if phase_run("remote_mutation", mutator_command).returncode != 0:
            return fail("independent mutator failed to apply the online changes")
        if phase_run("remote_verify", verify_command).returncode != 0:
            return fail("independent remote verification failed")
        remote_manifest = build_typed_manifest(verify_root)
        scenario_details["remote_verify_manifest"] = remote_manifest
        if remote_manifest != expected_final:
            return fail("online changes were not confirmed by an independent verifier before reconciliation")

        # Interrupt the subject once its online enumeration has started. Whatever point it
        # reaches, items that still exist online must not be removed. A later full run must
        # recover and complete the reconciliation.
        context.log(f"Executing Test Case {self.case_id} {self.REMOTE_SCENARIO_ID} subject_interrupted: {command_to_string(subject_command)}")
        interrupt_marker = "Generating a /delta response from the OneDrive API"
        stdout_path = phase_files["subject_interrupted"][0]
        process = None
        marker_seen = False
        signal_sent = False
        interrupt_failure: str | None = None
        with stdout_path.open("w", encoding="utf-8") as stdout_fp, \
                phase_files["subject_interrupted"][1].open("w", encoding="utf-8") as stderr_fp:
            try:
                process = subprocess.Popen(subject_command, cwd=str(context.repo_root), stdout=stdout_fp, stderr=stderr_fp, text=True)
                deadline = time.time() + 120
                while time.time() < deadline and process.poll() is None:
                    if interrupt_marker in stdout_path.read_text(encoding="utf-8", errors="replace"):
                        marker_seen = True
                        break
                    time.sleep(0.05)
                if marker_seen and process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    signal_sent = True
                    try:
                        process.wait(timeout=60)
                    except subprocess.TimeoutExpired:
                        interrupt_failure = "the subject did not exit within 60 seconds of SIGINT"
            finally:
                # Whatever happened above, no subject process may outlive this step.
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait(timeout=60)
        stdout_lines = [line for line in stdout_path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
        scenario_details["subject_interrupted_returncode"] = process.returncode if process is not None else None
        scenario_details["subject_interrupted_after_enumeration_started"] = marker_seen
        scenario_details["subject_interrupted_signal_sent"] = signal_sent
        scenario_details["subject_interrupted_last_output_line"] = stdout_lines[-1] if stdout_lines else ""
        if interrupt_failure:
            return fail(interrupt_failure)
        if not marker_seen:
            return fail("the online enumeration start marker was not observed before the subject exited or timed out")
        if not signal_sent:
            return fail("the subject finished before SIGINT could be sent, so the interruption was not exercised")
        if process.returncode not in (130, -signal.SIGINT):
            return fail(f"the subject was not terminated by SIGINT (exit status {process.returncode}), so it may have completed normally")
        for relative in (*stable_files, survivor):
            path = subject_root / relative
            if not path.is_file() or path.read_text(encoding="utf-8") != surviving_files[relative]:
                return fail(f"interrupted enumeration removed or changed an item that still exists online: {relative}")
        if not (subject_root / changed_file).is_file():
            return fail("interrupted enumeration removed an item that still exists online: " + changed_file)

        for phase in ("subject_reconcile", "subject_converge"):
            if phase_run(phase, subject_command).returncode != 0:
                return fail(f"{phase} sync failed")

        final_manifest = build_typed_manifest(subject_root)
        scenario_details["subject_final_manifest"] = final_manifest
        if non_backup(final_manifest) != expected_final:
            return fail("online deletions were not applied locally, or the surviving local tree differs from the expected state")
        content_failure = surviving_content_failure(subject_root)
        if content_failure:
            return fail(content_failure)
        if (subject_root / preserved_file).exists():
            return fail("the file deleted online was left at its canonical path")
        backups = sorted(subject_root.glob(f"{root_name}/Mutable/preserve-me-*-safeBackup-????.txt"))
        scenario_details["preserved_backups"] = [str(path.relative_to(subject_root)) for path in backups]
        if len(backups) != 1 or backups[0].read_text(encoding="utf-8") != preserved_local:
            return fail("the locally modified file deleted online was not preserved as exactly one safeBackup")
        if any(".partial" in path.name for path in subject_root.rglob("*")) \
                or [path for path in subject_root.rglob("*") if "safeBackup" in path.name and path not in backups]:
            return fail("unexpected backup or partial artefact in the subject tree")
        converge_feedback = feedback_lines("subject_converge")
        if converge_feedback:
            scenario_details["converge_feedback_lines"] = converge_feedback
            return fail("the unchanged convergence pass performed unintended operations")

        # A fresh independent enumeration confirms that nothing that should survive was removed
        # online, and that nothing deleted online was restored.
        reset_directory(verify_root)
        if phase_run("final_verify", verify_command).returncode != 0:
            return fail("final independent remote verification failed")
        final_remote = build_typed_manifest(verify_root)
        if non_backup(final_remote) != expected_final:
            scenario_details["final_remote_manifest"] = final_remote
            return fail("the final online state differs from the expected state")
        content_failure = surviving_content_failure(verify_root)
        if content_failure:
            return fail(content_failure)

        write_text_file(scenario_state / "metadata.txt", "\n".join(f"{k}={v!r}" for k, v in sorted(scenario_details.items())) + "\n")
        return None
