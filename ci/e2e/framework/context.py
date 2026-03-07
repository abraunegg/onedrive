from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from framework.utils import ensure_directory, timestamp_now, write_text_file_append


@dataclass
class E2EContext:
    """
    Runtime context for the E2E framework.
    """

    onedrive_bin: str
    e2e_target: str
    run_id: str

    repo_root: Path
    out_dir: Path
    logs_dir: Path
    state_dir: Path
    work_root: Path

    @classmethod
    def from_environment(cls) -> "E2EContext":
        onedrive_bin = os.environ.get("ONEDRIVE_BIN", "").strip()
        e2e_target = os.environ.get("E2E_TARGET", "").strip()
        run_id = os.environ.get("RUN_ID", "").strip()

        if not onedrive_bin:
            raise RuntimeError("Environment variable ONEDRIVE_BIN must be set")
        if not e2e_target:
            raise RuntimeError("Environment variable E2E_TARGET must be set")
        if not run_id:
            raise RuntimeError("Environment variable RUN_ID must be set")

        repo_root = Path.cwd()
        out_dir = repo_root / "ci" / "e2e" / "out"
        logs_dir = out_dir / "logs"
        state_dir = out_dir / "state"

        runner_temp = os.environ.get("RUNNER_TEMP", "/tmp").strip()
        work_root = Path(runner_temp) / f"onedrive-e2e-{e2e_target}"

        return cls(
            onedrive_bin=onedrive_bin,
            e2e_target=e2e_target,
            run_id=run_id,
            repo_root=repo_root,
            out_dir=out_dir,
            logs_dir=logs_dir,
            state_dir=state_dir,
            work_root=work_root,
        )

    @property
    def master_log_file(self) -> Path:
        return self.out_dir / "run.log"

    def log(self, message: str) -> None:
        ensure_directory(self.out_dir)
        line = f"[{timestamp_now()}] {message}\n"
        print(line, end="")
        write_text_file_append(self.master_log_file, line)