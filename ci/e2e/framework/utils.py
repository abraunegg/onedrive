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
    Clean the entire account by:
    1. Discovering and materialising remote state locally without uploading anything
    2. Deleting everything locally
    3. Running sync to push deletes online
    4. Running download-only sync to confirm the remote side is empty

    Returns:
        (success, reason, artifacts, details)
    """
    ensure_directory(log_dir)
    ensure_directory(sync_dir)

    phase1_stdout = log_dir / "cleanup_phase1_resync_stdout.log"
    phase1_stderr = log_dir / "cleanup_phase1_resync_stderr.log"
    phase2_state = log_dir / "cleanup_phase2_local_purge_state.txt"
    phase3_stdout = log_dir / "cleanup_phase3_push_deletes_stdout.log"
    phase3_stderr = log_dir / "cleanup_phase3_push_deletes_stderr.log"
    phase4_stdout = log_dir / "cleanup_phase4_verify_empty_stdout.log"
    phase4_stderr = log_dir / "cleanup_phase4_verify_empty_stderr.log"

    artifacts = [
        str(phase1_stdout),
        str(phase1_stderr),
        str(phase2_state),
        str(phase3_stdout),
        str(phase3_stderr),
        str(phase4_stdout),
        str(phase4_stderr),
    ]

    # Phase 1:
    # Discover remote state only. Do not upload anything. Do not fail because
    # stale remote testcase artefacts trigger download-integrity validation.
    phase1_command = [
        onedrive_bin,
        "--sync",
        "--verbose",
        "--download-only",
        "--resync",
        "--resync-auth",
        "--disable-download-validation",
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

    # Phase 2:
    # Purge the entire local sync root. Cleanup is destructive by design.
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

    # Phase 3:
    # Push local deletions online.
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

    # Phase 4:
    # Verify emptiness by pulling from remote only.
    # If anything still exists online, it will be downloaded back locally.
    phase4_command = [
        onedrive_bin,
        "--sync",
        "--verbose",
        "--download-only",
        "--disable-download-validation",
        "--confdir",
        str(config_dir),
    ]
    phase4 = run_command_logged(
        phase4_command,
        stdout_file=phase4_stdout,
        stderr_file=phase4_stderr,
        cwd=repo_root,
    )
    if phase4.returncode != 0:
        return (
            False,
            f"Cleanup phase 4 failed with status {phase4.returncode}",
            artifacts,
            {
                "phase4_returncode": phase4.returncode,
                "phase4_command": command_to_string(phase4_command),
            },
        )

    remaining_after_verify = [str(child) for child in sync_dir.iterdir()]
    if remaining_after_verify:
        return (
            False,
            "Cleanup verification failed: remote content still exists after delete propagation",
            artifacts,
            {"remaining_after_verify": remaining_after_verify},
        )

    return (
        True,
        "",
        artifacts,
        {
            "phase1_returncode": phase1.returncode,
            "phase3_returncode": phase3.returncode,
            "phase4_returncode": phase4.returncode,
            "phase1_command": command_to_string(phase1_command),
            "phase3_command": command_to_string(phase3_command),
            "phase4_command": command_to_string(phase4_command),
        },
    )