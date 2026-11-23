from __future__ import annotations

import os
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.pdf import REVISION_1 as PDF_REVISION_1, REVISION_2 as PDF_REVISION_2, create_random_pdf_pair, mutate_pdf_pair_revision, validate_pdf_pair, set_pdf_pair_mtime, copy_pdf_pair
from framework.image import REVISION_1 as IMAGE_REVISION_1, REVISION_2 as IMAGE_REVISION_2, create_random_image_set, mutate_image_set_revision, validate_image_set, set_image_set_mtime, copy_image_set
from framework.manifest import snapshot_tree, diff_tree_snapshots, write_tree_snapshot
from framework.utils import reset_directory, write_text_file
from framework.xlsx import REVISION_1, REVISION_2, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, set_xlsx_pair_mtime, copy_xlsx_pair
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0070SafeBackupNewFileUploadCollisionValidation(SafeBackupCaseBase):
    case_id = "0070"
    name = "safeBackup new-file upload collision validation"
    description = (
        "Validate with passive TXT plus real XLSX/PDF documents and PNG/JPEG image payloads that the no-database/new-local-file collision path "
        "under upload-only preserves every local payload path without a safeBackup when newer "
        "same-name online files already exist"
    )

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0070", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir

        seed_root = work / "seedroot"
        local_root = work / "localroot"
        verify_root = work / "verifyroot"
        for root in (seed_root, local_root, verify_root):
            reset_directory(root)

        conf_seed = work / "conf-seed"
        conf_local = work / "conf-local"
        conf_verify = work / "conf-verify"
        self._prepare_config(context, conf_seed, seed_root)
        self._prepare_config(context, conf_local, local_root)
        self._prepare_config(context, conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0070_{context.run_id}_{os.getpid()}"
        text_relative = f"{root_name}/new-file-collision.txt"
        xlsx_relative = f"{root_name}/new-file-collision.xlsx"
        pdf_relative = f"{root_name}/new-file-collision.pdf"
        image_relative = f"{root_name}/new-file-collision.png"
        seed_text = seed_root / text_relative
        seed_xlsx = seed_root / xlsx_relative
        seed_pdf = seed_root / pdf_relative
        seed_image = seed_root / image_relative
        local_text = local_root / text_relative
        local_xlsx = local_root / xlsx_relative
        local_pdf = local_root / pdf_relative
        local_image = local_root / image_relative
        verify_text = verify_root / text_relative
        verify_xlsx = verify_root / xlsx_relative
        verify_pdf = verify_root / pdf_relative
        verify_image = verify_root / image_relative

        local_text_content = "TC0070 older local untracked file that must remain canonical under upload-only\n"
        remote_text_content = "TC0070 newer online file with the same pathname\n"
        write_text_file(local_text, local_text_content)

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0070:{os.getpid()}"
        generated = create_random_xlsx_pair(
            local_xlsx,
            xlsx_seed,
            revision=REVISION_1,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0070 older untracked local workbook",
        )
        pdf_seed = f"{xlsx_seed}:pdf"
        image_seed = f"{xlsx_seed}:image"
        generated_pdf = create_random_pdf_pair(
            local_pdf,
            pdf_seed,
            revision=PDF_REVISION_1,
            title="TC0070 older untracked local PDF",
        )
        generated_images = create_random_image_set(local_image, image_seed, revision=IMAGE_REVISION_1, title="TC0070 older untracked local images")

        old_epoch = int(time.time()) - 3600
        os.utime(local_text, (old_epoch, old_epoch))
        set_xlsx_pair_mtime(local_xlsx, (old_epoch, old_epoch))
        set_pdf_pair_mtime(local_pdf, (old_epoch, old_epoch))
        set_image_set_mtime(local_image, (old_epoch, old_epoch))

        # Build the newer online XLSX from the exact local package, then change only the
        # revision marker. This gives the collision two realistic related document versions
        # while keeping the subject client completely untracked.
        time.sleep(2)
        write_text_file(seed_text, remote_text_content)
        seed_xlsx.parent.mkdir(parents=True, exist_ok=True)
        copy_xlsx_pair(local_xlsx, seed_xlsx)
        copy_pdf_pair(local_pdf, seed_pdf)
        copy_image_set(local_image, seed_image)
        mutate_xlsx_pair_revision(seed_xlsx, REVISION_1, REVISION_2)
        mutate_pdf_pair_revision(seed_pdf, PDF_REVISION_1, PDF_REVISION_2)
        mutate_image_set_revision(seed_image, IMAGE_REVISION_1, IMAGE_REVISION_2)

        seed_stdout, seed_stderr = logs / "seed_stdout.log", logs / "seed_stderr.log"
        collision_stdout, collision_stderr = logs / "collision_stdout.log", logs / "collision_stderr.log"
        repeat_stdout, repeat_stderr = logs / "repeat_stdout.log", logs / "repeat_stderr.log"
        verify_stdout, verify_stderr = logs / "verify_stdout.log", logs / "verify_stderr.log"
        metadata_file = state / "metadata.txt"
        artifacts = [
            str(seed_stdout), str(seed_stderr),
            str(collision_stdout), str(collision_stderr),
            str(repeat_stdout), str(repeat_stderr),
            str(verify_stdout), str(verify_stderr),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "root_name": root_name,
            "text_relative": text_relative,
            "xlsx_relative": xlsx_relative,
            "pdf_relative": pdf_relative,
            "image_relative": image_relative,
            "local_initial_mtime": old_epoch,
            "xlsx_seed": xlsx_seed,
            "pdf_seed": pdf_seed,
            "image_seed": image_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_local_xlsx_size": int(generated["size_bytes"]),
            "generated_local_pdf_size": int(generated_pdf["size_bytes"]),
            "generated_local_large_pdf_size": int(generated_pdf["large_size_bytes"]),
            "generated_local_image_sizes": {k: int(v) for k, v in generated_images.items() if k.endswith("_size_bytes")},
        }

        seed = self._run_phase(
            context,
            label="seed newer remote TXT/XLSX/PDF",
            command=self._single_directory_command(
                context,
                root_name=root_name,
                config_dir=conf_seed,
                mode="upload-only",
                resync=True,
            ),
            stdout_file=seed_stdout,
            stderr_file=seed_stderr,
        )
        details["seed_returncode"] = seed.returncode
        if seed.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"Remote seed failed with status {seed.returncode}",
                artifacts=artifacts,
                details=details,
            )

        # The remote seed is complete; there are no further fixture writes to
        # this local tree until after the subject sync has been observed.
        before_file = state / "local_before.json"
        after_file = state / "local_after.json"
        repeat_file = state / "local_after_repeat.json"
        diff_file = state / "local_immutability_differences.txt"
        artifacts.extend(map(str, (before_file, after_file, repeat_file, diff_file)))
        before = snapshot_tree(local_root)
        write_tree_snapshot(before_file, before)
        collision = self._run_phase(
            context, label="new-file upload-only collision",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="upload-only", verbose_count=2),
            stdout_file=collision_stdout, stderr_file=collision_stderr,
        )
        after = snapshot_tree(local_root)
        write_tree_snapshot(after_file, after)
        differences = diff_tree_snapshots(before, after)
        repeated = None
        if not differences and collision.returncode == 0:
            repeated = self._run_phase(
                context, label="new-file upload-only collision repeated unchanged",
                command=self._single_directory_command(context, root_name=root_name, config_dir=conf_local, mode="upload-only"),
                stdout_file=repeat_stdout, stderr_file=repeat_stderr,
            )
            after_repeat = snapshot_tree(local_root)
            write_tree_snapshot(repeat_file, after_repeat)
            differences.extend(diff_tree_snapshots(before, after_repeat))
        else:
            write_text_file(repeat_stdout, "SKIPPED: first upload-only run failed the immutability gate\n")
            write_text_file(repeat_stderr, "")
            write_text_file(repeat_file, '{"skipped": true, "reason": "first run failed"}\n')
        details.update({
            "collision_returncode": collision.returncode,
            "repeat_returncode": repeated.returncode if repeated is not None else "skipped_after_first_failure",
            "local_immutability_differences": differences,
        })
        write_text_file(diff_file, "\n".join(differences) + ("\n" if differences else ""))

        verify = self._run_phase(
            context, label="verify remote",
            command=self._single_directory_command(context, root_name=root_name, config_dir=conf_verify, mode="download-only", resync=True),
            stdout_file=verify_stdout, stderr_file=verify_stderr,
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
        unexpected_downloads = self._unexpected_download_activity(collision.stdout)
        if unexpected_downloads:
            failures.append(f"upload-only attempted download-side reconciliation: {unexpected_downloads}")
        if repeated is not None:
            unexpected_uploads = self._unexpected_upload_activity(repeated.stdout)
            if unexpected_uploads:
                failures.append(f"unchanged repeat attempted uploads: {unexpected_uploads}")
            repeated_downloads = self._unexpected_download_activity(repeated.stdout)
            if repeated_downloads:
                failures.append(f"unchanged repeat attempted download-side reconciliation: {repeated_downloads}")
        if collision.returncode != 0:
            failures.append(f"upload-only collision exited {collision.returncode}")
        if repeated is not None and repeated.returncode != 0:
            failures.append(f"repeated collision exited {repeated.returncode}")
        if verify.returncode != 0:
            failures.append(f"independent verification exited {verify.returncode}")
        elif self._text_if_file(verify_text) != remote_text_content or verify_xlsx_error or verify_pdf_error or verify_image_error:
            failures.append(f"online-authoritative canonical content changed: XLSX={verify_xlsx_error}, PDF={verify_pdf_error}, images={verify_image_error}")
        if remote_backups:
            failures.append(f"upload-only created unexpected remote safeBackup files: {remote_backups[:5]}")
        if failures:
            return self.fail_result(reason="; ".join(failures), artifacts=artifacts, details=details)
        return self.pass_result(artifacts=artifacts, details=details)
