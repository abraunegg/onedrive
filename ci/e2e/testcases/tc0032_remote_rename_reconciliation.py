from __future__ import annotations



import os

import shutil

from pathlib import Path



from testcases.monitor_case_base import MonitorModeTestCaseBase

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





class TestCase0032RemoteRenameReconciliation(MonitorModeTestCaseBase):

    case_id = "0032"

    name = "remote rename reconciliation"

    description = (

        "Validate that a stale local client correctly reconciles remote-side passive TXT, real XLSX/PDF file renames "

        "and a real PNG/JPEG image-set rename without leaving stale local leftovers"

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
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n'

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



    def run(self, context: E2EContext) -> TestResult:

        layout = self.prepare_case_layout(

            context,

            case_dir_name="tc0032",

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



        root_name = f"ZZ_E2E_TC0032_{context.run_id}_{os.getpid()}"

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



        # Phase 2: move already-synced items through inotify. A standalone
        # --sync interprets these local renames as remote delete + re-upload.
        # The stale --download-only client below must see genuine same-ID moves.
        rename_pairs = [
            (old.as_posix(), old.as_posix().replace("remote-original-name", "remote-renamed-name"))
            for old in sorted(path.relative_to(seed_root) for path in seed_root.rglob("*")
                              if path.is_file() and "remote-original-name" in path.name)
        ]
        if len(rename_pairs) != 9:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, "rename fixture does not contain nine original files", artifacts, details)

        remote_rename_command = [
            context.onedrive_bin, "--display-running-config", "--monitor",
            "--upload-only", "--verbose", "--verbose", "--single-directory",
            root_name, "--confdir", str(conf_seed),
        ]
        context.log(f"Executing Test Case {self.case_id} phase2 monitored remote rename: {command_to_string(remote_rename_command)}")
        monitor, started = self._launch_monitor_process(
            context, remote_rename_command, remote_rename_stdout, remote_rename_stderr,
        )
        try:
            details["remote_rename_monitor_initial_sync_complete"] = started
            if not started:
                return self.fail_result(self.case_id, self.name, "mutator monitor did not complete initial sync", artifacts, details)
            offset = self._prepare_monitor_for_local_mutation(monitor, remote_rename_stdout, details)
            if not details["monitor_ready_after_initial_sync"]:
                return self.fail_result(self.case_id, self.name, "mutator monitor not ready for rename", artifacts, details)

            seed_old_txt_path.rename(seed_new_txt_path)
            rename_xlsx_pair(seed_old_xlsx_path, seed_new_xlsx_path)
            rename_pdf_pair(seed_old_pdf_path, seed_new_pdf_path)
            rename_image_set(seed_old_image_path, seed_new_image_path)
            if (seed_old_txt_path.exists() or xlsx_pair_any_exists(seed_old_xlsx_path)
                    or pdf_pair_any_exists(seed_old_pdf_path) or image_set_any_exists(seed_old_image_path)):
                return self.fail_result(self.case_id, self.name, "old seed filenames still exist after local rename", artifacts, details)
            if (not seed_new_txt_path.is_file() or not xlsx_pair_all_files(seed_new_xlsx_path)
                    or not pdf_pair_all_files(seed_new_pdf_path) or not image_set_all_files(seed_new_image_path)):
                return self.fail_result(self.case_id, self.name, "renamed seed files missing after local rename", artifacts, details)

            patterns = [
                marker
                for source, destination in rename_pairs
                for marker in (
                    f"[M] Local item moved: ./{source} -> ./{destination}",
                    f"Moving ./{source} to ./{destination}",
                    f'"{Path(destination).name}", "", file,',
                )
            ]
            processed, segment = self._wait_for_stdout_growth_patterns(
                remote_rename_stdout, start_offset=offset,
                required_patterns=patterns, timeout_seconds=180,
            )
            details["remote_rename_monitor_moves_complete"] = processed
            details["remote_rename_monitor_move_count"] = len(rename_pairs)
            details["remote_rename_monitor_bad_operations"] = [
                line for line in segment.splitlines()
                if any(marker in line for marker in (
                    "Deleting item from Microsoft OneDrive:",
                    "Uploading new file:",
                    "New items to upload to Microsoft OneDrive:",
                    "New directories to create on Microsoft OneDrive:",
                    "Trying to delete this item as requested:",
                ))
            ]
            if not processed or details["remote_rename_monitor_bad_operations"]:
                return self.fail_result(self.case_id, self.name, "mutator did not complete same-ID moves without delete/re-upload", artifacts, details)
        finally:
            self._shutdown_monitor_process(monitor, details)
            self._write_metadata(metadata_file, details)
        details["remote_rename_transaction_complete"] = True

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



        if stale_old_txt_path.exists() or xlsx_pair_any_exists(stale_old_xlsx_path) or pdf_pair_any_exists(stale_old_pdf_path) or image_set_any_exists(stale_old_image_path):

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

