from __future__ import annotations

import os
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.pdf import REVISION_0 as PDF_REVISION_0, REVISION_1 as PDF_REVISION_1, REVISION_2 as PDF_REVISION_2, create_random_pdf_pair, mutate_pdf_pair_revision, validate_pdf_pair, copy_pdf_pair, pdf_pair_paths
from framework.image import REVISION_0 as IMAGE_REVISION_0, REVISION_1 as IMAGE_REVISION_1, REVISION_2 as IMAGE_REVISION_2, create_random_image_set, mutate_image_set_revision, validate_image_set, copy_image_set
from framework.manifest import snapshot_tree, diff_tree_snapshots, write_tree_snapshot
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_0, REVISION_1, REVISION_2, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, copy_xlsx_pair
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0068SafeBackupUploadOnlyConflictValidation(SafeBackupCaseBase):
    case_id = "0068"
    name = "safeBackup upload-only conflict validation"
    description = (
        "Validate with passive TXT plus real XLSX/PDF documents and PNG/JPEG image payloads that upload-only conflict handling preserves "
        "the entire local payload tree without creating safeBackups when newer online versions exist"
    )

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0068", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        local_root = work / "localroot"
        updater_root = work / "updaterroot"
        verify_root = work / "verifyroot"
        for root in (seed_root, local_root, updater_root, verify_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_local = work / "conf-local"
        conf_updater = work / "conf-updater"
        conf_verify = work / "conf-verify"
        for conf, root in ((conf_seed, seed_root), (conf_local, local_root), (conf_updater, updater_root), (conf_verify, verify_root)):
            self._prepare_config(context, conf, root)

        root_name = f"ZZ_E2E_TC0068_{context.run_id}_{os.getpid()}"
        text_relative = f"{root_name}/tracked-conflict.txt"
        xlsx_relative = f"{root_name}/tracked-conflict.xlsx"
        pdf_relative = f"{root_name}/tracked-conflict.pdf"
        image_relative = f"{root_name}/tracked-conflict.png"
        seed_text, seed_xlsx, seed_pdf, seed_image = seed_root / text_relative, seed_root / xlsx_relative, seed_root / pdf_relative, seed_root / image_relative
        local_text, local_xlsx, local_pdf, local_image = local_root / text_relative, local_root / xlsx_relative, local_root / pdf_relative, local_root / image_relative
        updater_text, updater_xlsx, updater_pdf, updater_image = updater_root / text_relative, updater_root / xlsx_relative, updater_root / pdf_relative, updater_root / image_relative
        verify_text, verify_xlsx, verify_pdf, verify_image = verify_root / text_relative, verify_root / xlsx_relative, verify_root / pdf_relative, verify_root / image_relative

        baseline_text = "TC0068 baseline\n"
        local_conflict_text = "TC0068 local upload-only conflict that must remain canonical locally\n"
        remote_newer_text = "TC0068 newer online content that upload-only must not download\n"
        write_text_file(seed_text, baseline_text)
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0068:{os.getpid()}"
        generated = create_random_xlsx_pair(
            seed_xlsx,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0068 upload-only conflict workbook",
        )
        pdf_seed = f"{xlsx_seed}:pdf"
        image_seed = f"{xlsx_seed}:image"
        generated_pdf = create_random_pdf_pair(
            seed_pdf,
            pdf_seed,
            revision=PDF_REVISION_0,
            title="TC0068 upload-only conflict PDF",
        )
        generated_images = create_random_image_set(seed_image, image_seed, revision=IMAGE_REVISION_0, title="TC0068 upload-only conflict images")

        phase_files = {label: (logs / f"{label}_stdout.log", logs / f"{label}_stderr.log") for label in ("seed", "initial", "remote_update", "upload_only", "repeat", "verify")}
        metadata_file = state / "metadata.txt"
        artifacts = [str(p) for pair in phase_files.values() for p in pair] + [str(metadata_file)]
        details: dict[str, object] = {
            "root_name": root_name,
            "text_relative": text_relative,
            "xlsx_relative": xlsx_relative,
            "pdf_relative": pdf_relative,
            "image_relative": image_relative,
            "xlsx_seed": xlsx_seed,
            "pdf_seed": pdf_seed,
            "image_seed": image_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_xlsx_size": int(generated["size_bytes"]),
            "generated_pdf_size": int(generated_pdf["size_bytes"]),
            "generated_large_pdf_size": int(generated_pdf["large_size_bytes"]),
            "generated_image_sizes": {k: int(v) for k, v in generated_images.items() if k.endswith("_size_bytes")},
        }

        seed = self._run_phase(context, label="seed", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_seed, mode="upload-only", resync=True), stdout_file=phase_files["seed"][0], stderr_file=phase_files["seed"][1])
        initial = self._run_phase(context, label="initial download", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="download-only", resync=True), stdout_file=phase_files["initial"][0], stderr_file=phase_files["initial"][1])
        initial_xlsx_error = validate_xlsx_pair(local_xlsx, REVISION_0)
        initial_pdf_error = validate_pdf_pair(local_pdf, PDF_REVISION_0)
        initial_image_error = validate_image_set(local_image, IMAGE_REVISION_0)
        details.update({"seed_returncode": seed.returncode, "initial_returncode": initial.returncode, "initial_xlsx_validation_error": initial_xlsx_error, "initial_pdf_validation_error": initial_pdf_error, "initial_image_validation_error": initial_image_error})
        if initial_pdf_error:
            # Capture bounded, non-content diagnostics for unexpectedly invalid
            # downloaded PDF fixtures; never turn invalid bytes into a PASS.
            pdf_diagnostics = {}
            for label, candidate in zip(("small", "large"), pdf_pair_paths(local_pdf)):
                if candidate.is_file():
                    with candidate.open("rb") as handle:
                        prefix = handle.read(16)
                    pdf_diagnostics[label] = {
                        "size_bytes": candidate.stat().st_size,
                        "first_16_bytes_hex": prefix.hex(),
                        "quickxor_hash": self._hash_if_file(candidate),
                    }
                else:
                    pdf_diagnostics[label] = {"missing": True}
            details["invalid_initial_pdf_diagnostics"] = pdf_diagnostics
        if seed.returncode != 0 or initial.returncode != 0 or self._text_if_file(local_text) != baseline_text or initial_xlsx_error or initial_pdf_error or initial_image_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Failed to establish tracked TXT/XLSX/PDF baseline: XLSX={initial_xlsx_error}; PDF={initial_pdf_error}", artifacts=artifacts, details=details)

        # Fork the Microsoft-settled workbook before mutating the local canonical copy.
        updater_xlsx.parent.mkdir(parents=True, exist_ok=True)
        copy_xlsx_pair(local_xlsx, updater_xlsx)
        copy_pdf_pair(local_pdf, updater_pdf)
        copy_image_set(local_image, updater_image)

        time.sleep(2)
        write_text_file(local_text, local_conflict_text)
        mutate_xlsx_pair_revision(local_xlsx, REVISION_0, REVISION_1)
        mutate_pdf_pair_revision(local_pdf, PDF_REVISION_0, PDF_REVISION_1)
        mutate_image_set_revision(local_image, IMAGE_REVISION_0, IMAGE_REVISION_1)

        time.sleep(2)
        write_text_file(updater_text, remote_newer_text)
        mutate_xlsx_pair_revision(updater_xlsx, REVISION_0, REVISION_2)
        mutate_pdf_pair_revision(updater_pdf, PDF_REVISION_0, PDF_REVISION_2)
        mutate_image_set_revision(updater_image, IMAGE_REVISION_0, IMAGE_REVISION_2)
        update = self._run_phase(context, label="remote update", command=self._single_directory_command(context, root_name=root_name, config_dir=conf_updater, mode="upload-only", resync=True), stdout_file=phase_files["remote_update"][0], stderr_file=phase_files["remote_update"][1])
        details["remote_update_returncode"] = update.returncode
        if update.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(reason=f"Remote update failed with status {update.returncode}", artifacts=artifacts, details=details)

        # Phase A: take the local snapshot *after* all fixture mutations and
        # remote updates, immediately before the subject client can run.
        before_file = state / "local_before.json"
        after_file = state / "local_after.json"
        repeat_file = state / "local_after_repeat.json"
        diff_file = state / "local_immutability_differences.txt"
        artifacts.extend(map(str, (before_file, after_file, repeat_file, diff_file)))
        before = snapshot_tree(local_root)
        write_tree_snapshot(before_file, before)

        upload_only = self._run_phase(
            context, label="upload-only conflict",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="upload-only"),
            stdout_file=phase_files["upload_only"][0], stderr_file=phase_files["upload_only"][1],
        )
        after = snapshot_tree(local_root)
        write_tree_snapshot(after_file, after)
        differences = diff_tree_snapshots(before, after)
        details.update({"upload_only_returncode": upload_only.returncode,
                        "local_immutability_differences": differences})

        # Do not spend another sync cycle on an already-proven red result.
        # After the implementation is fixed, the repeat catches non-converging
        # DB state and repeated preservation/upload behaviour.
        repeated = None
        if not differences and upload_only.returncode == 0:
            repeated = self._run_phase(
                context, label="upload-only repeated unchanged",
                command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="upload-only"),
                stdout_file=phase_files["repeat"][0], stderr_file=phase_files["repeat"][1],
            )
            after_repeat = snapshot_tree(local_root)
            write_tree_snapshot(repeat_file, after_repeat)
            differences.extend(diff_tree_snapshots(before, after_repeat))
        else:
            write_text_file(phase_files["repeat"][0], "SKIPPED: first upload-only run failed the immutability gate\n")
            write_text_file(phase_files["repeat"][1], "")
            write_text_file(repeat_file, '{"skipped": true, "reason": "first run failed"}\n')
        details["repeat_returncode"] = repeated.returncode if repeated is not None else "skipped_after_first_failure"
        details["local_immutability_differences"] = differences
        write_text_file(diff_file, "\n".join(differences) + ("\n" if differences else ""))

        verify = self._run_phase(
            context, label="verify remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=phase_files["verify"][0], stderr_file=phase_files["verify"][1],
        )
        remote_backups = sorted(
            p.relative_to(verify_root).as_posix() for p in (verify_root / root_name).rglob("*safeBackup*")
        )
        verify_xlsx_error = validate_xlsx_pair(verify_xlsx, REVISION_2)
        verify_pdf_error = validate_pdf_pair(verify_pdf, PDF_REVISION_2)
        verify_image_error = validate_image_set(verify_image, IMAGE_REVISION_2)
        details.update({
            "verify_returncode": verify.returncode,
            "remote_canonical_text": self._text_if_file(verify_text),
            "verify_xlsx_validation_error": verify_xlsx_error,
            "verify_pdf_validation_error": verify_pdf_error,
            "verify_image_validation_error": verify_image_error,
            "remote_safe_backup_paths": remote_backups,
        })
        self._write_metadata(metadata_file, details)

        failures = []
        if differences:
            failures.append(f"upload-only changed local filesystem ({len(differences)} differences); first: {differences[0]}")
        unexpected_downloads = self._unexpected_download_activity(upload_only.stdout)
        if unexpected_downloads:
            failures.append(f"upload-only attempted download-side reconciliation: {unexpected_downloads}")
        if repeated is not None:
            unexpected_uploads = self._unexpected_upload_activity(repeated.stdout)
            if unexpected_uploads:
                failures.append(f"unchanged repeat attempted uploads: {unexpected_uploads}")
            repeated_downloads = self._unexpected_download_activity(repeated.stdout)
            if repeated_downloads:
                failures.append(f"unchanged repeat attempted download-side reconciliation: {repeated_downloads}")
        if upload_only.returncode != 0:
            failures.append(f"upload-only conflict exited {upload_only.returncode}")
        if repeated is not None and repeated.returncode != 0:
            failures.append(f"repeated upload-only exited {repeated.returncode}")
        if verify.returncode != 0:
            failures.append(f"independent verification exited {verify.returncode}")
        elif self._text_if_file(verify_text) != remote_newer_text or verify_xlsx_error or verify_pdf_error or verify_image_error:
            failures.append(f"online-authoritative canonical content changed: XLSX={verify_xlsx_error}, PDF={verify_pdf_error}, images={verify_image_error}")
        if remote_backups:
            failures.append(f"upload-only created unexpected remote safeBackup files: {remote_backups[:5]}")
        if failures:
            return self.fail_result(reason="; ".join(failures), artifacts=artifacts, details=details)
        return self.pass_result(artifacts=artifacts, details=details)
