from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
from typing import Iterable

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.utils import (
    command_to_string,
    reset_directory,
    run_command,
    write_text_file,
)

CONFIG_FILE_NAME = "config"


class Wave1TestCaseBase(E2ETestCase):
    """
    Shared helper base for Wave 1 E2E test cases.

    Important design rule: Wave 1 test cases must not use sync_list.
    TC0002 is the sole owner of sync_list validation.
    """

    def _safe_run_id(self, context: E2EContext) -> str:
        value = re.sub(r"[^A-Za-z0-9]+", "_", context.run_id).strip("_").lower()
        return value or "run"

    def _root_name(self, context: E2EContext) -> str:
        return f"ZZ_E2E_TC{self.case_id}_{self._safe_run_id(context)}"

    def _initialise_case_dirs(self, context: E2EContext) -> tuple[Path, Path, Path]:
        case_work_dir = context.work_root / f"tc{self.case_id}"
        case_log_dir = context.logs_dir / f"tc{self.case_id}"
        case_state_dir = context.state_dir / f"tc{self.case_id}"
        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(case_state_dir)
        return case_work_dir, case_log_dir, case_state_dir

    def _new_config_dir(self, context: E2EContext, case_work_dir: Path, name: str) -> Path:
        config_dir = case_work_dir / f"conf-{name}"
        reset_directory(config_dir)
        context.bootstrap_config_dir(config_dir)
        return config_dir

    def _write_config(
        self,
        config_dir: Path,
        *,
        extra_lines: Iterable[str] | None = None,
    ) -> Path:
        config_path = config_dir / CONFIG_FILE_NAME

        lines = [
            f"# tc{self.case_id} generated config",
            'bypass_data_preservation = "true"',
            'monitor_interval = 5',
        ]
        if extra_lines:
            lines.extend(list(extra_lines))
        write_text_file(config_path, "\n".join(lines) + "\n")

        return config_path

    def _run_onedrive(
        self,
        context: E2EContext,
        *,
        sync_root: Path,
        config_dir: Path,
        extra_args: list[str] | None = None,
        use_resync: bool = True,
        use_resync_auth: bool = True,
        input_text: str | None = None,
    ):
        command = [context.onedrive_bin, "--sync", "--verbose"]
        if use_resync:
            command.append("--resync")
        if use_resync_auth:
            command.append("--resync-auth")
        command.extend(["--syncdir", str(sync_root), "--confdir", str(config_dir)])
        if extra_args:
            command.extend(extra_args)

        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        return run_command(command, cwd=context.repo_root, input_text=input_text)

    def _write_command_artifacts(
        self,
        *,
        result,
        log_dir: Path,
        state_dir: Path,
        phase_name: str,
        extra_metadata: dict[str, str | int | bool] | None = None,
    ) -> list[str]:
        stdout_file = log_dir / f"{phase_name}_stdout.log"
        stderr_file = log_dir / f"{phase_name}_stderr.log"
        metadata_file = state_dir / f"{phase_name}_metadata.txt"

        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        metadata = {
            "phase": phase_name,
            "command": command_to_string(result.command),
            "returncode": result.returncode,
        }
        if extra_metadata:
            metadata.update(extra_metadata)

        lines = [f"{key}={value}" for key, value in metadata.items()]
        write_text_file(metadata_file, "\n".join(lines) + "\n")

        return [str(stdout_file), str(stderr_file), str(metadata_file)]

    def _write_manifests(self, root: Path, state_dir: Path, prefix: str) -> list[str]:
        manifest_file = state_dir / f"{prefix}_manifest.txt"
        write_manifest(manifest_file, build_manifest(root))
        return [str(manifest_file)]

    def _write_json_artifact(self, path: Path, payload: object) -> str:
        write_text_file(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")
        return str(path)

    def _create_text_file(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def _create_binary_file(self, path: Path, size_bytes: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        chunk = os.urandom(min(size_bytes, 1024 * 1024))
        with path.open("wb") as fp:
            remaining = size_bytes
            while remaining > 0:
                to_write = chunk[: min(len(chunk), remaining)]
                fp.write(to_write)
                remaining -= len(to_write)

    def _snapshot_files(self, root: Path) -> dict[str, str]:
        result: dict[str, str] = {}
        if not root.exists():
            return result

        for path in sorted(root.rglob("*")):
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                result[rel] = f"symlink->{os.readlink(path)}"
                continue
            if path.is_dir():
                result[rel] = "dir"
                continue
            hasher = hashlib.sha256()
            with path.open("rb") as fp:
                while True:
                    chunk = fp.read(8192)
                    if not chunk:
                        break
                    hasher.update(chunk)
            result[rel] = hasher.hexdigest()
        return result

    def _download_remote_scope(
        self,
        context: E2EContext,
        case_work_dir: Path,
        scope_root: str,
        name: str,
        *,
        extra_config_lines: Iterable[str] | None = None,
        extra_args: list[str] | None = None,
    ) -> tuple[Path, object, list[str]]:
        verify_root = case_work_dir / f"verify-{name}"
        reset_directory(verify_root)
        config_dir = self._new_config_dir(context, case_work_dir, f"verify-{name}")
        config_path = self._write_config(
            config_dir,
            extra_lines=extra_config_lines,
        )
        result = self._run_onedrive(
            context,
            sync_root=verify_root,
            config_dir=config_dir,
            extra_args=["--download-only", "--single-directory", scope_root] + (extra_args or []),
        )
        artifacts = [str(config_path)]
        return verify_root, result, artifacts
