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

E2E_REMOTE_ARTEFACT_SYNC_LIST_ENTRIES = (
    "/ZZ_E2E_*/",
    "/ZZ_E2E_*",
)

def default_e2e_sync_list_text() -> str:
    return "\n".join(E2E_REMOTE_ARTEFACT_SYNC_LIST_ENTRIES) + "\n"

def write_default_e2e_sync_list(config_dir: Path) -> None:
    """
    Restrict normal E2E runs to the harness-owned remote namespace.

    The non-shared E2E suite historically treated the whole OneDrive root as
    disposable during suite cleanup. That is unsafe once an account also hosts
    permanent seed data, such as Personal Shared Folder source folders.

    All non-shared test artefacts are created using top-level names beginning
    with ZZ_E2E_. Keeping this default sync_list in every generated config dir
    prevents unrelated root content from being downloaded, modified or deleted
    by normal test execution. Test cases that explicitly validate sync_list
    behaviour may overwrite or remove this file for their own scenario-specific
    policy.
    """
    write_text_file(config_dir / "sync_list", default_e2e_sync_list_text())

def config_dir_has_e2e_sync_list_guard(config_dir: Path) -> bool:
    sync_list_path = config_dir / "sync_list"
    if not sync_list_path.is_file():
        return False
    return "ZZ_E2E_" in sync_list_path.read_text(encoding="utf-8", errors="replace")



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
    Clean only harness-owned E2E artefacts.

    This deliberately does not use sync_list filtering. The OneDrive sync_list
    syntax is not a shell-style wildcard language, so a guard such as
    /ZZ_E2E_*/ does not safely expose every generated test root.

    Instead, cleanup performs a normal resync into an isolated temporary sync
    root, deletes only local top-level entries whose names start with ZZ_E2E_,
    then runs a normal sync to propagate only those harness-owned deletions.

    Permanent seed data and shared-folder source material may be downloaded into
    this temporary sync root during phase 1, but it is left in place and
    therefore is not propagated as a deletion in phase 3.

    Process:
    1. Run a full resync into an isolated local sync directory.
    2. Delete only top-level ZZ_E2E_* artefacts locally.
    3. Run a normal sync to propagate those harness-owned deletions online.
    4. Validate that no top-level ZZ_E2E_* entries remain locally.

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

    # Phase 1: establish local state in an isolated temporary sync root.
    phase1_command = [
        onedrive_bin,
        "--sync",
        "--verbose",
        "--resync",
        "--resync-auth",
        "--syncdir",
        str(sync_dir),
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

    # Phase 2: delete only harness-owned top-level artefacts.
    deleted_entries: list[str] = []
    preserved_entries: list[str] = []
    for child in sorted(sync_dir.iterdir(), key=lambda path: path.name):
        if child.name.startswith("ZZ_E2E_"):
            deleted_entries.append(child.name)
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
        else:
            preserved_entries.append(child.name)

    write_text_file(
        phase2_state,
        "Deleted top-level ZZ_E2E_* entries:\n"
        + "\n".join(deleted_entries)
        + ("\n" if deleted_entries else "")
        + "\nPreserved non-E2E top-level entries:\n"
        + "\n".join(preserved_entries)
        + ("\n" if preserved_entries else ""),
    )

    # Phase 3: propagate only the local deletions made in phase 2.
    phase3_command = [
        onedrive_bin,
        "--sync",
        "--verbose",
        "--syncdir",
        str(sync_dir),
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

    # Phase 4: validate no harness-owned top-level entries remain.
    remaining_e2e_entries = [child.name for child in sync_dir.iterdir() if child.name.startswith("ZZ_E2E_")]
    if remaining_e2e_entries:
        return (
            False,
            "Cleanup phase 4 failed: top-level ZZ_E2E_* entries remain after sync",
            artifacts,
            {"remaining_e2e_entries": remaining_e2e_entries},
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
            "deleted_entries": deleted_entries,
            "preserved_entries": preserved_entries,
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

