from __future__ import annotations

import os
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)
from framework.xlsx import REVISION_0, create_random_xlsx, validate_xlsx
from framework.pdf import (
    LARGE_PDF_IMAGE_HEIGHT,
    LARGE_PDF_IMAGE_WIDTH,
    SMALL_PDF_IMAGE_HEIGHT,
    SMALL_PDF_IMAGE_WIDTH,
    create_random_pdf,
    validate_pdf,
)
from framework.image import (
    LARGE_JPEG_HEIGHT,
    LARGE_JPEG_WIDTH,
    LARGE_PNG_HEIGHT,
    LARGE_PNG_WIDTH,
    SMALL_IMAGE_HEIGHT,
    SMALL_IMAGE_WIDTH,
    create_random_jpeg,
    create_random_png,
    validate_jpeg,
    validate_png,
)


class TestCase0037MtimeOnlyLocalChangeHandling(E2ETestCase):
    case_id = "0037"
    name = "mtime-only Microsoft file change handling"
    description = (
        "Validate mtime-only local XLSX, PDF, PNG and JPEG changes across initial simple upload, "
        "automatic session upload for files larger than 4 MiB, and forced session upload behaviour "
        "without changing file content"
    )

    SESSION_THRESHOLD_BYTES = 4 * 1024 * 1024
    SMALL_XLSX_PAYLOAD_ROWS = 80
    LARGE_XLSX_PAYLOAD_ROWS = 240

    def _write_config(self, config_dir: Path, sync_dir: Path, extra_config_lines: list[str] | None = None) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_lines = [
            "# tc0037 config",
            f'sync_dir = "{sync_dir}"',
            'bypass_data_preservation = "true"',
        ]

        if extra_config_lines:
            config_lines.extend(extra_config_lines)

        config_text = "\n".join(config_lines) + "\n"

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

    def _run_logged_command(
        self,
        context: E2EContext,
        command: list[str],
        stdout_path: Path,
        stderr_path: Path,
    ):
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_path, result.stdout)
        write_text_file(stderr_path, result.stderr)
        return result

    def _scenario_uses_session_upload(self, file_size_bytes: int, force_session_upload: bool) -> bool:
        if force_session_upload:
            return True
        return file_size_bytes > self.SESSION_THRESHOLD_BYTES

    def _run_scenario(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        scenario_id: str,
        scenario_name: str,
        payload_rows: int,
        force_session_upload: bool,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id

        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        local_root = scenario_work_dir / "syncroot"
        verify_initial_root = scenario_work_dir / "verify-initial-root"
        verify_final_root = scenario_work_dir / "verify-final-root"

        conf_main = scenario_work_dir / "conf-main"
        conf_verify_initial = scenario_work_dir / "conf-verify-initial"
        conf_verify_final = scenario_work_dir / "conf-verify-final"

        reset_directory(local_root)
        reset_directory(verify_initial_root)
        reset_directory(verify_final_root)

        context.prepare_minimal_config_dir(conf_main, "")
        context.prepare_minimal_config_dir(conf_verify_initial, "")
        context.prepare_minimal_config_dir(conf_verify_final, "")

        extra_config_lines: list[str] = []
        if force_session_upload:
            extra_config_lines.append('force_session_upload = "true"')

        self._write_config(conf_main, local_root, extra_config_lines)
        self._write_config(conf_verify_initial, verify_initial_root)
        self._write_config(conf_verify_final, verify_final_root)

        root_name = f"ZZ_E2E_TC0037_{scenario_id}_{context.run_id}_{os.getpid()}"
        relative_path = f"{root_name}/mtime-only.xlsx"
        pdf_relative_path = f"{root_name}/mtime-only.pdf"

        local_file_path = local_root / relative_path
        local_pdf_path = local_root / pdf_relative_path
        verify_initial_file_path = verify_initial_root / relative_path
        verify_initial_pdf_path = verify_initial_root / pdf_relative_path
        verify_final_file_path = verify_final_root / relative_path
        verify_final_pdf_path = verify_final_root / pdf_relative_path

        expected_manifest = [
            root_name,
            pdf_relative_path,
            relative_path,
        ]

        phase1_stdout = scenario_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_verify_initial_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_verify_initial_stderr.log"
        phase3_stdout = scenario_log_dir / "phase3_touch_sync_stdout.log"
        phase3_stderr = scenario_log_dir / "phase3_touch_sync_stderr.log"
        phase4_stdout = scenario_log_dir / "phase4_verify_final_stdout.log"
        phase4_stderr = scenario_log_dir / "phase4_verify_final_stderr.log"

        verify_initial_manifest_file = scenario_state_dir / "verify_initial_manifest.txt"
        verify_final_manifest_file = scenario_state_dir / "verify_final_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts.extend(
            [
                str(phase1_stdout),
                str(phase1_stderr),
                str(phase2_stdout),
                str(phase2_stderr),
                str(phase3_stdout),
                str(phase3_stderr),
                str(phase4_stdout),
                str(phase4_stderr),
                str(verify_initial_manifest_file),
                str(verify_final_manifest_file),
                str(metadata_file),
            ]
        )

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:{scenario_id}:{os.getpid()}"
        pdf_seed = f"{xlsx_seed}:pdf"
        generated = create_random_xlsx(
            local_file_path,
            xlsx_seed,
            payload_rows=payload_rows,
            title=f"TC0037 {scenario_id} mtime-only workbook",
        )
        pdf_is_large = payload_rows == self.LARGE_XLSX_PAYLOAD_ROWS
        generated_pdf = create_random_pdf(
            local_pdf_path,
            pdf_seed,
            revision=REVISION_0,
            image_width=LARGE_PDF_IMAGE_WIDTH if pdf_is_large else SMALL_PDF_IMAGE_WIDTH,
            image_height=LARGE_PDF_IMAGE_HEIGHT if pdf_is_large else SMALL_PDF_IMAGE_HEIGHT,
            title=f"TC0037 {scenario_id} mtime-only PDF",
        )
        initial_generated_hash = compute_quickxor_hash_file(local_file_path)
        initial_generated_pdf_hash = compute_quickxor_hash_file(local_pdf_path)
        initial_generated_size = local_file_path.stat().st_size
        initial_generated_pdf_size = local_pdf_path.stat().st_size
        uses_session_upload = self._scenario_uses_session_upload(initial_generated_size, force_session_upload)
        pdf_uses_session_upload = self._scenario_uses_session_upload(initial_generated_pdf_size, force_session_upload)

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "relative_path": relative_path,
            "payload_rows": payload_rows,
            "xlsx_seed": xlsx_seed,
            "pdf_seed": pdf_seed,
            "pdf_relative_path": pdf_relative_path,
            "generated_size": int(generated["size_bytes"]),
            "generated_pdf_size": int(generated_pdf["size_bytes"]),
            "initial_generated_hash": initial_generated_hash,
            "initial_generated_pdf_hash": initial_generated_pdf_hash,
            "initial_generated_size": initial_generated_size,
            "initial_generated_pdf_size": initial_generated_pdf_size,
            "force_session_upload": force_session_upload,
            "uses_session_upload": uses_session_upload,
            "pdf_uses_session_upload": pdf_uses_session_upload,
            "main_conf_dir": str(conf_main),
            "verify_initial_conf_dir": str(conf_verify_initial),
            "verify_final_conf_dir": str(conf_verify_final),
            "local_root": str(local_root),
            "verify_initial_root": str(verify_initial_root),
            "verify_final_root": str(verify_final_root),
            "expected_manifest": expected_manifest,
        }

        if payload_rows == self.SMALL_XLSX_PAYLOAD_ROWS and initial_generated_size > self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} small XLSX unexpectedly exceeded the 4 MiB session threshold", details
        if payload_rows == self.LARGE_XLSX_PAYLOAD_ROWS and initial_generated_size <= self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} large XLSX did not exceed the 4 MiB session threshold", details

        if not pdf_is_large and initial_generated_pdf_size > self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} small PDF unexpectedly exceeded the 4 MiB session threshold", details
        if pdf_is_large and initial_generated_pdf_size <= self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} large PDF did not exceed the 4 MiB session threshold", details

        # Phase 1: seed a real XLSX file. SharePoint may enrich the package after
        # upload, so the post-sync local file becomes the authoritative settled
        # content baseline for the mtime-only portion of this scenario.
        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        phase1_result = self._run_logged_command(context, phase1_command, phase1_stdout, phase1_stderr)
        details["phase1_returncode"] = phase1_result.returncode

        if phase1_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} seed phase failed with status {phase1_result.returncode}", details

        settled_validation_error = validate_xlsx(local_file_path, REVISION_0)
        settled_pdf_validation_error = validate_pdf(local_pdf_path, REVISION_0)
        details["settled_validation_error"] = settled_validation_error
        details["settled_pdf_validation_error"] = settled_pdf_validation_error
        if settled_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} seeded XLSX was invalid after initial sync: {settled_validation_error}", details
        if settled_pdf_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} seeded PDF was invalid after initial sync: {settled_pdf_validation_error}", details

        settled_local_hash = compute_quickxor_hash_file(local_file_path)
        settled_pdf_hash = compute_quickxor_hash_file(local_pdf_path)
        settled_local_size = local_file_path.stat().st_size
        settled_pdf_size = local_pdf_path.stat().st_size
        settled_local_mtime = int(local_file_path.stat().st_mtime)
        settled_pdf_mtime = int(local_pdf_path.stat().st_mtime)
        details["settled_local_hash"] = settled_local_hash
        details["settled_local_size"] = settled_local_size
        details["settled_local_mtime"] = settled_local_mtime
        details["settled_pdf_hash"] = settled_pdf_hash
        details["settled_pdf_size"] = settled_pdf_size
        details["settled_pdf_mtime"] = settled_pdf_mtime
        details["microsoft_changed_seed_bytes"] = settled_local_hash != initial_generated_hash
        details["microsoft_changed_pdf_seed_bytes"] = settled_pdf_hash != initial_generated_pdf_hash

        # Phase 2: verify the settled online workbook from a fresh client.
        phase2_command = [
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
            str(conf_verify_initial),
        ]
        phase2_result = self._run_logged_command(context, phase2_command, phase2_stdout, phase2_stderr)
        details["phase2_returncode"] = phase2_result.returncode

        verify_initial_manifest = build_manifest(verify_initial_root)
        write_manifest(verify_initial_manifest_file, verify_initial_manifest)
        details["verify_initial_manifest"] = verify_initial_manifest
        details["verify_initial_file_exists"] = verify_initial_file_path.is_file()
        details["verify_initial_pdf_exists"] = verify_initial_pdf_path.is_file()

        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote verification failed with status {phase2_result.returncode}", details

        if not verify_initial_file_path.is_file():
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote verification is missing expected file: {relative_path}", details
        if not verify_initial_pdf_path.is_file():
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote verification is missing expected PDF: {pdf_relative_path}", details

        baseline_validation_error = validate_xlsx(verify_initial_file_path, REVISION_0)
        baseline_pdf_validation_error = validate_pdf(verify_initial_pdf_path, REVISION_0)
        baseline_verified_hash = compute_quickxor_hash_file(verify_initial_file_path)
        baseline_verified_size = verify_initial_file_path.stat().st_size
        baseline_verified_mtime = int(verify_initial_file_path.stat().st_mtime)
        baseline_verified_pdf_hash = compute_quickxor_hash_file(verify_initial_pdf_path)
        baseline_verified_pdf_size = verify_initial_pdf_path.stat().st_size
        baseline_verified_pdf_mtime = int(verify_initial_pdf_path.stat().st_mtime)

        details["baseline_validation_error"] = baseline_validation_error
        details["baseline_pdf_validation_error"] = baseline_pdf_validation_error
        details["baseline_verified_hash"] = baseline_verified_hash
        details["baseline_verified_size"] = baseline_verified_size
        details["baseline_verified_mtime"] = baseline_verified_mtime
        details["baseline_verified_pdf_hash"] = baseline_verified_pdf_hash
        details["baseline_verified_pdf_size"] = baseline_verified_pdf_size
        details["baseline_verified_pdf_mtime"] = baseline_verified_pdf_mtime

        if baseline_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote XLSX validation failed: {baseline_validation_error}", details
        if baseline_pdf_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote PDF validation failed: {baseline_pdf_validation_error}", details
        if verify_initial_manifest != expected_manifest:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote verification manifest did not match expected structure", details
        if baseline_verified_hash != settled_local_hash:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote verification hash did not match the settled post-upload XLSX", details
        if baseline_verified_size != settled_local_size:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote verification size did not match the settled post-upload XLSX", details
        if baseline_verified_pdf_hash != settled_pdf_hash:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote verification hash did not match the settled post-upload PDF", details
        if baseline_verified_pdf_size != settled_pdf_size:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote verification size did not match the settled post-upload PDF", details

        # Phase 3: change only the local mtime. The workbook bytes, including any
        # Microsoft-added enrichment, must remain bit-for-bit unchanged.
        local_hash_before_touch = compute_quickxor_hash_file(local_file_path)
        local_pdf_hash_before_touch = compute_quickxor_hash_file(local_pdf_path)
        local_mtime_before_touch = int(local_file_path.stat().st_mtime)
        local_pdf_mtime_before_touch = int(local_pdf_path.stat().st_mtime)

        touched_epoch = max(
            int(time.time()),
            local_mtime_before_touch,
            local_pdf_mtime_before_touch,
            baseline_verified_mtime,
            baseline_verified_pdf_mtime,
        ) + 120
        os.utime(local_file_path, (touched_epoch, touched_epoch))
        os.utime(local_pdf_path, (touched_epoch, touched_epoch))

        local_hash_after_touch = compute_quickxor_hash_file(local_file_path)
        local_pdf_hash_after_touch = compute_quickxor_hash_file(local_pdf_path)
        local_mtime_after_touch = int(local_file_path.stat().st_mtime)
        local_pdf_mtime_after_touch = int(local_pdf_path.stat().st_mtime)

        details["local_hash_before_touch"] = local_hash_before_touch
        details["local_hash_after_touch"] = local_hash_after_touch
        details["local_mtime_before_touch"] = local_mtime_before_touch
        details["local_mtime_after_touch"] = local_mtime_after_touch
        details["local_pdf_hash_before_touch"] = local_pdf_hash_before_touch
        details["local_pdf_hash_after_touch"] = local_pdf_hash_after_touch
        details["local_pdf_mtime_before_touch"] = local_pdf_mtime_before_touch
        details["local_pdf_mtime_after_touch"] = local_pdf_mtime_after_touch
        details["touched_epoch"] = touched_epoch

        if local_hash_after_touch != local_hash_before_touch:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} local XLSX hash changed after mtime-only touch", details
        if local_mtime_after_touch <= local_mtime_before_touch:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} local XLSX mtime did not advance after touch", details
        if local_pdf_hash_after_touch != local_pdf_hash_before_touch:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} local PDF hash changed after mtime-only touch", details
        if local_pdf_mtime_after_touch <= local_pdf_mtime_before_touch:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} local PDF mtime did not advance after touch", details

        phase3_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        phase3_result = self._run_logged_command(context, phase3_command, phase3_stdout, phase3_stderr)
        details["phase3_returncode"] = phase3_result.returncode

        phase3_combined_output = phase3_result.stdout + "\n" + phase3_result.stderr
        content_unchanged_marker = (
            "The last modified timestamp has changed however the file content has not changed"
        )
        same_hash_marker = "The local item has the same hash value as the item online"
        correcting_timestamp_marker = "correcting online timestamp"
        online_apply_guard_marker = "ONLINE_APPLY_GUARD timestamp PATCH response changed file content identity"

        details["phase3_detected_content_unchanged_marker"] = content_unchanged_marker in phase3_combined_output
        details["phase3_detected_same_hash_marker"] = same_hash_marker in phase3_combined_output
        details["phase3_detected_correcting_timestamp_marker"] = correcting_timestamp_marker in phase3_combined_output
        details["phase3_detected_online_apply_guard_marker"] = online_apply_guard_marker in phase3_combined_output
        details["phase3_detected_xlsx_content_upload"] = f"Uploading modified file: {relative_path}" in phase3_combined_output

        if phase3_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} mtime-only sync phase failed with status {phase3_result.returncode}", details
        if content_unchanged_marker not in phase3_combined_output:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} did not log the expected content-unchanged timestamp handling marker", details
        if same_hash_marker not in phase3_combined_output:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} did not log the expected same-hash timestamp handling marker", details

        post_touch_validation_error = validate_xlsx(local_file_path, REVISION_0)
        post_touch_pdf_validation_error = validate_pdf(local_pdf_path, REVISION_0)
        details["post_touch_validation_error"] = post_touch_validation_error
        details["post_touch_pdf_validation_error"] = post_touch_pdf_validation_error
        if post_touch_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} local XLSX became invalid during mtime-only reconciliation: {post_touch_validation_error}", details
        if post_touch_pdf_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} local PDF became invalid during mtime-only reconciliation: {post_touch_pdf_validation_error}", details

        # Phase 4: final fresh remote verification.
        phase4_command = [
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
            str(conf_verify_final),
        ]
        phase4_result = self._run_logged_command(context, phase4_command, phase4_stdout, phase4_stderr)
        details["phase4_returncode"] = phase4_result.returncode

        verify_final_manifest = build_manifest(verify_final_root)
        write_manifest(verify_final_manifest_file, verify_final_manifest)
        details["verify_final_manifest"] = verify_final_manifest
        details["verify_final_file_exists"] = verify_final_file_path.is_file()
        details["verify_final_pdf_exists"] = verify_final_pdf_path.is_file()

        if phase4_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} final remote verification failed with status {phase4_result.returncode}", details
        if not verify_final_file_path.is_file():
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} final remote verification is missing expected file: {relative_path}", details
        if not verify_final_pdf_path.is_file():
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} final remote verification is missing expected PDF: {pdf_relative_path}", details

        final_validation_error = validate_xlsx(verify_final_file_path, REVISION_0)
        final_pdf_validation_error = validate_pdf(verify_final_pdf_path, REVISION_0)
        final_verified_hash = compute_quickxor_hash_file(verify_final_file_path)
        final_verified_size = verify_final_file_path.stat().st_size
        final_verified_mtime = int(verify_final_file_path.stat().st_mtime)
        final_verified_pdf_hash = compute_quickxor_hash_file(verify_final_pdf_path)
        final_verified_pdf_size = verify_final_pdf_path.stat().st_size
        final_verified_pdf_mtime = int(verify_final_pdf_path.stat().st_mtime)

        details["final_validation_error"] = final_validation_error
        details["final_pdf_validation_error"] = final_pdf_validation_error
        details["final_verified_hash"] = final_verified_hash
        details["final_verified_size"] = final_verified_size
        details["final_verified_mtime"] = final_verified_mtime
        details["final_verified_pdf_hash"] = final_verified_pdf_hash
        details["final_verified_pdf_size"] = final_verified_pdf_size
        details["final_verified_pdf_mtime"] = final_verified_pdf_mtime
        self._write_metadata(metadata_file, details)

        if final_validation_error:
            return False, f"{scenario_id} final remote XLSX validation failed: {final_validation_error}", details
        if final_pdf_validation_error:
            return False, f"{scenario_id} final remote PDF validation failed: {final_pdf_validation_error}", details
        if verify_final_manifest != expected_manifest:
            return False, f"{scenario_id} final remote verification manifest did not match expected structure", details
        # SharePoint can rewrite an Office package as part of the fileSystemInfo
        # timestamp PATCH itself. When that happens master deliberately reports
        # ONLINE_APPLY_GUARD and preserves the already-applied local baseline so
        # the newly changed remote content is reconciled normally. The logical
        # workbook revision must remain valid, but byte identity is no longer an
        # invariant for the SharePoint XLSX. PDF remains byte-for-byte stable.
        xlsx_changed_during_timestamp_patch = final_verified_hash != local_hash_after_touch
        details["xlsx_changed_during_timestamp_patch"] = xlsx_changed_during_timestamp_patch
        if context.e2e_target == "sharepoint" and xlsx_changed_during_timestamp_patch:
            # The normal (non-debug) E2E run cannot require the debug-only
            # ONLINE_APPLY_GUARD log line. Instead prove the client classified
            # this as same-content mtime handling and did not upload new XLSX
            # bytes; the fresh verifier then confirms the same logical revision.
            if details["phase3_detected_xlsx_content_upload"]:
                return (
                    False,
                    f"{scenario_id} unexpectedly uploaded XLSX content during an mtime-only SharePoint reconciliation",
                    details,
                )
        else:
            if final_verified_hash != local_hash_after_touch:
                return False, f"{scenario_id} final verified XLSX hash changed during an mtime-only operation", details
            if final_verified_size != settled_local_size:
                return False, f"{scenario_id} final verified XLSX size changed during an mtime-only operation", details

        if final_verified_pdf_hash != local_pdf_hash_after_touch:
            return False, f"{scenario_id} final verified PDF hash changed during an mtime-only operation", details
        if final_verified_pdf_size != settled_pdf_size:
            return False, f"{scenario_id} final verified PDF size changed during an mtime-only operation", details

        # Preserve the existing timestamp assertions. The initial transfer path is
        # deliberately varied because timestamp authority differs between simple
        # and session-upload workflows.
        if uses_session_upload:
            if abs(final_verified_mtime - touched_epoch) > 2:
                return (
                    False,
                    f"{scenario_id} final remote mtime {final_verified_mtime} did not match touched local timestamp {touched_epoch} within tolerance",
                    details,
                )
        else:
            if final_verified_mtime <= baseline_verified_mtime:
                return (
                    False,
                    f"{scenario_id} final remote mtime {final_verified_mtime} did not advance beyond baseline {baseline_verified_mtime}",
                    details,
                )
            if correcting_timestamp_marker not in phase3_combined_output:
                return (
                    False,
                    f"{scenario_id} did not log the expected online timestamp correction marker for direct upload handling",
                    details,
                )

        if pdf_uses_session_upload:
            if abs(final_verified_pdf_mtime - touched_epoch) > 2:
                return (
                    False,
                    f"{scenario_id} final PDF remote mtime {final_verified_pdf_mtime} did not match touched local timestamp {touched_epoch} within tolerance",
                    details,
                )
        else:
            if final_verified_pdf_mtime <= baseline_verified_pdf_mtime:
                return (
                    False,
                    f"{scenario_id} final PDF remote mtime {final_verified_pdf_mtime} did not advance beyond baseline {baseline_verified_pdf_mtime}",
                    details,
                )

        return True, f"{scenario_id} passed", details

    def _run_image_scenario(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        scenario_id: str,
        scenario_name: str,
        image_is_large: bool,
        force_session_upload: bool,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        """Validate mtime-only handling for genuine PNG/JPEG files without coupling to Office enrichment."""
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id

        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        local_root = scenario_work_dir / "syncroot"
        verify_initial_root = scenario_work_dir / "verify-initial-root"
        verify_final_root = scenario_work_dir / "verify-final-root"
        conf_main = scenario_work_dir / "conf-main"
        conf_verify_initial = scenario_work_dir / "conf-verify-initial"
        conf_verify_final = scenario_work_dir / "conf-verify-final"

        reset_directory(local_root)
        reset_directory(verify_initial_root)
        reset_directory(verify_final_root)
        context.prepare_minimal_config_dir(conf_main, "")
        context.prepare_minimal_config_dir(conf_verify_initial, "")
        context.prepare_minimal_config_dir(conf_verify_final, "")

        extra_config_lines: list[str] = []
        if force_session_upload:
            extra_config_lines.append('force_session_upload = "true"')
        self._write_config(conf_main, local_root, extra_config_lines)
        self._write_config(conf_verify_initial, verify_initial_root)
        self._write_config(conf_verify_final, verify_final_root)

        root_name = f"ZZ_E2E_TC0037_{scenario_id}_{context.run_id}_{os.getpid()}"
        png_relative_path = f"{root_name}/mtime-only.png"
        jpeg_relative_path = f"{root_name}/mtime-only.jpg"
        local_png_path = local_root / png_relative_path
        local_jpeg_path = local_root / jpeg_relative_path
        verify_initial_png_path = verify_initial_root / png_relative_path
        verify_initial_jpeg_path = verify_initial_root / jpeg_relative_path
        verify_final_png_path = verify_final_root / png_relative_path
        verify_final_jpeg_path = verify_final_root / jpeg_relative_path
        expected_manifest = sorted([root_name, png_relative_path, jpeg_relative_path])

        phase1_stdout = scenario_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_verify_initial_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_verify_initial_stderr.log"
        phase3_stdout = scenario_log_dir / "phase3_touch_sync_stdout.log"
        phase3_stderr = scenario_log_dir / "phase3_touch_sync_stderr.log"
        phase3_retry_stdout = scenario_log_dir / "phase3_retry_stdout.log"
        phase3_retry_stderr = scenario_log_dir / "phase3_retry_stderr.log"
        phase4_stdout = scenario_log_dir / "phase4_verify_final_stdout.log"
        phase4_stderr = scenario_log_dir / "phase4_verify_final_stderr.log"
        verify_initial_manifest_file = scenario_state_dir / "verify_initial_manifest.txt"
        verify_final_manifest_file = scenario_state_dir / "verify_final_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts.extend(
            [
                str(phase1_stdout), str(phase1_stderr),
                str(phase2_stdout), str(phase2_stderr),
                str(phase3_stdout), str(phase3_stderr),
                str(phase3_retry_stdout), str(phase3_retry_stderr),
                str(phase4_stdout), str(phase4_stderr),
                str(verify_initial_manifest_file), str(verify_final_manifest_file),
                str(metadata_file),
            ]
        )

        seed = f"{context.run_id}:{context.e2e_target}:{scenario_id}:{os.getpid()}"
        png_width = LARGE_PNG_WIDTH if image_is_large else SMALL_IMAGE_WIDTH
        png_height = LARGE_PNG_HEIGHT if image_is_large else SMALL_IMAGE_HEIGHT
        jpeg_width = LARGE_JPEG_WIDTH if image_is_large else SMALL_IMAGE_WIDTH
        jpeg_height = LARGE_JPEG_HEIGHT if image_is_large else SMALL_IMAGE_HEIGHT

        png_generated = create_random_png(
            local_png_path,
            f"{seed}:png",
            revision=REVISION_0,
            width=png_width,
            height=png_height,
            title=f"TC0037 {scenario_id} mtime-only PNG",
        )
        jpeg_generated = create_random_jpeg(
            local_jpeg_path,
            f"{seed}:jpeg",
            revision=REVISION_0,
            width=jpeg_width,
            height=jpeg_height,
            title=f"TC0037 {scenario_id} mtime-only JPEG",
        )

        png_size = local_png_path.stat().st_size
        jpeg_size = local_jpeg_path.stat().st_size
        png_hash = compute_quickxor_hash_file(local_png_path)
        jpeg_hash = compute_quickxor_hash_file(local_jpeg_path)
        uses_session_upload = force_session_upload or image_is_large

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "png_relative_path": png_relative_path,
            "jpeg_relative_path": jpeg_relative_path,
            "image_is_large": image_is_large,
            "force_session_upload": force_session_upload,
            "uses_session_upload": uses_session_upload,
            "png_size": png_size,
            "jpeg_size": jpeg_size,
            "png_generated": png_generated,
            "jpeg_generated": jpeg_generated,
            "initial_png_hash": png_hash,
            "initial_jpeg_hash": jpeg_hash,
            "expected_manifest": expected_manifest,
        }

        if image_is_large:
            if png_size <= self.SESSION_THRESHOLD_BYTES or jpeg_size <= self.SESSION_THRESHOLD_BYTES:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_id} large PNG/JPEG fixture did not exceed the 4 MiB session threshold", details
        else:
            if png_size > self.SESSION_THRESHOLD_BYTES or jpeg_size > self.SESSION_THRESHOLD_BYTES:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_id} small PNG/JPEG fixture unexpectedly exceeded the 4 MiB session threshold", details

        phase1_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--single-directory", root_name, "--confdir", str(conf_main),
        ]
        phase1_result = self._run_logged_command(context, phase1_command, phase1_stdout, phase1_stderr)
        details["phase1_returncode"] = phase1_result.returncode
        if phase1_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} image seed phase failed with status {phase1_result.returncode}", details

        png_validation_error = validate_png(local_png_path, REVISION_0)
        jpeg_validation_error = validate_jpeg(local_jpeg_path, REVISION_0)
        settled_png_hash = compute_quickxor_hash_file(local_png_path)
        settled_jpeg_hash = compute_quickxor_hash_file(local_jpeg_path)
        settled_png_size = local_png_path.stat().st_size
        settled_jpeg_size = local_jpeg_path.stat().st_size
        settled_png_mtime = int(local_png_path.stat().st_mtime)
        settled_jpeg_mtime = int(local_jpeg_path.stat().st_mtime)
        details.update(
            {
                "settled_png_validation_error": png_validation_error,
                "settled_jpeg_validation_error": jpeg_validation_error,
                "settled_png_hash": settled_png_hash,
                "settled_jpeg_hash": settled_jpeg_hash,
                "settled_png_size": settled_png_size,
                "settled_jpeg_size": settled_jpeg_size,
                "settled_png_mtime": settled_png_mtime,
                "settled_jpeg_mtime": settled_jpeg_mtime,
            }
        )
        if png_validation_error or jpeg_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} seeded PNG/JPEG validation failed: {png_validation_error or jpeg_validation_error}", details
        if settled_png_hash != png_hash or settled_jpeg_hash != jpeg_hash:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} Microsoft unexpectedly changed PNG/JPEG bytes during seed", details

        phase2_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose",
            "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_verify_initial),
        ]
        phase2_result = self._run_logged_command(context, phase2_command, phase2_stdout, phase2_stderr)
        details["phase2_returncode"] = phase2_result.returncode
        verify_initial_manifest = build_manifest(verify_initial_root)
        write_manifest(verify_initial_manifest_file, verify_initial_manifest)
        details["verify_initial_manifest"] = verify_initial_manifest
        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial image verification failed with status {phase2_result.returncode}", details
        if verify_initial_manifest != expected_manifest:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial image verification manifest did not match expected structure", details

        initial_png_validation_error = validate_png(verify_initial_png_path, REVISION_0)
        initial_jpeg_validation_error = validate_jpeg(verify_initial_jpeg_path, REVISION_0)
        baseline_png_hash = compute_quickxor_hash_file(verify_initial_png_path)
        baseline_jpeg_hash = compute_quickxor_hash_file(verify_initial_jpeg_path)
        baseline_png_mtime = int(verify_initial_png_path.stat().st_mtime)
        baseline_jpeg_mtime = int(verify_initial_jpeg_path.stat().st_mtime)
        details.update(
            {
                "initial_png_validation_error": initial_png_validation_error,
                "initial_jpeg_validation_error": initial_jpeg_validation_error,
                "baseline_png_hash": baseline_png_hash,
                "baseline_jpeg_hash": baseline_jpeg_hash,
                "baseline_png_mtime": baseline_png_mtime,
                "baseline_jpeg_mtime": baseline_jpeg_mtime,
            }
        )
        if initial_png_validation_error or initial_jpeg_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote PNG/JPEG validation failed: {initial_png_validation_error or initial_jpeg_validation_error}", details
        if baseline_png_hash != settled_png_hash or baseline_jpeg_hash != settled_jpeg_hash:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} initial remote PNG/JPEG content did not match the settled local content", details

        touched_epoch = max(
            int(time.time()),
            settled_png_mtime,
            settled_jpeg_mtime,
            baseline_png_mtime,
            baseline_jpeg_mtime,
        ) + 120
        os.utime(local_png_path, (touched_epoch, touched_epoch))
        os.utime(local_jpeg_path, (touched_epoch, touched_epoch))
        touched_png_hash = compute_quickxor_hash_file(local_png_path)
        touched_jpeg_hash = compute_quickxor_hash_file(local_jpeg_path)
        details.update(
            {
                "touched_epoch": touched_epoch,
                "touched_png_hash": touched_png_hash,
                "touched_jpeg_hash": touched_jpeg_hash,
                "touched_png_mtime": int(local_png_path.stat().st_mtime),
                "touched_jpeg_mtime": int(local_jpeg_path.stat().st_mtime),
            }
        )
        if touched_png_hash != settled_png_hash or touched_jpeg_hash != settled_jpeg_hash:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} PNG/JPEG bytes changed during local mtime-only touch", details

        phase3_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--single-directory", root_name, "--confdir", str(conf_main),
        ]
        phase3_result = self._run_logged_command(context, phase3_command, phase3_stdout, phase3_stderr)
        phase3_output = phase3_result.stdout + "\n" + phase3_result.stderr
        details["phase3_returncode"] = phase3_result.returncode
        details["phase3_timestamp_412_count"] = phase3_output.count(
            "HTTP 412 - Precondition Failed' when attempting file time stamp update"
        )
        details["phase3_content_unchanged_count"] = phase3_output.count(
            "The last modified timestamp has changed however the file content has not changed"
        )
        details["phase3_same_hash_count"] = phase3_output.count(
            "The local item has the same hash value as the item online"
        )
        details["phase3_timestamp_correction_count"] = phase3_output.count("correcting online timestamp")
        details["phase3_png_processed"] = f"Processing: {png_relative_path}" in phase3_output
        details["phase3_jpeg_processed"] = f"Processing: {jpeg_relative_path}" in phase3_output
        if phase3_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} image mtime-only sync failed with status {phase3_result.returncode}", details
        if not details["phase3_png_processed"] or not details["phase3_jpeg_processed"]:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} did not process both PNG and JPEG during mtime-only reconciliation", details
        if details["phase3_content_unchanged_count"] < 2 or details["phase3_same_hash_count"] < 2:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} did not exercise same-content mtime handling for both image formats", details
        if f"Uploading modified file: {png_relative_path}" in phase3_output or f"Uploading modified file: {jpeg_relative_path}" in phase3_output:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} incorrectly uploaded image content for an mtime-only local change", details

        # A 412 is a supported race: Microsoft changed the remote eTag after the
        # consistency check. Production code deliberately defers the timestamp
        # correction until the following delta/true-up has reconciled that newer
        # remote identity. Exercise that real recovery path with one normal retry.
        retry_output = ""
        if details["phase3_timestamp_412_count"]:
            retry_result = self._run_logged_command(
                context, phase3_command, phase3_retry_stdout, phase3_retry_stderr
            )
            retry_output = retry_result.stdout + "\n" + retry_result.stderr
            details["phase3_retry_returncode"] = retry_result.returncode
            details["phase3_retry_timestamp_412_count"] = retry_output.count(
                "HTTP 412 - Precondition Failed' when attempting file time stamp update"
            )
            if retry_result.returncode != 0:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_id} deferred timestamp retry failed with status {retry_result.returncode}", details
            if details["phase3_retry_timestamp_412_count"]:
                self._write_metadata(metadata_file, details)
                return False, f"{scenario_id} image timestamp correction still hit HTTP 412 after delta reconciliation", details
        else:
            details["phase3_retry_returncode"] = None
            details["phase3_retry_timestamp_412_count"] = 0
            write_text_file(phase3_retry_stdout, "not required\n")
            write_text_file(phase3_retry_stderr, "")

        post_phase3_png_validation_error = validate_png(local_png_path, REVISION_0)
        post_phase3_jpeg_validation_error = validate_jpeg(local_jpeg_path, REVISION_0)
        post_phase3_png_hash = compute_quickxor_hash_file(local_png_path)
        post_phase3_jpeg_hash = compute_quickxor_hash_file(local_jpeg_path)
        details.update(
            {
                "post_phase3_png_validation_error": post_phase3_png_validation_error,
                "post_phase3_jpeg_validation_error": post_phase3_jpeg_validation_error,
                "post_phase3_png_hash": post_phase3_png_hash,
                "post_phase3_jpeg_hash": post_phase3_jpeg_hash,
            }
        )
        if post_phase3_png_validation_error or post_phase3_jpeg_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} local PNG/JPEG became invalid during mtime-only reconciliation", details
        if post_phase3_png_hash != touched_png_hash or post_phase3_jpeg_hash != touched_jpeg_hash:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} local PNG/JPEG bytes changed during mtime-only reconciliation", details

        phase4_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose",
            "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_verify_final),
        ]
        phase4_result = self._run_logged_command(context, phase4_command, phase4_stdout, phase4_stderr)
        details["phase4_returncode"] = phase4_result.returncode
        verify_final_manifest = build_manifest(verify_final_root)
        write_manifest(verify_final_manifest_file, verify_final_manifest)
        details["verify_final_manifest"] = verify_final_manifest
        if phase4_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} final image verification failed with status {phase4_result.returncode}", details
        if verify_final_manifest != expected_manifest:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} final image verification manifest did not match expected structure", details

        final_png_validation_error = validate_png(verify_final_png_path, REVISION_0)
        final_jpeg_validation_error = validate_jpeg(verify_final_jpeg_path, REVISION_0)
        final_png_hash = compute_quickxor_hash_file(verify_final_png_path)
        final_jpeg_hash = compute_quickxor_hash_file(verify_final_jpeg_path)
        final_png_size = verify_final_png_path.stat().st_size
        final_jpeg_size = verify_final_jpeg_path.stat().st_size
        final_png_mtime = int(verify_final_png_path.stat().st_mtime)
        final_jpeg_mtime = int(verify_final_jpeg_path.stat().st_mtime)
        details.update(
            {
                "final_png_validation_error": final_png_validation_error,
                "final_jpeg_validation_error": final_jpeg_validation_error,
                "final_png_hash": final_png_hash,
                "final_jpeg_hash": final_jpeg_hash,
                "final_png_size": final_png_size,
                "final_jpeg_size": final_jpeg_size,
                "final_png_mtime": final_png_mtime,
                "final_jpeg_mtime": final_jpeg_mtime,
            }
        )
        self._write_metadata(metadata_file, details)

        if final_png_validation_error or final_jpeg_validation_error:
            return False, f"{scenario_id} final remote PNG/JPEG validation failed: {final_png_validation_error or final_jpeg_validation_error}", details
        if final_png_hash != touched_png_hash or final_jpeg_hash != touched_jpeg_hash:
            return False, f"{scenario_id} final remote PNG/JPEG bytes changed during an mtime-only operation", details
        if final_png_size != settled_png_size or final_jpeg_size != settled_jpeg_size:
            return False, f"{scenario_id} final remote PNG/JPEG size changed during an mtime-only operation", details

        if uses_session_upload:
            if abs(final_png_mtime - touched_epoch) > 2 or abs(final_jpeg_mtime - touched_epoch) > 2:
                return False, f"{scenario_id} final remote PNG/JPEG mtimes did not match the touched local timestamp within tolerance", details
        else:
            if final_png_mtime <= baseline_png_mtime or final_jpeg_mtime <= baseline_jpeg_mtime:
                return False, f"{scenario_id} final remote PNG/JPEG mtimes did not advance beyond baseline", details
            if details["phase3_timestamp_correction_count"] < 2:
                return False, f"{scenario_id} did not log timestamp correction for both direct-upload image fixtures", details

        return True, f"{scenario_id} passed", details

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0037",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        artifacts: list[str] = []
        details: dict[str, object] = {}

        document_scenarios = [
            {
                "scenario_id": "MT-0001",
                "scenario_name": "small XLSX/PDF with default simple-upload seed behaviour",
                "payload_rows": self.SMALL_XLSX_PAYLOAD_ROWS,
                "force_session_upload": False,
            },
            {
                "scenario_id": "MT-0002",
                "scenario_name": "large XLSX/PDF greater than 4 MiB with automatic session-upload seed behaviour",
                "payload_rows": self.LARGE_XLSX_PAYLOAD_ROWS,
                "force_session_upload": False,
            },
            {
                "scenario_id": "MT-0003",
                "scenario_name": "small XLSX/PDF with force_session_upload enabled",
                "payload_rows": self.SMALL_XLSX_PAYLOAD_ROWS,
                "force_session_upload": True,
            },
            {
                "scenario_id": "MT-0004",
                "scenario_name": "large XLSX/PDF greater than 4 MiB with force_session_upload enabled",
                "payload_rows": self.LARGE_XLSX_PAYLOAD_ROWS,
                "force_session_upload": True,
            },
        ]
        image_scenarios = [
            {
                "scenario_id": "IMG-0001",
                "scenario_name": "small PNG/JPEG with default simple-upload seed behaviour",
                "image_is_large": False,
                "force_session_upload": False,
            },
            {
                "scenario_id": "IMG-0002",
                "scenario_name": "large PNG/JPEG greater than 4 MiB with automatic session-upload seed behaviour",
                "image_is_large": True,
                "force_session_upload": False,
            },
            {
                "scenario_id": "IMG-0003",
                "scenario_name": "small PNG/JPEG with force_session_upload enabled",
                "image_is_large": False,
                "force_session_upload": True,
            },
            {
                "scenario_id": "IMG-0004",
                "scenario_name": "large PNG/JPEG greater than 4 MiB with force_session_upload enabled",
                "image_is_large": True,
                "force_session_upload": True,
            },
        ]

        document_scenarios = [
            scenario for scenario in document_scenarios
            if context.should_run_scenario(self.case_id, scenario["scenario_id"])
        ]
        image_scenarios = [
            scenario for scenario in image_scenarios
            if context.should_run_scenario(self.case_id, scenario["scenario_id"])
        ]

        failed_scenarios: list[str] = []
        executed_scenario_ids: list[str] = []

        for scenario in document_scenarios:
            passed, message, scenario_details = self._run_scenario(
                context=context,
                case_work_dir=case_work_dir,
                case_log_dir=case_log_dir,
                state_dir=state_dir,
                scenario_id=scenario["scenario_id"],
                scenario_name=scenario["scenario_name"],
                payload_rows=scenario["payload_rows"],
                force_session_upload=scenario["force_session_upload"],
                artifacts=artifacts,
            )
            scenario_id = scenario["scenario_id"]
            executed_scenario_ids.append(scenario_id)
            details[scenario_id] = scenario_details
            details[f"{scenario_id}_passed"] = passed
            details[f"{scenario_id}_message"] = message
            if not passed:
                failed_scenarios.append(scenario_id)

        for scenario in image_scenarios:
            passed, message, scenario_details = self._run_image_scenario(
                context=context,
                case_work_dir=case_work_dir,
                case_log_dir=case_log_dir,
                state_dir=state_dir,
                scenario_id=scenario["scenario_id"],
                scenario_name=scenario["scenario_name"],
                image_is_large=scenario["image_is_large"],
                force_session_upload=scenario["force_session_upload"],
                artifacts=artifacts,
            )
            scenario_id = scenario["scenario_id"]
            executed_scenario_ids.append(scenario_id)
            details[scenario_id] = scenario_details
            details[f"{scenario_id}_passed"] = passed
            details[f"{scenario_id}_message"] = message
            if not passed:
                failed_scenarios.append(scenario_id)

        details["executed_scenario_ids"] = executed_scenario_ids
        details["failed_scenario_ids"] = list(failed_scenarios)

        summary_file = state_dir / "scenario-summary.txt"
        summary_lines: list[str] = []
        for scenario_id in executed_scenario_ids:
            summary_lines.append(
                f"{scenario_id}: passed={details.get(f'{scenario_id}_passed')} "
                f"message={details.get(f'{scenario_id}_message')!r}"
            )
        write_text_file(summary_file, "\n".join(summary_lines) + "\n")
        artifacts.append(str(summary_file))

        metadata_file = state_dir / "metadata.txt"
        self._write_metadata(metadata_file, details)
        artifacts.append(str(metadata_file))

        if failed_scenarios:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failed_scenarios)} of {len(executed_scenario_ids)} mtime-only document/image scenarios failed: {', '.join(failed_scenarios)}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
