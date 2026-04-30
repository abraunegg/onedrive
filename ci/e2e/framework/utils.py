from __future__ import annotations

import os
import shutil
import subprocess
import base64
import time
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


STARTUP_RETRY_ATTEMPTS = 3
STARTUP_RETRY_SLEEP_SECONDS = 3.0
STARTUP_DISCOVERY_FUNCTION_MARKERS = (
    "Calling Function:    syncEngine.getDefaultRootDetails()",
    "Calling Function:    syncEngine.getDefaultDriveDetails()",
)
STARTUP_TRANSIENT_HTTP_MARKERS = (
    "HTTP request returned status code 403 (Forbidden)",
    "HTTP request returned status code 408",
    "HTTP request returned status code 429",
    "HTTP request returned status code 500",
    "HTTP request returned status code 502",
    "HTTP request returned status code 503",
    "HTTP request returned status code 504",
    "Failed to reach the Microsoft OneDrive Service. HTTP status code: 408",
    "Failed to reach the Microsoft OneDrive Service. HTTP status code: 429",
    "Failed to reach the Microsoft OneDrive Service. HTTP status code: 500",
    "Failed to reach the Microsoft OneDrive Service. HTTP status code: 502",
    "Failed to reach the Microsoft OneDrive Service. HTTP status code: 503",
    "Failed to reach the Microsoft OneDrive Service. HTTP status code: 504",
)
STARTUP_TRANSIENT_ERROR_MARKERS = (
    "Error Code:          accessDenied",
    "Unable to reach the Microsoft OneDrive API service, unable to initialise application",
    "Connection timeout",
    "Operation timed out",
    "Timeout was reached",
)


def _combined_output(stdout: str, stderr: str) -> str:
    return f"{stdout}\n{stderr}"


def is_transient_startup_discovery_failure(stdout: str, stderr: str) -> bool:
    content = _combined_output(stdout, stderr)
    has_transient_markers = (
        any(marker in content for marker in STARTUP_TRANSIENT_HTTP_MARKERS)
        or any(marker in content for marker in STARTUP_TRANSIENT_ERROR_MARKERS)
    )

    has_discovery_failure = (
        any(marker in content for marker in STARTUP_DISCOVERY_FUNCTION_MARKERS)
        and has_transient_markers
    )

    has_generic_startup_service_failure = (
        "Attempting to contact the Microsoft OneDrive Service" in content
        and "unable to initialise application" in content.lower()
        and has_transient_markers
    )

    return has_discovery_failure or has_generic_startup_service_failure


def should_retry_startup_failure(stdout: str, stderr: str, attempt: int, max_attempts: int) -> bool:
    return attempt < max_attempts and is_transient_startup_discovery_failure(stdout, stderr)


def run_command_with_startup_retry(
    command: list[str],
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
    *,
    max_attempts: int = STARTUP_RETRY_ATTEMPTS,
    retry_sleep_seconds: float = STARTUP_RETRY_SLEEP_SECONDS,
) -> CommandResult:
    last_result: CommandResult | None = None

    for attempt in range(1, max_attempts + 1):
        completed = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            env=(lambda merged_env: merged_env)(dict(os.environ, **(env or {}))),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
            input=input_text,
        )

        last_result = CommandResult(
            command=command,
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )

        if not should_retry_startup_failure(last_result.stdout, last_result.stderr, attempt, max_attempts):
            return last_result

        time.sleep(retry_sleep_seconds)

    assert last_result is not None
    return last_result


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
    return run_command_with_startup_retry(
        command=command,
        cwd=cwd,
        env=env,
        input_text=input_text,
    )


def command_to_string(command: list[str]) -> str:
    return " ".join(command)

PROTECTED_SUITE_CLEANUP_PREFIXES = (
    "ZZ_SHARED_SEED",
)


def is_protected_suite_cleanup_path(path: Path) -> bool:
    """
    Return True when a top-level local path represents durable online seed
    data that must never be removed by suite-wide cleanup.

    This intentionally protects any top-level name beginning with
    ZZ_SHARED_SEED so both the current 15-character driveId seed
    (ZZ_SHARED_SEED_15CHAR) and future shared-folder seed roots are
    preserved.
    """
    return any(path.name.startswith(prefix) for prefix in PROTECTED_SUITE_CLEANUP_PREFIXES)


def purge_directory_contents(path: Path) -> list[str]:
    """
    Delete files and folders inside 'path', but do not delete 'path' itself.

    Durable shared-folder seed roots are explicitly preserved.  This is
    required because the cleanup syncroot is populated from the account root;
    deleting a preserved local seed root and then running a normal sync would
    delete that online fixture.
    """
    ensure_directory(path)

    preserved: list[str] = []
    for child in path.iterdir():
        if is_protected_suite_cleanup_path(child):
            preserved.append(child.name)
            continue

        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink(missing_ok=True)

    return sorted(preserved)


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

    # Phase 2: delete local content that is safe for suite cleanup.
    #
    # IMPORTANT: do not delete durable shared-folder seed roots. If those
    # directories are removed locally here, phase 3 will propagate that delete
    # to OneDrive and destroy the online shared-folder fixture.
    preserved_after_purge = purge_directory_contents(sync_dir)

    remaining_after_purge = sorted(str(child.name) for child in sync_dir.iterdir())
    write_text_file(
        phase2_state,
        "\n".join(
            ["Preserved by suite cleanup guard:"]
            + preserved_after_purge
            + ["", "Remaining after purge:"]
            + remaining_after_purge
        )
        + "\n",
    )

    unsafe_remaining_after_purge = [
        name for name in remaining_after_purge
        if not name.startswith(PROTECTED_SUITE_CLEANUP_PREFIXES)
    ]
    if unsafe_remaining_after_purge:
        return (
            False,
            "Cleanup phase 2 failed: unsafe local sync directory entries remain after purge",
            artifacts,
            {
                "remaining_after_purge": remaining_after_purge,
                "unsafe_remaining_after_purge": unsafe_remaining_after_purge,
                "preserved_after_purge": preserved_after_purge,
            },
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

    # Phase 4: validate that only explicitly protected seed roots remain.
    remaining_after_sync = sorted(str(child.name) for child in sync_dir.iterdir())
    unsafe_remaining_after_sync = [
        name for name in remaining_after_sync
        if not name.startswith(PROTECTED_SUITE_CLEANUP_PREFIXES)
    ]
    if unsafe_remaining_after_sync:
        return (
            False,
            "Cleanup phase 4 failed: unsafe local sync directory entries remain after sync",
            artifacts,
            {
                "remaining_after_sync": remaining_after_sync,
                "unsafe_remaining_after_sync": unsafe_remaining_after_sync,
            },
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
            "preserved_after_purge": preserved_after_purge,
            "remaining_after_sync": remaining_after_sync,
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


def compute_quickxor_hash_bytes(data: bytes) -> str:
    """
    Compute Microsoft QuickXorHash and return the same base64 string style used
    by the OneDrive client for .config.hash and .sync_list.hash files.

    This implementation is sufficient for small text config files used by the
    E2E harness.
    """
    width_bits = 160
    shift = 11
    cell_count = width_bits // 8
    out = [0] * cell_count

    for i, b in enumerate(data):
        bit_index = (i * shift) % width_bits
        byte_index = bit_index // 8
        bit_offset = bit_index % 8

        value = b & 0xFF

        out[byte_index] ^= (value << bit_offset) & 0xFF
        if bit_offset > 0:
            out[(byte_index + 1) % cell_count] ^= (value >> (8 - bit_offset)) & 0xFF

    length = len(data)
    for i in range(8):
        out[cell_count - 8 + i] ^= (length >> (8 * i)) & 0xFF

    return base64.b64encode(bytes(out)).decode("ascii")


def compute_quickxor_hash_file(path: Path) -> str:
    return compute_quickxor_hash_bytes(path.read_bytes())

