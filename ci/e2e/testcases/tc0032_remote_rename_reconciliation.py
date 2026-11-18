from __future__ import annotations



import os
import traceback
import hashlib

import shutil

from pathlib import Path



from testcases.remote_move_identity import (
    MonitoredRemoteMoveCase, snapshot_remote_identities, check_remote_identity_transition,
)

from framework.context import E2EContext

from framework.manifest import build_manifest, write_manifest

from framework.result import TestResult

from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, rename_xlsx_pair, xlsx_pair_any_exists, xlsx_pair_all_files

from framework.pdf import create_random_pdf_pair, validate_pdf_pair, rename_pdf_pair, pdf_pair_any_exists, pdf_pair_all_files

from framework.image import create_random_image_set, validate_image_set, rename_image_set, image_set_any_exists, image_set_all_files

from framework.utils import (

    command_to_string,

    compute_quickxor_hash_file,

    reset_directory,

    run_command,

    write_onedrive_config,

    write_text_file,

)





class TestCase0032RemoteRenameReconciliation(MonitoredRemoteMoveCase):

    case_id = "0032"

    name = "remote rename reconciliation"

    description = (

        "Distinguish delete-and-recreate archive preservation from identity-preserving remote file "

        "renames for passive TXT, XLSX/PDF and PNG/JPEG fixtures"

    )



    XLSX_PAYLOAD_ROWS = 32



    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:

        config_path = config_dir / "config"

        backup_path = config_dir / ".config.backup"

        hash_path = config_dir / ".config.hash"



        config_text = (

            "# tc0032 config\n"

            f'sync_dir = "{sync_dir}"\n'

            'bypass_data_preservation = "true"\n'

        )



        write_onedrive_config(config_path, config_text)

        write_onedrive_config(backup_path, config_text)

        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")

        os.chmod(config_path, 0o600)

        os.chmod(backup_path, 0o600)

        os.chmod(hash_path, 0o600)



    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:

        write_text_file(

            metadata_file,

            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",

        )



    SCENARIOS = (
        ("DR-0001", "standalone sync delete-and-recreate archival semantics"),
        ("RM-0002", "monitor identity-preserving Graph rename/move reconciliation"),
    )

    def run(self, context: E2EContext) -> TestResult:
        failures: list[str] = []
        artifacts: list[str] = []
        scenario_details: dict[str, object] = {}
        executed: list[str] = []
        failed_ids: list[str] = []
        for scenario_id, description in self.SCENARIOS:
            if not context.should_run_scenario(self.case_id, scenario_id):
                continue
            executed.append(scenario_id)
            context.log(f"Running Test Case {self.case_id} scenario {scenario_id}: {description}")
            try:
                result = self._run_scenario(
                    context, scenario_id=scenario_id,
                    preserve_identity=(scenario_id == "RM-0002"),
                )
            except Exception as exc:
                # One broken scenario must not silently suppress execution of
                # the other independent operation. Retain full traceback evidence.
                exception_log = context.state_dir / f"tc{self.case_id}" / scenario_id / "exception.log"
                write_text_file(exception_log, traceback.format_exc())
                result = self.fail_result(
                    self.case_id, self.name,
                    f"Unexpected {type(exc).__name__}: {exc}",
                    [str(exception_log)],
                    {"scenario_id": scenario_id, "exception_type": type(exc).__name__},
                )
            artifacts.extend(result.artifacts)
            scenario_details[scenario_id] = result.details
            if result.status != "pass":
                failed_ids.append(scenario_id)
                failures.append(f"{scenario_id}: {result.reason}")
                context.log(f"Scenario {scenario_id} FAILED: {result.reason}")
            else:
                context.log(f"Scenario {scenario_id} PASSED")

        details = {
            "scenario_count": len(executed),
            "executed_scenario_ids": executed,
            "failed_scenario_ids": failed_ids,
            "failed_scenarios": len(failures),
            "scenario_details": scenario_details,
        }
        if failures:
            return self.fail_result(
                self.case_id, self.name,
                f"{len(failures)} of {len(executed)} scenarios failed: " + " | ".join(failures),
                artifacts, details,
            )
        return self.pass_result(self.case_id, self.name, artifacts, details)

    def _run_scenario(
        self, context: E2EContext, *, scenario_id: str, preserve_identity: bool,
    ) -> TestResult:

        layout = self.prepare_case_layout(

            context,

            case_dir_name=f"tc0032/{scenario_id}",

            ensure_refresh_token=True,

        )

        case_work_dir = layout.work_dir

        case_log_dir = layout.log_dir

        state_dir = layout.state_dir



        seed_root = case_work_dir / "seedroot"

        stale_root = case_work_dir / "staleroot"

        verify_root = case_work_dir / "verifyroot"



        conf_seed = case_work_dir / "conf-seed"

        conf_stale = case_work_dir / "conf-stale"

        conf_verify = case_work_dir / "conf-verify"



        reset_directory(seed_root)

        reset_directory(verify_root)



        context.prepare_minimal_config_dir(conf_seed, "")

        context.prepare_minimal_config_dir(conf_verify, "")



        self._write_config(conf_seed, seed_root)

        self._write_config(conf_verify, verify_root)



        root_name = f"ZZ_E2E_TC0032_{scenario_id.replace('-', '_')}_{context.run_id}_{os.getpid()}"

        old_txt_relative = f"{root_name}/remote-original-name.txt"

        new_txt_relative = f"{root_name}/remote-renamed-name.txt"

        old_xlsx_relative = f"{root_name}/remote-original-name.xlsx"

        new_xlsx_relative = f"{root_name}/remote-renamed-name.xlsx"

        old_pdf_relative = f"{root_name}/remote-original-name.pdf"

        new_pdf_relative = f"{root_name}/remote-renamed-name.pdf"

        old_image_relative = f"{root_name}/remote-original-name.png"

        new_image_relative = f"{root_name}/remote-renamed-name.png"



        seed_old_txt_path = seed_root / old_txt_relative

        seed_new_txt_path = seed_root / new_txt_relative

        seed_old_xlsx_path = seed_root / old_xlsx_relative

        seed_new_xlsx_path = seed_root / new_xlsx_relative

        seed_old_pdf_path = seed_root / old_pdf_relative

        seed_new_pdf_path = seed_root / new_pdf_relative

        seed_old_image_path = seed_root / old_image_relative

        seed_new_image_path = seed_root / new_image_relative



        stale_old_txt_path = stale_root / old_txt_relative

        stale_new_txt_path = stale_root / new_txt_relative

        stale_old_xlsx_path = stale_root / old_xlsx_relative

        stale_new_xlsx_path = stale_root / new_xlsx_relative

        stale_old_pdf_path = stale_root / old_pdf_relative

        stale_new_pdf_path = stale_root / new_pdf_relative

        stale_old_image_path = stale_root / old_image_relative

        stale_new_image_path = stale_root / new_image_relative



        verify_old_txt_path = verify_root / old_txt_relative

        verify_new_txt_path = verify_root / new_txt_relative

        verify_old_xlsx_path = verify_root / old_xlsx_relative

        verify_new_xlsx_path = verify_root / new_xlsx_relative

        verify_old_pdf_path = verify_root / old_pdf_relative

        verify_new_pdf_path = verify_root / new_pdf_relative

        verify_old_image_path = verify_root / old_image_relative

        verify_new_image_path = verify_root / new_image_relative



        txt_content = (

            "TC0032 remote rename reconciliation\n"

            "This passive text file is renamed remotely and must reconcile locally.\n"

        )

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0032:{os.getpid()}"

        pdf_seed = f"{xlsx_seed}:pdf"

        image_seed = f"{xlsx_seed}:image"



        seed_stdout = case_log_dir / "phase1_seed_stdout.log"

        seed_stderr = case_log_dir / "phase1_seed_stderr.log"

        remote_rename_stdout = case_log_dir / "phase2_remote_rename_stdout.log"

        remote_rename_stderr = case_log_dir / "phase2_remote_rename_stderr.log"

        stale_sync_stdout = case_log_dir / "phase3_stale_reconcile_stdout.log"

        stale_sync_stderr = case_log_dir / "phase3_stale_reconcile_stderr.log"

        verify_stdout = case_log_dir / "verify_stdout.log"

        verify_stderr = case_log_dir / "verify_stderr.log"

        stale_manifest_file = state_dir / "stale_manifest.txt"

        verify_manifest_file = state_dir / "verify_manifest.txt"

        metadata_file = state_dir / "metadata.txt"



        artifacts = [

            str(seed_stdout),

            str(seed_stderr),

            str(remote_rename_stdout),

            str(remote_rename_stderr),

            str(stale_sync_stdout),

            str(stale_sync_stderr),

            str(verify_stdout),

            str(verify_stderr),

            str(stale_manifest_file),

            str(verify_manifest_file),

            str(metadata_file),

        ]



        details: dict[str, object] = {

            "root_name": root_name,

            "old_txt_relative": old_txt_relative,

            "new_txt_relative": new_txt_relative,

            "old_xlsx_relative": old_xlsx_relative,

            "new_xlsx_relative": new_xlsx_relative,

            "old_pdf_relative": old_pdf_relative,

            "new_pdf_relative": new_pdf_relative,

            "old_image_relative": old_image_relative,

            "new_image_relative": new_image_relative,

            "seed_root": str(seed_root),

            "stale_root": str(stale_root),

            "verify_root": str(verify_root),

            "seed_conf_dir": str(conf_seed),

            "stale_conf_dir": str(conf_stale),

            "verify_conf_dir": str(conf_verify),

            "xlsx_seed": xlsx_seed,

            "pdf_seed": pdf_seed,

            "image_seed": image_seed,

            "payload_rows": self.XLSX_PAYLOAD_ROWS,

        }



        # Phase 1: seed original remote state with both a passive and Microsoft-processed payload class.

        write_text_file(seed_old_txt_path, txt_content)

        generated = create_random_xlsx_pair(

            seed_old_xlsx_path,

            xlsx_seed,

            revision=REVISION_0,

            payload_rows=self.XLSX_PAYLOAD_ROWS,

            title="TC0032 remote rename reconciliation workbook",

        )

        details["generated_xlsx_size"] = int(generated["size_bytes"])

        generated_pdf = create_random_pdf_pair(seed_old_pdf_path, pdf_seed, revision=REVISION_0, title="TC0032 remote rename reconciliation PDF")

        details["generated_pdf_size"] = int(generated_pdf["size_bytes"])

        details["generated_large_pdf_size"] = int(generated_pdf["large_size_bytes"])

        generated_images = create_random_image_set(seed_old_image_path, image_seed, revision=REVISION_0, title="TC0032 remote rename reconciliation images")

        details["generated_image_sizes"] = {k: int(v) for k, v in generated_images.items() if k.endswith("_size_bytes")}



        seed_command = [

            context.onedrive_bin,

            "--display-running-config",

            "--sync",

            "--verbose",

            "--single-directory",

            root_name,

            "--confdir",

            str(conf_seed),

        ]

        context.log(f"Executing Test Case {self.case_id} phase1 seed: {command_to_string(seed_command)}")

        seed_result = run_command(seed_command, cwd=context.repo_root)

        write_text_file(seed_stdout, seed_result.stdout)

        write_text_file(seed_stderr, seed_result.stderr)

        details["seed_returncode"] = seed_result.returncode



        if seed_result.returncode != 0:

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                f"seed phase failed with status {seed_result.returncode}",

                artifacts,

                details,

            )



        settled_txt_content = seed_old_txt_path.read_text(encoding="utf-8") if seed_old_txt_path.is_file() else ""

        settled_xlsx_validation_error = validate_xlsx_pair(seed_old_xlsx_path, REVISION_0)

        settled_pdf_validation_error = validate_pdf_pair(seed_old_pdf_path, REVISION_0)

        settled_image_validation_error = validate_image_set(seed_old_image_path, REVISION_0)

        details["settled_txt_content"] = settled_txt_content

        details["settled_xlsx_validation_error"] = settled_xlsx_validation_error

        details["settled_pdf_validation_error"] = settled_pdf_validation_error

        details["settled_image_validation_error"] = settled_image_validation_error



        if settled_txt_content != txt_content:

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                "seeded passive TXT content changed during initial sync",

                artifacts,

                details,

            )



        if settled_xlsx_validation_error:

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                f"seeded XLSX was invalid after initial sync: {settled_xlsx_validation_error}",

                artifacts,

                details,

            )



        if settled_image_validation_error:

            self._write_metadata(metadata_file, details)

            return self.fail_result(self.case_id, self.name, f"seeded image set was invalid after initial sync: {settled_image_validation_error}", artifacts, details)



        if settled_pdf_validation_error:

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                f"seeded PDF was invalid after initial sync: {settled_pdf_validation_error}",

                artifacts,

                details,

            )



        # Snapshot the synchronised local + config/db state to create a stale client.

        if conf_stale.exists():

            shutil.rmtree(conf_stale)

        if stale_root.exists():

            shutil.rmtree(stale_root)



        shutil.copytree(conf_seed, conf_stale)

        shutil.copytree(seed_root, stale_root)



        # Rewrite stale runtime config so it points at stale_root while preserving DB state.

        self._write_config(conf_stale, stale_root)



        details["stale_snapshot_old_txt_exists_before_reconcile"] = stale_old_txt_path.is_file()

        details["stale_snapshot_new_txt_exists_before_reconcile"] = stale_new_txt_path.exists()

        details["stale_snapshot_old_xlsx_exists_before_reconcile"] = stale_old_xlsx_path.is_file()

        details["stale_snapshot_new_xlsx_exists_before_reconcile"] = stale_new_xlsx_path.exists()

        details["stale_snapshot_old_pdf_exists_before_reconcile"] = stale_old_pdf_path.is_file()

        details["stale_snapshot_new_pdf_exists_before_reconcile"] = stale_new_pdf_path.exists()

        details["stale_snapshot_old_image_exists_before_reconcile"] = image_set_all_files(stale_old_image_path)

        details["stale_snapshot_new_image_exists_before_reconcile"] = image_set_any_exists(stale_new_image_path)



        if not stale_old_txt_path.is_file() or not stale_old_xlsx_path.is_file() or not stale_old_pdf_path.is_file() or not image_set_all_files(stale_old_image_path):

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                "stale snapshot did not preserve both original local files before reconciliation",

                artifacts,

                details,

            )



        if stale_old_txt_path.read_text(encoding="utf-8") != txt_content:

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                "stale snapshot passive TXT content did not match expected content",

                artifacts,

                details,

            )



        stale_snapshot_xlsx_validation_error = validate_xlsx_pair(stale_old_xlsx_path, REVISION_0)

        stale_snapshot_pdf_validation_error = validate_pdf_pair(stale_old_pdf_path, REVISION_0)

        stale_snapshot_image_validation_error = validate_image_set(stale_old_image_path, REVISION_0)

        details["stale_snapshot_xlsx_validation_error"] = stale_snapshot_xlsx_validation_error

        details["stale_snapshot_pdf_validation_error"] = stale_snapshot_pdf_validation_error

        details["stale_snapshot_image_validation_error"] = stale_snapshot_image_validation_error

        if stale_snapshot_xlsx_validation_error:

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                f"stale snapshot XLSX was invalid before reconciliation: {stale_snapshot_xlsx_validation_error}",

                artifacts,

                details,

            )



        if stale_snapshot_pdf_validation_error:

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                f"stale snapshot PDF was invalid before reconciliation: {stale_snapshot_pdf_validation_error}",

                artifacts,

                details,

            )



        # Two independently proved online operations: standalone sync may replace
        # Graph objects, while inotify monitor must update the original identities.
        baseline_items = snapshot_remote_identities(conf_seed / "items.sqlite3", root_name)
        transitions = sorted(
            (old, old.replace("remote-original-name", "remote-renamed-name", 1))
            for old in baseline_items
            if old.startswith(f"{root_name}/remote-original-name")
        )
        if len(transitions) != 9:
            return self.fail_result(self.case_id, self.name,
                f"Expected nine tracked original files, found {len(transitions)}",
                artifacts, details)
        original_hashes = {
            old: hashlib.sha256((stale_root / old).read_bytes()).hexdigest()
            for old, _ in transitions
        }
        details["expected_identity_transitions"] = len(transitions)

        if preserve_identity:
            error = self._move_existing_items_online(
                context, config_dir=conf_seed, sync_root=seed_root,
                root_name=root_name, moves=transitions,
                stdout_file=remote_rename_stdout, stderr_file=remote_rename_stderr,
                details=details,
            )
            if error:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, error, artifacts, details)
        else:
            seed_old_txt_path.rename(seed_new_txt_path)
            rename_xlsx_pair(seed_old_xlsx_path, seed_new_xlsx_path)
            rename_pdf_pair(seed_old_pdf_path, seed_new_pdf_path)
            rename_image_set(seed_old_image_path, seed_new_image_path)
            remote_rename_command = [
                context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
                "--single-directory", root_name, "--confdir", str(conf_seed),
            ]
            context.log(f"Executing Test Case {self.case_id} {scenario_id} standalone rename: {command_to_string(remote_rename_command)}")
            remote_rename_result = run_command(remote_rename_command, cwd=context.repo_root)
            write_text_file(remote_rename_stdout, remote_rename_result.stdout)
            write_text_file(remote_rename_stderr, remote_rename_result.stderr)
            details["remote_rename_returncode"] = remote_rename_result.returncode
            if remote_rename_result.returncode != 0:
                return self.fail_result(self.case_id, self.name,
                    f"standalone rename propagation failed with status {remote_rename_result.returncode}",
                    artifacts, details)

        if (seed_old_txt_path.exists() or xlsx_pair_any_exists(seed_old_xlsx_path)
                or pdf_pair_any_exists(seed_old_pdf_path) or image_set_any_exists(seed_old_image_path)):
            return self.fail_result(self.case_id, self.name,
                "Mutator still contains one or more original filenames", artifacts, details)
        if (not seed_new_txt_path.is_file() or not xlsx_pair_all_files(seed_new_xlsx_path)
                or not pdf_pair_all_files(seed_new_pdf_path) or not image_set_all_files(seed_new_image_path)):
            return self.fail_result(self.case_id, self.name,
                "Mutator is missing one or more renamed files", artifacts, details)
        # No OneDrive client currently owns this database.
        after_items = snapshot_remote_identities(conf_seed / "items.sqlite3", root_name)

        # Phase 3: stale client reconciles both remote renames using existing DB/local state.

        # No --resync here, because this is specifically a reconciliation test.

        stale_sync_command = [

            context.onedrive_bin,

            "--display-running-config",

            "--sync",

            "--download-only",

            "--verbose",

            "--single-directory",

            root_name,

            "--confdir",

            str(conf_stale),

        ]

        context.log(f"Executing Test Case {self.case_id} phase3 stale reconcile: {command_to_string(stale_sync_command)}")

        stale_sync_result = run_command(stale_sync_command, cwd=context.repo_root)

        write_text_file(stale_sync_stdout, stale_sync_result.stdout)

        write_text_file(stale_sync_stderr, stale_sync_result.stderr)

        details["stale_reconcile_returncode"] = stale_sync_result.returncode



        stale_manifest = build_manifest(stale_root)

        write_manifest(stale_manifest_file, stale_manifest)



        details["stale_old_txt_exists_after_reconcile"] = stale_old_txt_path.exists()

        details["stale_new_txt_exists_after_reconcile"] = stale_new_txt_path.is_file()

        details["stale_old_xlsx_exists_after_reconcile"] = stale_old_xlsx_path.exists()

        details["stale_new_xlsx_exists_after_reconcile"] = stale_new_xlsx_path.is_file()

        details["stale_old_pdf_exists_after_reconcile"] = stale_old_pdf_path.exists()

        details["stale_new_pdf_exists_after_reconcile"] = stale_new_pdf_path.is_file()

        details["stale_old_image_exists_after_reconcile"] = image_set_any_exists(stale_old_image_path)

        details["stale_new_image_exists_after_reconcile"] = image_set_all_files(stale_new_image_path)

        stale_new_txt_content = stale_new_txt_path.read_text(encoding="utf-8") if stale_new_txt_path.is_file() else ""

        stale_new_xlsx_validation_error = (

            validate_xlsx_pair(stale_new_xlsx_path, REVISION_0)

            if stale_new_xlsx_path.is_file()

            else "Stale client XLSX is missing"

        )

        stale_new_pdf_validation_error = (

            validate_pdf_pair(stale_new_pdf_path, REVISION_0)

            if stale_new_pdf_path.is_file()

            else "Stale client PDF is missing"

        )

        details["stale_new_txt_content"] = stale_new_txt_content

        stale_new_image_validation_error = (validate_image_set(stale_new_image_path, REVISION_0) if image_set_all_files(stale_new_image_path) else "Stale renamed image set is missing")

        details["stale_new_xlsx_validation_error"] = stale_new_xlsx_validation_error

        details["stale_new_pdf_validation_error"] = stale_new_pdf_validation_error

        details["stale_new_image_validation_error"] = stale_new_image_validation_error



        if stale_sync_result.returncode != 0:

            self._write_metadata(metadata_file, details)

            return self.fail_result(

                self.case_id,

                self.name,

                f"stale reconciliation phase failed with status {stale_sync_result.returncode}",

                artifacts,

                details,

            )



        # Final clean remote verification from scratch.

        verify_command = [

            context.onedrive_bin,

            "--display-running-config",

            "--sync",

            "--download-only",

            "--verbose",

            "--resync",

            "--resync-auth",

            "--single-directory",

            root_name,

            "--confdir",

            str(conf_verify),

        ]

        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")

        verify_result = run_command(verify_command, cwd=context.repo_root)

        write_text_file(verify_stdout, verify_result.stdout)

        write_text_file(verify_stderr, verify_result.stderr)

        details["verify_returncode"] = verify_result.returncode



        verify_manifest = build_manifest(verify_root)

        write_manifest(verify_manifest_file, verify_manifest)



        details["verify_old_txt_exists"] = verify_old_txt_path.exists()

        details["verify_new_txt_exists"] = verify_new_txt_path.is_file()

        details["verify_old_xlsx_exists"] = verify_old_xlsx_path.exists()

        details["verify_new_xlsx_exists"] = verify_new_xlsx_path.is_file()

        details["verify_old_pdf_exists"] = verify_old_pdf_path.exists()

        details["verify_new_pdf_exists"] = verify_new_pdf_path.is_file()

        details["verify_old_image_exists"] = image_set_any_exists(verify_old_image_path)

        details["verify_new_image_exists"] = image_set_all_files(verify_new_image_path)

        verify_new_txt_content = verify_new_txt_path.read_text(encoding="utf-8") if verify_new_txt_path.is_file() else ""

        verify_new_xlsx_validation_error = (

            validate_xlsx_pair(verify_new_xlsx_path, REVISION_0)

            if verify_new_xlsx_path.is_file()

            else "Verification XLSX is missing"

        )

        verify_new_pdf_validation_error = (

            validate_pdf_pair(verify_new_pdf_path, REVISION_0)

            if verify_new_pdf_path.is_file()

            else "Verification PDF is missing"

        )
        verify_new_image_validation_error = (
            validate_image_set(verify_new_image_path, REVISION_0)
            if image_set_all_files(verify_new_image_path)
            else "Verification image set is missing"
        )

        details["verify_new_txt_content"] = verify_new_txt_content

        details["verify_new_xlsx_validation_error"] = verify_new_xlsx_validation_error

        details["verify_new_pdf_validation_error"] = verify_new_pdf_validation_error
        details["verify_new_image_validation_error"] = verify_new_image_validation_error



        self._write_metadata(metadata_file, details)



        if verify_result.returncode != 0:

            return self.fail_result(

                self.case_id,

                self.name,

                f"remote verification failed with status {verify_result.returncode}",

                artifacts,

                details,

            )



        # Both scenario classes must prove their Graph identity semantics using a
        # fresh independent online download. The mutator's database was read
        # only after the client stopped, never concurrently with --monitor.
        verified_items = snapshot_remote_identities(conf_verify / "items.sqlite3", root_name)
        identity_errors = check_remote_identity_transition(
            baseline_items, after_items, verified_items, transitions,
            preserve_identity=preserve_identity,
        )
        details["graph_identity_verified_count"] = len(transitions) - len(identity_errors)
        details["graph_identity_errors"] = identity_errors
        if identity_errors:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name,
                "Graph identity evidence failed: " + "; ".join(identity_errors),
                artifacts, details)
        if not preserve_identity:
            archived_differences = [
                path for path, expected_hash in original_hashes.items()
                if not (stale_root / path).is_file()
                or hashlib.sha256((stale_root / path).read_bytes()).hexdigest() != expected_hash
            ]
            if archived_differences:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name,
                    "--download-only failed to preserve original local bytes after delete/recreate: "
                    + ", ".join(archived_differences), artifacts, details)

        if preserve_identity and (stale_old_txt_path.exists() or xlsx_pair_any_exists(stale_old_xlsx_path) or pdf_pair_any_exists(stale_old_pdf_path) or image_set_any_exists(stale_old_image_path)):

            return self.fail_result(

                self.case_id,

                self.name,

                "stale client still contains one or more old filenames after reconciliation",

                artifacts,

                details,

            )



        if not stale_new_txt_path.is_file() or not xlsx_pair_all_files(stale_new_xlsx_path) or not pdf_pair_all_files(stale_new_pdf_path) or not image_set_all_files(stale_new_image_path):

            return self.fail_result(

                self.case_id,

                self.name,

                "stale client is missing one or more renamed files after reconciliation",

                artifacts,

                details,

            )



        if stale_new_txt_content != txt_content:

            return self.fail_result(

                self.case_id,

                self.name,

                "stale client renamed passive TXT content did not match expected content after reconciliation",

                artifacts,

                details,

            )



        if stale_new_xlsx_validation_error:

            return self.fail_result(

                self.case_id,

                self.name,

                f"stale client renamed XLSX is invalid or stale after reconciliation: {stale_new_xlsx_validation_error}",

                artifacts,

                details,

            )



        if stale_new_image_validation_error:

            return self.fail_result(self.case_id, self.name, f"stale client renamed image set is invalid or stale after reconciliation: {stale_new_image_validation_error}", artifacts, details)



        if stale_new_pdf_validation_error:

            return self.fail_result(

                self.case_id,

                self.name,

                f"stale client renamed PDF is invalid or stale after reconciliation: {stale_new_pdf_validation_error}",

                artifacts,

                details,

            )



        if verify_old_txt_path.exists() or xlsx_pair_any_exists(verify_old_xlsx_path) or pdf_pair_any_exists(verify_old_pdf_path) or image_set_any_exists(verify_old_image_path):

            return self.fail_result(

                self.case_id,

                self.name,

                "fresh remote verification still contains one or more old filenames",

                artifacts,

                details,

            )



        if not verify_new_txt_path.is_file() or not xlsx_pair_all_files(verify_new_xlsx_path) or not pdf_pair_all_files(verify_new_pdf_path) or not image_set_all_files(verify_new_image_path):

            return self.fail_result(

                self.case_id,

                self.name,

                "fresh remote verification is missing one or more renamed files",

                artifacts,

                details,

            )



        if verify_new_txt_content != txt_content:

            return self.fail_result(

                self.case_id,

                self.name,

                "fresh remote verification passive TXT content did not match expected content",

                artifacts,

                details,

            )



        if verify_new_xlsx_validation_error:

            return self.fail_result(

                self.case_id,

                self.name,

                f"fresh remote verification returned an invalid or stale XLSX workbook: {verify_new_xlsx_validation_error}",

                artifacts,

                details,

            )



        if verify_new_image_validation_error:

            return self.fail_result(self.case_id, self.name, f"remote verification returned an invalid or stale image set: {verify_new_image_validation_error}", artifacts, details)



        if verify_new_pdf_validation_error:

            return self.fail_result(

                self.case_id,

                self.name,

                f"fresh remote verification returned an invalid or stale PDF document: {verify_new_pdf_validation_error}",

                artifacts,

                details,

            )



        return self.pass_result(self.case_id, self.name, artifacts, details)

