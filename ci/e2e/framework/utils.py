from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass
class CommandResult:
    command: list[str]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def timestamp_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def ensure_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def reset_directory(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def write_text_file(path: Path, content: str) -> None:
    ensure_directory(path.parent)
    path.write_text(content, encoding="utf-8")


def write_text_file_append(path: Path, content: str) -> None:
    ensure_directory(path.parent)
    with path.open("a", encoding="utf-8") as fp:
        fp.write(content)


def run_command(
    command: list[str],
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
) -> CommandResult:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    completed = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        env=merged_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        input=input_text,
    )

    return CommandResult(
        command=command,
        returncode=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
    )


def command_to_string(command: list[str]) -> str:
    return " ".join(command)

def purge_directory_contents(path: Path) -> None:
    """
    Delete all files and folders inside 'path', but do not delete 'path' itself.
    """
    ensure_directory(path)

    for child in path.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink(missing_ok=True)


def run_command_logged(
    command: list[str],
    stdout_file: Path,
    stderr_file: Path,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
) -> CommandResult:
    result = run_command(
        command=command,
        cwd=cwd,
        env=env,
        input_text=input_text,
    )
    write_text_file(stdout_file, result.stdout)
    write_text_file(stderr_file, result.stderr)
    return result


def perform_full_account_cleanup(
    *,
    onedrive_bin: str,
    repo_root: Path,
    config_dir: Path,
    sync_dir: Path,
    log_dir: Path,
) -> tuple[bool, str, list[str], dict]:
    """
    Clean the account by:
    1. Running a full resync to establish local state from remote
    2. Deleting everything locally
    3. Running a normal sync to propagate deletions online
    4. Validating that the local sync directory is empty

    Returns:
        (success, reason, artifacts, details)
    """
    ensure_directory(log_dir)
    ensure_directory(sync_dir)

    phase1_stdout = log_dir / "cleanup_phase1_resync_stdout.log"
    phase1_stderr = log_dir / "cleanup_phase1_resync_stderr.log"
    phase2_state = log_dir / "cleanup_phase2_local_purge_state.txt"
    phase3_stdout = log_dir / "cleanup_phase3_sync_stdout.log"
    phase3_stderr = log_dir / "cleanup_phase3_sync_stderr.log"

    artifacts = [
        str(phase1_stdout),
        str(phase1_stderr),
        str(phase2_state),
        str(phase3_stdout),
        str(phase3_stderr),
    ]

    # Phase 1: establish local state from remote
    phase1_command = [
        onedrive_bin,
        "--sync",
        "--verbose",
        "--resync",
        "--resync-auth",
        "--confdir",
        str(config_dir),
    ]
    phase1 = run_command_logged(
        phase1_command,
        stdout_file=phase1_stdout,
        stderr_file=phase1_stderr,
        cwd=repo_root,
    )
    if phase1.returncode != 0:
        return (
            False,
            f"Cleanup phase 1 failed with status {phase1.returncode}",
            artifacts,
            {
                "phase1_returncode": phase1.returncode,
                "phase1_command": command_to_string(phase1_command),
            },
        )

    # Phase 2: delete everything locally
    purge_directory_contents(sync_dir)

    remaining_after_purge = [str(child) for child in sync_dir.iterdir()]
    write_text_file(
        phase2_state,
        "\n".join(remaining_after_purge) + ("\n" if remaining_after_purge else ""),
    )

    if remaining_after_purge:
        return (
            False,
            "Cleanup phase 2 failed: local sync directory is not empty after purge",
            artifacts,
            {"remaining_after_purge": remaining_after_purge},
        )

    # Phase 3: propagate deletions online
    phase3_command = [
        onedrive_bin,
        "--sync",
        "--verbose",
        "--confdir",
        str(config_dir),
    ]
    phase3 = run_command_logged(
        phase3_command,
        stdout_file=phase3_stdout,
        stderr_file=phase3_stderr,
        cwd=repo_root,
    )
    if phase3.returncode != 0:
        return (
            False,
            f"Cleanup phase 3 failed with status {phase3.returncode}",
            artifacts,
            {
                "phase3_returncode": phase3.returncode,
                "phase3_command": command_to_string(phase3_command),
            },
        )

    # Phase 4: validate local is empty
    remaining_after_sync = [str(child) for child in sync_dir.iterdir()]
    if remaining_after_sync:
        return (
            False,
            "Cleanup phase 4 failed: local sync directory is not empty after sync",
            artifacts,
            {"remaining_after_sync": remaining_after_sync},
        )

    return (
        True,
        "",
        artifacts,
        {
            "phase1_returncode": phase1.returncode,
            "phase3_returncode": phase3.returncode,
            "phase1_command": command_to_string(phase1_command),
            "phase3_command": command_to_string(phase3_command),
        },
    )

def default_onedrive_config_dir_from_env() -> Path:
    xdg_config_home = os.environ.get("XDG_CONFIG_HOME", "").strip()
    if xdg_config_home:
        return Path(xdg_config_home) / "onedrive"

    home = os.environ.get("HOME", "").strip()
    if not home:
        raise RuntimeError("Neither XDG_CONFIG_HOME nor HOME is set")

    return Path(home) / ".config" / "onedrive"


def get_optional_base_config_text() -> str:
    """
    Return the optional base config content used to seed SharePoint-specific
    configuration such as drive_id. For personal/business testing this returns
    an empty string.
    """
    base_config_path = default_onedrive_config_dir_from_env() / "config.sharepoint"
    if not base_config_path.is_file():
        return ""

    text = base_config_path.read_text(encoding="utf-8")
    if text and not text.endswith("\n"):
        text += "\n"
    return text


def write_onedrive_config(path: Path, content: str) -> None:
    """
    Write a test config file, automatically prepending any optional base config
    such as SharePoint drive_id settings from config.sharepoint.
    """
    base_config_text = get_optional_base_config_text()
    write_text_file(path, base_config_text + content)
