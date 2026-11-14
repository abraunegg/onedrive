from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.pdf import REVISION_0 as PDF_REVISION_0, create_random_pdf_pair, validate_pdf_pair, rename_pdf_pair, large_pdf_relative, pdf_pair_any_exists, pdf_pair_all_files
from framework.image import create_random_image_set, validate_image_set, rename_image_set, image_set_relatives, image_set_any_exists, image_set_all_files
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file
from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, rename_xlsx_pair, large_xlsx_relative, xlsx_pair_any_exists, xlsx_pair_all_files


class TestCase0060MonitorModeLocalMoveNoDeleteReupload(MonitorModeTestCaseBase):
    XLSX_PAYLOAD_ROWS = 32
    case_id = "0060"
    name = "monitor mode local move without delete re-upload"
    description = (
        "Start --monitor, move in-sync local files and directories within the sync tree, "
        "and validate they are propagated as moves rather than delete/re-upload operations"
    )

    SYNC_COMPLETE_PATTERN = "Sync with Microsoft OneDrive is complete"

    def _build_monitor_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        # This testcase is specifically validating local inotify IN_MOVED_* handling.
        # The shared monitor config keeps WebSocket disabled and fullscan fallback off
        # so remote notification timing does not mask or race the local event path.
        return self._build_config_text(sync_dir, app_log_dir)

    def _build_verify_config_text(self, sync_dir: Path) -> str:
        return (
            "# tc0060 verify config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
        )

    def _read_text_file(self, path: Path) -> str:
        if not path.exists():
            return ""
        try:
            return path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def _wait_for_stdout_growth_patterns(
        self,
        stdout_file: Path,
        *,
        start_offset: int,
        required_patterns: list[str],
        timeout_seconds: int = 180,
        poll_interval: float = 0.5,
    ) -> tuple[bool, str]:
        deadline = time.time() + timeout_seconds
        latest_segment = ""

        while time.time() < deadline:
            content = self._read_stdout(stdout_file)
            latest_segment = content[start_offset:]
            if all(self._monitor_output_contains(latest_segment, pattern) for pattern in required_patterns):
                return True, latest_segment
            time.sleep(poll_interval)

        return False, latest_segment

    def _contains_bad_move_side_effects(self, log_segment: str) -> list[str]:
        bad_markers = [
            "Trying to delete this item as requested:",
            "The local item has been deleted:",
            "Uploading new file:",
            "Uploading changed file:",
        ]
        return [marker for marker in bad_markers if marker in log_segment]


    # ------------------------------------------------------------------
    # Rename-race coverage (Issue #3948 (history #3941))
    #
    # A directory that is created and renamed before the monitor processes its
    # IN_CREATE event must still end up with an inotify watch, and in-sync files
    # moved into it afterwards must be propagated as moves. To make both events
    # arrive in one batch deterministically, the monitor process is stopped with
    # SIGSTOP around a real mkdir + rename, then resumed. The kernel queues the
    # inotify events while the process is stopped; nothing synthetic is injected.
    # ------------------------------------------------------------------
    RENAME_RACE_WATCH_SETTLE_SECONDS = 5

    def _directory_has_inotify_watch(self, pid: int, directory: Path) -> tuple[bool, dict[str, object]]:
        """Return whether the client process holds an inotify watch on the directory's inode.

        Read from /proc/<pid>/fdinfo for every inotify file descriptor. Linux only;
        on other platforms the result is (False, {"supported": False}).
        """
        info: dict[str, object] = {"supported": False, "inotify_fds": 0, "watch_count": 0}
        fd_dir = Path(f"/proc/{pid}/fd")
        if not fd_dir.is_dir():
            return False, info
        info["supported"] = True
        try:
            inode = directory.stat().st_ino
        except OSError as exc:
            info["stat_error"] = str(exc)
            return False, info
        info["inode"] = inode
        found = False
        for fd_entry in fd_dir.iterdir():
            try:
                if os.readlink(fd_entry) != "anon_inode:inotify":
                    continue
            except OSError:
                continue
            info["inotify_fds"] = int(info["inotify_fds"]) + 1
            fdinfo = Path(f"/proc/{pid}/fdinfo/{fd_entry.name}")
            try:
                lines = fdinfo.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            for line in lines:
                if not line.startswith("inotify "):
                    continue
                info["watch_count"] = int(info["watch_count"]) + 1
                for token in line.split():
                    if token.startswith("ino:"):
                        try:
                            if int(token[4:], 16) == inode:
                                found = True
                        except ValueError:
                            pass
        return found, info

    def _create_and_rename_directory_while_monitor_stopped(
        self,
        process: subprocess.Popen[str],
        temporary_dir: Path,
        final_dir: Path,
    ) -> None:
        """Create temporary_dir and rename it to final_dir while the monitor is stopped.

        SIGSTOP guarantees the IN_CREATE for temporary_dir and the IN_MOVED_FROM/IN_MOVED_TO
        pair are read by the client in the same batch, after temporary_dir no longer exists.
        """
        process.send_signal(signal.SIGSTOP)
        try:
            temporary_dir.mkdir(parents=False, exist_ok=False)
            temporary_dir.rename(final_dir)
        finally:
            process.send_signal(signal.SIGCONT)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0060",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0060_{context.run_id}_{os.getpid()}"

        file_source_relative = f"{root_name}/FileSource/move-me.txt"
        file_destination_relative = f"{root_name}/FileDestination/move-me.txt"
        file_xlsx_source_relative = f"{root_name}/FileSource/move-me.xlsx"
        file_xlsx_destination_relative = f"{root_name}/FileDestination/move-me.xlsx"
        file_pdf_source_relative = f"{root_name}/FileSource/move-me.pdf"
        file_pdf_destination_relative = f"{root_name}/FileDestination/move-me.pdf"
        file_image_source_relative = f"{root_name}/FileSource/move-me.png"
        file_image_destination_relative = f"{root_name}/FileDestination/move-me.png"
        file_destination_anchor_relative = f"{root_name}/FileDestination/anchor.txt"

        dir_source_relative = f"{root_name}/Pictures/2005"
        dir_destination_relative = f"{root_name}/Pictures/Year/2005"
        dir_destination_parent_anchor_relative = f"{root_name}/Pictures/Year/anchor.txt"
        race_parent_relative = f"{root_name}/RenameRace"
        race_temporary_dir_relative = f"{race_parent_relative}/Untitled Folder"
        race_final_dir_relative = f"{race_parent_relative}/Renamed"
        race_file_names = ["race-001.txt", "race-002.txt", "race-003.txt"]
        race_file_source_relatives = [f"{race_parent_relative}/{name}" for name in race_file_names]
        race_file_destination_relatives = [f"{race_final_dir_relative}/{name}" for name in race_file_names]
        dir_file_relative_paths = [
            f"{dir_source_relative}/photo-root-001.txt",
            f"{dir_source_relative}/photo-root-002.txt",
            f"{dir_source_relative}/nested/photo-nested-001.txt",
            f"{dir_source_relative}/nested/deeper/photo-deeper-001.txt",
        ]

        file_source_path = sync_root / file_source_relative
        file_destination_path = sync_root / file_destination_relative
        file_xlsx_source_path = sync_root / file_xlsx_source_relative
        file_xlsx_destination_path = sync_root / file_xlsx_destination_relative
        file_pdf_source_path = sync_root / file_pdf_source_relative
        file_pdf_destination_path = sync_root / file_pdf_destination_relative
        file_image_source_path = sync_root / file_image_source_relative
        file_image_destination_path = sync_root / file_image_destination_relative
        file_destination_anchor_path = sync_root / file_destination_anchor_relative
        dir_source_path = sync_root / dir_source_relative
        dir_destination_path = sync_root / dir_destination_relative
        dir_destination_parent_anchor_path = sync_root / dir_destination_parent_anchor_relative
        race_temporary_dir_path = sync_root / race_temporary_dir_relative
        race_final_dir_path = sync_root / race_final_dir_relative

        file_destination_verify_path = verify_root / file_destination_relative
        file_source_verify_path = verify_root / file_source_relative
        file_xlsx_destination_verify_path = verify_root / file_xlsx_destination_relative
        file_xlsx_source_verify_path = verify_root / file_xlsx_source_relative
        file_pdf_destination_verify_path = verify_root / file_pdf_destination_relative
        file_pdf_source_verify_path = verify_root / file_pdf_source_relative
        file_image_destination_verify_path = verify_root / file_image_destination_relative
        file_image_source_verify_path = verify_root / file_image_source_relative
        dir_source_verify_path = verify_root / dir_source_relative
        dir_destination_verify_path = verify_root / dir_destination_relative

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0060:{os.getpid()}"
        pdf_seed = f"{xlsx_seed}:pdf"
        image_seed = f"{xlsx_seed}:image"
        file_content = (
            "TC0060 monitor local file move validation\n"
            "This file must be moved remotely, not deleted and re-uploaded.\n"
        )
        file_anchor_content = "TC0060 destination directory anchor for file move\n"
        dir_anchor_content = "TC0060 destination parent anchor for directory move\n"
        race_file_contents = {
            relative: f"TC0060 rename-race file {index + 1}\n"
            for index, relative in enumerate(race_file_source_relatives)
        }
        dir_file_contents = {
            dir_file_relative_paths[0]: "TC0060 root photo 001\n",
            dir_file_relative_paths[1]: "TC0060 root photo 002\n",
            dir_file_relative_paths[2]: "TC0060 nested photo 001\n",
            dir_file_relative_paths[3]: "TC0060 deeper nested photo 001\n",
        }

        context.prepare_minimal_config_dir(
            conf_main,
            self._build_monitor_config_text(sync_root, app_log_dir),
        )
        context.prepare_minimal_config_dir(
            conf_verify,
            self._build_verify_config_text(verify_root),
        )

        write_text_file(file_source_path, file_content)
        generated_xlsx = create_random_xlsx_pair(
            file_xlsx_source_path,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0060 no-delete-reupload move workbook",
        )
        generated_pdf = create_random_pdf_pair(
            file_pdf_source_path,
            pdf_seed,
            revision=PDF_REVISION_0,
            title="TC0060 no-delete-reupload move PDF",
        )
        generated_images = create_random_image_set(file_image_source_path, image_seed, revision=REVISION_0, title="TC0060 no-delete-reupload move images")
        write_text_file(file_destination_anchor_path, file_anchor_content)
        write_text_file(dir_destination_parent_anchor_path, dir_anchor_content)
        for relative_path, content in dir_file_contents.items():
            write_text_file(sync_root / relative_path, content)
        for relative_path, content in race_file_contents.items():
            write_text_file(sync_root / relative_path, content)

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        monitor_manifest_file = state_dir / "monitor_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(monitor_stdout),
            str(monitor_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(monitor_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
            str(app_log_dir),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "file_source_relative": file_source_relative,
            "file_destination_relative": file_destination_relative,
            "file_xlsx_source_relative": file_xlsx_source_relative,
            "file_xlsx_destination_relative": file_xlsx_destination_relative,
            "file_pdf_source_relative": file_pdf_source_relative,
            "file_pdf_destination_relative": file_pdf_destination_relative,
            "file_image_source_relative": file_image_source_relative,
            "file_image_destination_relative": file_image_destination_relative,
            "xlsx_seed": xlsx_seed,
            "pdf_seed": pdf_seed,
            "image_seed": image_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "generated_xlsx_size": int(generated_xlsx["size_bytes"]),
            "generated_pdf_small_size": int(generated_pdf["small_size_bytes"]),
            "generated_pdf_large_size": int(generated_pdf["large_size_bytes"]),
            "generated_image_sizes": {k: int(v) for k, v in generated_images.items() if k.endswith("_size_bytes")},
            "dir_source_relative": dir_source_relative,
            "dir_destination_relative": dir_destination_relative,
            "dir_file_relative_paths": dir_file_relative_paths,
            "race_temporary_dir_relative": race_temporary_dir_relative,
            "race_final_dir_relative": race_final_dir_relative,
            "race_file_source_relatives": race_file_source_relatives,
            "race_file_destination_relatives": race_file_destination_relatives,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
            "websocket_disabled": True,
        }

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")

        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
            startup_timeout_seconds=300,
        )

        mutation_processed = False
        post_mutation_log_segment = ""
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor process did not complete initial sync before local moves",
                    artifacts,
                    details,
                )

            settled_xlsx_validation_error = (
                validate_xlsx_pair(file_xlsx_source_path, REVISION_0)
                if file_xlsx_source_path.is_file()
                else "Seeded XLSX is missing after monitor initial sync"
            )
            details["settled_xlsx_validation_error"] = settled_xlsx_validation_error
            if settled_xlsx_validation_error:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"seeded XLSX was invalid before local move: {settled_xlsx_validation_error}",
                    artifacts,
                    details,
                )
            settled_pdf_validation_error = (
                validate_pdf_pair(file_pdf_source_path, PDF_REVISION_0)
                if file_pdf_source_path.is_file()
                else "Seeded PDF is missing after monitor initial sync"
            )
            settled_image_validation_error = validate_image_set(file_image_source_path, REVISION_0)
            details["settled_pdf_validation_error"] = settled_pdf_validation_error
            details["settled_image_validation_error"] = settled_image_validation_error
            if settled_image_validation_error:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, f"seeded image set was invalid before local move: {settled_image_validation_error}", artifacts, details)
            if settled_pdf_validation_error:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"seeded PDF was invalid before local move: {settled_pdf_validation_error}",
                    artifacts,
                    details,
                )

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)
            details["initial_sync_complete_count_before_moves"] = details.get("initial_sync_complete_count_before_mutation", 0)

            context.log(f"Test Case {self.case_id}: moving in-sync local file: {file_source_relative} -> {file_destination_relative}")
            file_destination_path.parent.mkdir(parents=True, exist_ok=True)
            file_source_path.rename(file_destination_path)
            context.log(f"Test Case {self.case_id}: moving in-sync local XLSX: {file_xlsx_source_relative} -> {file_xlsx_destination_relative}")
            rename_xlsx_pair(file_xlsx_source_path, file_xlsx_destination_path)
            context.log(f"Test Case {self.case_id}: moving in-sync local PDF: {file_pdf_source_relative} -> {file_pdf_destination_relative}")
            rename_pdf_pair(file_pdf_source_path, file_pdf_destination_path)
            context.log(f"Test Case {self.case_id}: moving in-sync local image set: {file_image_source_relative} -> {file_image_destination_relative}")
            rename_image_set(file_image_source_path, file_image_destination_path)

            context.log(f"Test Case {self.case_id}: moving in-sync local directory tree: {dir_source_relative} -> {dir_destination_relative}")
            dir_destination_path.parent.mkdir(parents=True, exist_ok=True)
            dir_source_path.rename(dir_destination_path)

            details["file_source_exists_after_local_move"] = file_source_path.exists()
            details["file_destination_exists_after_local_move"] = file_destination_path.is_file()
            details["file_xlsx_source_exists_after_local_move"] = xlsx_pair_any_exists(file_xlsx_source_path)
            details["file_xlsx_destination_exists_after_local_move"] = xlsx_pair_all_files(file_xlsx_destination_path)
            details["file_xlsx_destination_validation_error"] = (
                validate_xlsx_pair(file_xlsx_destination_path, REVISION_0)
                if xlsx_pair_all_files(file_xlsx_destination_path)
                else "Moved local XLSX is missing"
            )
            details["file_pdf_source_exists_after_local_move"] = pdf_pair_any_exists(file_pdf_source_path)
            details["file_pdf_destination_exists_after_local_move"] = pdf_pair_all_files(file_pdf_destination_path)
            details["file_pdf_destination_validation_error"] = (
                validate_pdf_pair(file_pdf_destination_path, PDF_REVISION_0)
                if pdf_pair_all_files(file_pdf_destination_path)
                else "Moved local PDF is missing"
            )
            details["file_image_source_exists_after_local_move"] = image_set_any_exists(file_image_source_path)
            details["file_image_destination_exists_after_local_move"] = image_set_all_files(file_image_destination_path)
            details["file_image_destination_validation_error"] = (
                validate_image_set(file_image_destination_path, REVISION_0)
                if image_set_all_files(file_image_destination_path)
                else "Moved local image set is missing"
            )
            if details["file_xlsx_destination_validation_error"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Local XLSX move did not preserve a valid workbook before monitor processing",
                    artifacts,
                    details,
                )
            if details["file_image_destination_validation_error"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Local image move did not preserve valid image content before monitor processing", artifacts, details)
            if details["file_pdf_destination_validation_error"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Local PDF move did not preserve a valid document before monitor processing",
                    artifacts,
                    details,
                )
            details["dir_source_exists_after_local_move"] = dir_source_path.exists()
            details["dir_destination_exists_after_local_move"] = dir_destination_path.is_dir()

            image_source_relatives = image_set_relatives(file_image_source_relative)
            image_destination_relatives = image_set_relatives(file_image_destination_relative)
            required_patterns = [
                f"[M] Local item moved: ./{file_source_relative} -> ./{file_destination_relative}",
                f"Moving ./{file_source_relative} to ./{file_destination_relative}",
                f"[M] Local item moved: ./{file_xlsx_source_relative} -> ./{file_xlsx_destination_relative}",
                f"Moving ./{file_xlsx_source_relative} to ./{file_xlsx_destination_relative}",
                f"[M] Local item moved: ./{large_xlsx_relative(file_xlsx_source_relative)} -> ./{large_xlsx_relative(file_xlsx_destination_relative)}",
                f"Moving ./{large_xlsx_relative(file_xlsx_source_relative)} to ./{large_xlsx_relative(file_xlsx_destination_relative)}",
                f"[M] Local item moved: ./{file_pdf_source_relative} -> ./{file_pdf_destination_relative}",
                f"Moving ./{file_pdf_source_relative} to ./{file_pdf_destination_relative}",
                f"[M] Local item moved: ./{large_pdf_relative(file_pdf_source_relative)} -> ./{large_pdf_relative(file_pdf_destination_relative)}",
                f"Moving ./{large_pdf_relative(file_pdf_source_relative)} to ./{large_pdf_relative(file_pdf_destination_relative)}",
                *[value for label in image_source_relatives for value in (
                    f"[M] Local item moved: ./{image_source_relatives[label]} -> ./{image_destination_relatives[label]}",
                    f"Moving ./{image_source_relatives[label]} to ./{image_destination_relatives[label]}",
                )],
                f"[M] Local item moved: ./{dir_source_relative} -> ./{dir_destination_relative}",
                f"Moving ./{dir_source_relative} to ./{dir_destination_relative}",
            ]
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=required_patterns,
                timeout_seconds=180,
            )
            details["mutation_processed"] = mutation_processed
            details["mutation_required_patterns"] = required_patterns
            details["post_mutation_bad_markers"] = self._contains_bad_move_side_effects(post_mutation_log_segment)
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)

            # ---- Rename-race phase (Issue #3948 (history #3941)) ----
            race_processed = False
            race_moves_processed = False
            race_log_segment = ""
            if mutation_processed and not details["post_mutation_bad_markers"]:
                race_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)
                context.log(
                    f"Test Case {self.case_id}: creating and renaming directory while the monitor is stopped: "
                    f"{race_temporary_dir_relative} -> {race_final_dir_relative}"
                )
                self._create_and_rename_directory_while_monitor_stopped(process, race_temporary_dir_path, race_final_dir_path)
                race_required_patterns = [
                    # Proves the race was exercised: IN_CREATE was processed after the rename.
                    f"Not adding non-existing/disappeared directory: ./{race_temporary_dir_relative}",
                    f"[M] Local item moved: ./{race_temporary_dir_relative} -> ./{race_final_dir_relative}",
                    f"Successfully created the remote directory ./{race_final_dir_relative} on Microsoft OneDrive",
                ]
                race_processed, race_log_segment = self._wait_for_stdout_growth_patterns(
                    monitor_stdout,
                    start_offset=race_log_start_offset,
                    required_patterns=race_required_patterns,
                    timeout_seconds=180,
                )
                details["race_processed"] = race_processed
                details["race_required_patterns"] = race_required_patterns
                if race_processed:
                    time.sleep(self.RENAME_RACE_WATCH_SETTLE_SECONDS)
                    race_watched, race_watch_info = self._directory_has_inotify_watch(process.pid, race_final_dir_path)
                    details["race_final_dir_watched"] = race_watched
                    details["race_watch_info"] = race_watch_info
                    if race_watched or not race_watch_info.get("supported", False):
                        race_moves_start_offset = len(self._read_stdout(monitor_stdout))
                        context.log(f"Test Case {self.case_id}: moving in-sync files into the renamed directory: {race_file_source_relatives}")
                        for source_relative, destination_relative in zip(race_file_source_relatives, race_file_destination_relatives):
                            (sync_root / source_relative).rename(sync_root / destination_relative)
                        race_move_patterns = [
                            value
                            for source_relative, destination_relative in zip(race_file_source_relatives, race_file_destination_relatives)
                            for value in (
                                f"[M] Local item moved: ./{source_relative} -> ./{destination_relative}",
                                f"Moving ./{source_relative} to ./{destination_relative}",
                            )
                        ]
                        race_moves_processed, race_moves_segment = self._wait_for_stdout_growth_patterns(
                            monitor_stdout,
                            start_offset=race_moves_start_offset,
                            required_patterns=race_move_patterns,
                            timeout_seconds=180,
                        )
                        details["race_moves_processed"] = race_moves_processed
                        details["race_move_patterns"] = race_move_patterns
                        details["race_bad_markers"] = self._contains_bad_move_side_effects(race_moves_segment)
        finally:
            self._shutdown_monitor_process(process, details)

        monitor_manifest = build_manifest(sync_root)
        write_manifest(monitor_manifest_file, monitor_manifest)

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
            "--syncdir",
            str(verify_root),
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

        expected_destination_dir_files = [
            relative_path.replace(dir_source_relative, dir_destination_relative, 1)
            for relative_path in dir_file_relative_paths
        ]
        details["expected_destination_dir_files"] = expected_destination_dir_files
        details["verify_file_source_exists"] = file_source_verify_path.exists()
        details["verify_file_destination_exists"] = file_destination_verify_path.is_file()
        details["verify_file_xlsx_source_exists"] = xlsx_pair_any_exists(file_xlsx_source_verify_path)
        details["verify_file_xlsx_destination_exists"] = xlsx_pair_all_files(file_xlsx_destination_verify_path)
        details["verify_file_xlsx_destination_validation_error"] = (
            validate_xlsx_pair(file_xlsx_destination_verify_path, REVISION_0)
            if file_xlsx_destination_verify_path.is_file()
            else "Verification XLSX is missing"
        )
        details["verify_file_pdf_source_exists"] = pdf_pair_any_exists(file_pdf_source_verify_path)
        details["verify_file_pdf_destination_exists"] = pdf_pair_all_files(file_pdf_destination_verify_path)
        details["verify_file_pdf_destination_validation_error"] = (
            validate_pdf_pair(file_pdf_destination_verify_path, PDF_REVISION_0)
            if file_pdf_destination_verify_path.is_file()
            else "Verification PDF is missing"
        )
        details["verify_file_image_source_exists"] = image_set_any_exists(file_image_source_verify_path)
        details["verify_file_image_destination_exists"] = image_set_all_files(file_image_destination_verify_path)
        details["verify_file_image_destination_validation_error"] = (
            validate_image_set(file_image_destination_verify_path, REVISION_0)
            if image_set_all_files(file_image_destination_verify_path)
            else "Verification image set is missing"
        )
        details["verify_file_destination_content"] = (
            file_destination_verify_path.read_text(encoding="utf-8")
            if file_destination_verify_path.is_file()
            else ""
        )
        details["verify_dir_source_exists"] = dir_source_verify_path.exists()
        details["verify_dir_destination_exists"] = dir_destination_verify_path.is_dir()
        details["verify_destination_dir_files_exist"] = {
            relative_path: (verify_root / relative_path).is_file()
            for relative_path in expected_destination_dir_files
        }
        details["verify_destination_dir_file_contents"] = {
            relative_path: (
                (verify_root / relative_path).read_text(encoding="utf-8")
                if (verify_root / relative_path).is_file()
                else ""
            )
            for relative_path in expected_destination_dir_files
        }

        self._write_metadata(metadata_file, details)

        if not mutation_processed:
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor process did not log both local move operations before shutdown",
                artifacts,
                details,
            )

        bad_markers = details.get("post_mutation_bad_markers", [])
        if bad_markers:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Monitor move processing logged delete/re-upload side effects after local moves: {bad_markers}",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if file_source_verify_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains original file move source: {file_source_relative}",
                artifacts,
                details,
            )

        if xlsx_pair_any_exists(file_xlsx_source_verify_path):
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains original XLSX move source: {file_xlsx_source_relative}",
                artifacts,
                details,
            )
        if image_set_any_exists(file_image_source_verify_path):
            return self.fail_result(self.case_id, self.name, f"Remote verification still contains original image move source: {file_image_source_relative}", artifacts, details)
        if pdf_pair_any_exists(file_pdf_source_verify_path):
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains original PDF move source: {file_pdf_source_relative}",
                artifacts,
                details,
            )

        if not file_destination_verify_path.is_file() or details["verify_file_destination_content"] != file_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote verification did not preserve moved file at the destination path with expected content",
                artifacts,
                details,
            )

        if details["verify_file_xlsx_destination_validation_error"]:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote verification did not preserve the moved XLSX at the destination path with the expected revision",
                artifacts,
                details,
            )
        if details["verify_file_image_destination_validation_error"]:
            return self.fail_result(self.case_id, self.name, "Remote verification did not preserve the moved image set at the destination path with the expected revision", artifacts, details)
        if details["verify_file_pdf_destination_validation_error"]:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote verification did not preserve the moved PDF at the destination path with the expected revision",
                artifacts,
                details,
            )

        if dir_source_verify_path.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains original directory move source: {dir_source_relative}",
                artifacts,
                details,
            )

        if not dir_destination_verify_path.is_dir():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing moved directory destination: {dir_destination_relative}",
                artifacts,
                details,
            )

        missing_dir_files = [
            relative_path
            for relative_path, exists in details["verify_destination_dir_files_exist"].items()
            if not exists
        ]
        if missing_dir_files:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing moved directory descendant files: {missing_dir_files}",
                artifacts,
                details,
            )

        content_mismatches = []
        for source_relative, expected_content in dir_file_contents.items():
            destination_relative = source_relative.replace(dir_source_relative, dir_destination_relative, 1)
            actual_content = details["verify_destination_dir_file_contents"].get(destination_relative, "")
            if actual_content != expected_content:
                content_mismatches.append(destination_relative)
        if content_mismatches:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification found moved directory descendant content mismatches: {content_mismatches}",
                artifacts,
                details,
            )

        if not details.get("race_processed", False):
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor did not process the created-then-renamed directory as a rename with the IN_CREATE race exercised",
                artifacts,
                details,
            )

        race_watch_info = details.get("race_watch_info", {})
        if isinstance(race_watch_info, dict) and race_watch_info.get("supported", False) and not details.get("race_final_dir_watched", False):
            return self.fail_result(
                self.case_id,
                self.name,
                f"Renamed directory has no inotify watch after the create/rename race was processed: {race_final_dir_relative}",
                artifacts,
                details,
            )

        if not details.get("race_moves_processed", False):
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor did not log the file moves into the renamed directory as moves",
                artifacts,
                details,
            )

        race_bad_markers = details.get("race_bad_markers", [])
        if race_bad_markers:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Moves into the renamed directory logged delete/re-upload side effects: {race_bad_markers}",
                artifacts,
                details,
            )

        race_source_leftovers = [relative for relative in race_file_source_relatives if (verify_root / relative).exists()]
        if race_source_leftovers:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains rename-race move sources: {race_source_leftovers}",
                artifacts,
                details,
            )
        race_destination_mismatches = [
            destination_relative
            for source_relative, destination_relative in zip(race_file_source_relatives, race_file_destination_relatives)
            if not (verify_root / destination_relative).is_file()
            or (verify_root / destination_relative).read_text(encoding="utf-8") != race_file_contents[source_relative]
        ]
        if race_destination_mismatches:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing or has wrong content for rename-race destinations: {race_destination_mismatches}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
