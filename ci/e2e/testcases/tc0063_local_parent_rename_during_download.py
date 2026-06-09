from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0063LocalParentRenameDuringDownload(E2ETestCase):
    case_id = "0063"
    name = "local parent rename during active download"
    description = (
        "Run a normal local_first sync, trigger a required download, then rename the "
        "downloaded file's local parent directory while the download/finalisation path is active"
    )

    TARGET_RELATIVE = "Documents/divers/jeux intéressants.odt"
    NOTES_RELATIVE = "Documents/divers/Notes/dummy.txt"

    def _write_config(self, config_path: Path, sync_dir: Path, *, local_first: bool = False) -> None:
        content = (
            "# tc0063 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            # Keep remote notification timing from masking the deterministic normal sync path.
            'disable_websocket_support = "true"\n'
        )
        if local_first:
            content += 'local_first = "true"\n'
        write_onedrive_config(config_path, content)

    def _write_large_file(self, path: Path, *, size_mb: int, fill_byte: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        block = fill_byte * (1024 * 1024)
        with path.open("wb") as handle:
            for _ in range(size_mb):
                handle.write(block)

    def _read_text(self, path: Path) -> str:
        if not path.exists():
            return ""
        return path.read_text(encoding="utf-8", errors="replace")

    def _reader_thread(self, stream, output_file: Path, buffer: list[str], stop_event: threading.Event) -> None:
        output_file.parent.mkdir(parents=True, exist_ok=True)
        with output_file.open("w", encoding="utf-8", errors="replace") as handle:
            while not stop_event.is_set():
                chunk = stream.read(1)
                if not chunk:
                    break
                buffer.append(chunk)
                handle.write(chunk)
                handle.flush()

    def _run_sync_with_parent_rename(self, *, context: E2EContext, command: list[str], sync_root: Path, root_name: str,
                                     stdout_file: Path, stderr_file: Path, mutation_log_file: Path,
                                     timeout_seconds: int = 420) -> tuple[int, bool, str, str, dict[str, object]]:
        old_parent = sync_root / root_name / "Documents" / "divers"
        new_parent = sync_root / root_name / "Documents" / "divers-renamed-during-download"
        target_path = sync_root / root_name / self.TARGET_RELATIVE
        initial_size = target_path.stat().st_size if target_path.exists() else -1
        initial_mtime = target_path.stat().st_mtime if target_path.exists() else 0.0

        stdout_buffer: list[str] = []
        stderr_buffer: list[str] = []
        stop_event = threading.Event()
        mutation_done = threading.Event()
        mutation_details: dict[str, object] = {
            "initial_target_size": initial_size,
            "initial_target_mtime": initial_mtime,
            "old_parent": str(old_parent),
            "new_parent": str(new_parent),
            "target_path": str(target_path),
            "trigger": "",
            "rename_error": "",
        }

        def combined_output() -> str:
            return "".join(stdout_buffer) + "\n" + "".join(stderr_buffer)

        def log_mutation(line: str) -> None:
            with mutation_log_file.open("a", encoding="utf-8", errors="replace") as handle:
                handle.write(line.rstrip("\n") + "\n")

        def try_rename(trigger: str) -> None:
            if mutation_done.is_set():
                return
            try:
                mutation_details["trigger"] = trigger
                if new_parent.exists():
                    shutil.rmtree(new_parent)
                if old_parent.exists():
                    old_parent.rename(new_parent)
                    mutation_details["rename_success"] = True
                    log_mutation(f"RENAMED trigger={trigger} old={old_parent} new={new_parent}")
                else:
                    mutation_details["rename_success"] = False
                    mutation_details["rename_error"] = f"old parent did not exist: {old_parent}"
                    log_mutation(f"NOT_RENAMED trigger={trigger} reason=old_parent_missing old={old_parent}")
            except Exception as exc:  # noqa: BLE001 - preserve the exact failure in artifacts
                mutation_details["rename_success"] = False
                mutation_details["rename_error"] = repr(exc)
                log_mutation(f"RENAME_EXCEPTION trigger={trigger} error={exc!r}")
            finally:
                mutation_done.set()

        def mutator() -> None:
            # Wait for clear evidence that the final sync has entered the download phase.
            # The target file is intentionally large and the command is run through stdbuf,
            # so either stdout or on-disk size/mtime should provide a deterministic trigger.
            deadline = time.time() + timeout_seconds
            saw_download_count = False
            while time.time() < deadline and not mutation_done.is_set():
                output = combined_output()
                if f"Downloading file: {root_name}/{self.TARGET_RELATIVE}" in output:
                    time.sleep(0.10)
                    try_rename("stdout-target-download-line")
                    return
                if "Number of items to download from Microsoft OneDrive:" in output:
                    saw_download_count = True
                if saw_download_count and target_path.exists():
                    try:
                        stat = target_path.stat()
                        if stat.st_size != initial_size or stat.st_mtime != initial_mtime:
                            try_rename("target-size-or-mtime-changed-after-download-count")
                            return
                    except FileNotFoundError:
                        # If the target vanished after the download count appeared, the race has already started.
                        try_rename("target-vanished-after-download-count")
                        return
                # Last-resort deterministic trigger: after the client announces pending downloads,
                # wait briefly and rename the parent while the large target download should be active.
                if saw_download_count:
                    time.sleep(0.75)
                    try_rename("timed-after-download-count")
                    return
                time.sleep(0.05)

            log_mutation("MUTATOR_TIMEOUT no download trigger observed")
            mutation_details["rename_success"] = False
            mutation_details["rename_error"] = "no download trigger observed"
            mutation_done.set()

        # stdbuf improves the chance that progress output is visible while the download is active.
        effective_command = command
        if shutil.which("stdbuf"):
            effective_command = ["stdbuf", "-oL", "-eL", *command]

        context.log(f"Executing Test Case {self.case_id} final sync with concurrent parent rename: {command_to_string(effective_command)}")
        process = subprocess.Popen(
            effective_command,
            cwd=str(context.repo_root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=0,
        )
        assert process.stdout is not None
        assert process.stderr is not None

        stdout_thread = threading.Thread(target=self._reader_thread, args=(process.stdout, stdout_file, stdout_buffer, stop_event), daemon=True)
        stderr_thread = threading.Thread(target=self._reader_thread, args=(process.stderr, stderr_file, stderr_buffer, stop_event), daemon=True)
        mutate_thread = threading.Thread(target=mutator, daemon=True)
        stdout_thread.start()
        stderr_thread.start()
        mutate_thread.start()

        try:
            returncode = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                returncode = process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                returncode = process.wait(timeout=20)
            mutation_details["process_timeout"] = True
        finally:
            stop_event.set()
            stdout_thread.join(timeout=10)
            stderr_thread.join(timeout=10)
            mutate_thread.join(timeout=10)

        return returncode, bool(mutation_details.get("rename_success", False)), "".join(stdout_buffer), "".join(stderr_buffer), mutation_details

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0063", ensure_refresh_token=True)
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        seed_root = case_work_dir / "seedroot"
        local_root = case_work_dir / "localroot"
        remote_update_root = case_work_dir / "remoteupdateroot"
        conf_seed = case_work_dir / "conf-seed"
        conf_local = case_work_dir / "conf-local"
        conf_remote = case_work_dir / "conf-remote"

        root_name = f"ZZ_E2E_TC0063_{context.run_id}_{os.getpid()}"
        target_relative = f"{root_name}/{self.TARGET_RELATIVE}"
        notes_relative = f"{root_name}/{self.NOTES_RELATIVE}"

        reset_directory(seed_root)
        reset_directory(local_root)
        reset_directory(remote_update_root)

        self._write_large_file(seed_root / target_relative, size_mb=48, fill_byte=b"A")
        write_text_file(seed_root / notes_relative, "TC0063 baseline Notes content\n")
        self._write_large_file(remote_update_root / target_relative, size_mb=80, fill_byte=b"B")
        write_text_file(remote_update_root / notes_relative, "TC0063 baseline Notes content\n")

        context.bootstrap_config_dir(conf_seed)
        self._write_config(conf_seed / "config", seed_root)
        context.bootstrap_config_dir(conf_local)
        self._write_config(conf_local / "config", local_root)
        context.bootstrap_config_dir(conf_remote)
        self._write_config(conf_remote / "config", remote_update_root)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        initial_download_stdout = case_log_dir / "initial_download_stdout.log"
        initial_download_stderr = case_log_dir / "initial_download_stderr.log"
        remote_update_stdout = case_log_dir / "remote_update_stdout.log"
        remote_update_stderr = case_log_dir / "remote_update_stderr.log"
        final_stdout = case_log_dir / "final_local_first_sync_stdout.log"
        final_stderr = case_log_dir / "final_local_first_sync_stderr.log"
        mutation_log = case_log_dir / "parent_rename_mutation.log"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(initial_download_stdout),
            str(initial_download_stderr),
            str(remote_update_stdout),
            str(remote_update_stderr),
            str(final_stdout),
            str(final_stderr),
            str(mutation_log),
            str(metadata_file),
        ]

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seed),
        ]
        context.log(f"Executing Test Case {self.case_id} seed upload: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        if seed_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Seed upload failed with status {seed_result.returncode}", artifacts, {"seed_returncode": seed_result.returncode})

        initial_download_command = [
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
            str(conf_local),
        ]
        context.log(f"Executing Test Case {self.case_id} initial download: {command_to_string(initial_download_command)}")
        initial_download_result = run_command(initial_download_command, cwd=context.repo_root)
        write_text_file(initial_download_stdout, initial_download_result.stdout)
        write_text_file(initial_download_stderr, initial_download_result.stderr)
        if initial_download_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Initial download failed with status {initial_download_result.returncode}", artifacts, {"initial_download_returncode": initial_download_result.returncode})

        # Remote-side content change: the local DB remains from the initial download, and the
        # reproduction sync below is a normal local_first sync, matching the reported user config.
        remote_update_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_remote),
        ]
        context.log(f"Executing Test Case {self.case_id} remote sibling update: {command_to_string(remote_update_command)}")
        remote_update_result = run_command(remote_update_command, cwd=context.repo_root)
        write_text_file(remote_update_stdout, remote_update_result.stdout)
        write_text_file(remote_update_stderr, remote_update_result.stderr)
        if remote_update_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote update failed with status {remote_update_result.returncode}", artifacts, {"remote_update_returncode": remote_update_result.returncode})

        # The actual reproduction phase must be local_first and must be a normal sync.
        self._write_config(conf_local / "config", local_root, local_first=True)

        final_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        final_returncode, mutation_done, final_stdout_text, final_stderr_text, mutation_details = self._run_sync_with_parent_rename(
            context=context,
            command=final_command,
            sync_root=local_root,
            root_name=root_name,
            stdout_file=final_stdout,
            stderr_file=final_stderr,
            mutation_log_file=mutation_log,
        )

        combined_final_output = final_stdout_text + "\n" + final_stderr_text
        filesystem_error_seen = "The local file system returned an error" in combined_final_output
        status_zero_seen = "HTTP request returned status code 0" in combined_final_output
        api_error_seen = "Microsoft OneDrive API returned an error" in combined_final_output
        wrapped_filesystem_error_seen = "There was a file system error during OneDrive request" in combined_final_output
        target_download_seen = f"Downloading file: {root_name}/{self.TARGET_RELATIVE}" in combined_final_output
        target_download_seen_without_root = f"Downloading file: {self.TARGET_RELATIVE}" in combined_final_output

        details: dict[str, object] = {
            "root_name": root_name,
            "target_relative": target_relative,
            "notes_relative": notes_relative,
            "seed_returncode": seed_result.returncode,
            "initial_download_returncode": initial_download_result.returncode,
            "remote_update_returncode": remote_update_result.returncode,
            "final_returncode": final_returncode,
            "local_first_reproduction_phase": True,
            "final_command": command_to_string(final_command),
            "mutation_done": mutation_done,
            "mutation_details": mutation_details,
            "filesystem_error_seen": filesystem_error_seen,
            "status_zero_seen": status_zero_seen,
            "api_error_seen": api_error_seen,
            "wrapped_filesystem_error_seen": wrapped_filesystem_error_seen,
            "target_download_seen": target_download_seen,
            "target_download_seen_without_root": target_download_seen_without_root,
            "bad_api_status_zero_classification": bool(status_zero_seen or (api_error_seen and wrapped_filesystem_error_seen)),
        }
        self._write_metadata(metadata_file, details)

        if not mutation_done:
            return self.fail_result(
                self.case_id,
                self.name,
                "tc0063 did not rename the local parent path during the local_first sync download phase",
                artifacts,
                details,
            )

        if details["bad_api_status_zero_classification"]:
            return self.fail_result(
                self.case_id,
                self.name,
                "Local filesystem race was misreported as a Microsoft OneDrive API / HTTP status 0 error",
                artifacts,
                details,
            )

        # A local filesystem error may be an acceptable outcome for this deliberately hostile
        # test; the critical validation is that it is not reclassified as an API/HTTP failure.
        return self.pass_result(self.case_id, self.name, artifacts, details)
