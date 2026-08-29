from __future__ import annotations

import os
import socket
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.utils import (
    CommandResult,
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_text_file,
)


class SafeBackupCaseBase(E2ETestCase):
    """Shared helpers for safeBackup transaction regression cases."""

    def _prepare_config(
        self,
        context: E2EContext,
        config_dir: Path,
        sync_root: Path,
        *,
        extra_lines: list[str] | None = None,
    ) -> None:
        lines = [
            f"# tc{self.case_id} config",
            f'sync_dir = "{sync_root}"',
        ]
        if extra_lines:
            lines.extend(extra_lines)
        context.prepare_minimal_config_dir(config_dir, "\n".join(lines) + "\n")

    def _run_phase(
        self,
        context: E2EContext,
        *,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
    ) -> CommandResult:
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def _single_directory_command(
        self,
        context: E2EContext,
        *,
        root_name: str,
        config_dir: Path,
        mode: str = "sync",
        resync: bool = False,
        verbose_count: int = 1,
    ) -> list[str]:
        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
        ]
        if mode == "upload-only":
            command.append("--upload-only")
        elif mode == "download-only":
            command.append("--download-only")
        elif mode != "sync":
            raise ValueError(f"Unsupported mode: {mode}")

        command.extend(["--verbose"] * max(1, verbose_count))
        if resync:
            command.extend(["--resync", "--resync-auth"])
        command.extend([
            "--single-directory",
            root_name,
            "--confdir",
            str(config_dir),
        ])
        return command

    def _safe_backup_files_for(self, canonical_path: Path) -> list[Path]:
        stem = canonical_path.stem
        suffix = canonical_path.suffix
        return sorted(
            path
            for path in canonical_path.parent.glob(f"{stem}-*-safeBackup-????{suffix}")
            if path.is_file()
        )

    def _partial_files_under(self, root: Path) -> list[Path]:
        if not root.exists():
            return []
        return sorted(path for path in root.rglob("*.partial") if path.is_file())

    def _hash_if_file(self, path: Path) -> str:
        return compute_quickxor_hash_file(path) if path.is_file() else ""

    def _text_if_file(self, path: Path) -> str:
        return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _device_safe_backup_name(self, canonical_path: Path, counter: int) -> Path:
        if counter < 1 or counter > 9999:
            raise ValueError("safeBackup counter must be between 1 and 9999")
        hostname = socket.gethostname()
        return canonical_path.with_name(
            f"{canonical_path.stem}-{hostname}-safeBackup-{counter:04d}{canonical_path.suffix}"
        )

    def _create_exact_size_file(self, path: Path, size_bytes: int, fill_byte: bytes) -> None:
        if len(fill_byte) != 1:
            raise ValueError("fill_byte must contain exactly one byte")
        path.parent.mkdir(parents=True, exist_ok=True)
        chunk = fill_byte * (1024 * 1024)
        with path.open("wb") as handle:
            remaining = size_bytes
            while remaining > 0:
                block = chunk[: min(len(chunk), remaining)]
                handle.write(block)
                remaining -= len(block)
