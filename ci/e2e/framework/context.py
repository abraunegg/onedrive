from __future__ import annotations

import json
import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from framework.utils import (
    compute_quickxor_hash_file,
    ensure_directory,
    get_optional_base_config_text,
    timestamp_now,
    write_text_file,
    write_text_file_append,
)


def _normalise_case_id(value: str) -> str:
    text = value.strip()
    if not text:
        return ""
    if text.lower().startswith("tc"):
        text = text[2:]
    if text.isdigit() and len(text) <= 4:
        text = text.zfill(4)
    return text


def _parse_case_filter_env(raw: str) -> set[str]:
    selected: set[str] = set()
    for token in raw.split(","):
        case_id = _normalise_case_id(token)
        if case_id:
            selected.add(case_id)
    return selected


def _parse_scenario_filter_env(raw: str) -> dict[str, set[str]]:
    if not raw.strip():
        return {}

    decoded = json.loads(raw)
    parsed: dict[str, set[str]] = {}

    for raw_case_id, raw_scenarios in decoded.items():
        case_id = _normalise_case_id(str(raw_case_id))
        if not case_id:
            continue

        scenario_ids: set[str] = set()
        for scenario_id in raw_scenarios:
            scenario_text = str(scenario_id).strip()
            if scenario_text:
                scenario_ids.add(scenario_text)

        if scenario_ids:
            parsed[case_id] = scenario_ids

    return parsed


@dataclass
class E2EContext:
    """Runtime context for the E2E framework."""

    real_onedrive_bin: str
    onedrive_bin: str
    e2e_target: str
    run_id: str

    repo_root: Path
    out_dir: Path
    logs_dir: Path
    state_dir: Path
    work_root: Path

    debug_enabled: bool = False
    skip_suite_cleanup: bool = False
    run_label: str = "primary"
    selected_case_ids: set[str] = field(default_factory=set)
    selected_scenarios: dict[str, set[str]] = field(default_factory=dict)

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

        output_subdir = os.environ.get("E2E_OUTPUT_SUBDIR", "").strip()
        out_dir = repo_root / "ci" / "e2e" / "out"
        if output_subdir:
            out_dir = out_dir / output_subdir

        logs_dir = out_dir / "logs"
        state_dir = out_dir / "state"

        runner_temp = os.environ.get("RUNNER_TEMP", "/tmp").strip()
        work_root = Path(runner_temp) / f"onedrive-e2e-{e2e_target}"
        if output_subdir:
            safe_subdir = output_subdir.replace("/", "_")
            work_root = work_root / safe_subdir

        debug_enabled = os.environ.get("E2E_DEBUG", "").strip().lower() in {"1", "true", "yes", "on"}
        skip_suite_cleanup = os.environ.get("E2E_SKIP_SUITE_CLEANUP", "").strip().lower() in {"1", "true", "yes", "on"}
        run_label = os.environ.get("E2E_RUN_LABEL", "").strip() or "primary"
        selected_case_ids = _parse_case_filter_env(os.environ.get("E2E_SELECTED_CASES", ""))
        selected_scenarios = _parse_scenario_filter_env(os.environ.get("E2E_SELECTED_SCENARIOS_JSON", ""))

        return cls(
            real_onedrive_bin=onedrive_bin,
            onedrive_bin=onedrive_bin,
            e2e_target=e2e_target,
            run_id=run_id,
            repo_root=repo_root,
            out_dir=out_dir,
            logs_dir=logs_dir,
            state_dir=state_dir,
            work_root=work_root,
            debug_enabled=debug_enabled,
            skip_suite_cleanup=skip_suite_cleanup,
            run_label=run_label,
            selected_case_ids=selected_case_ids,
            selected_scenarios=selected_scenarios,
        )

    @property
    def master_log_file(self) -> Path:
        return self.out_dir / "run.log"

    @property
    def default_onedrive_config_dir(self) -> Path:
        xdg_config_home = os.environ.get("XDG_CONFIG_HOME", "").strip()
        if xdg_config_home:
            return Path(xdg_config_home) / "onedrive"

        home = os.environ.get("HOME", "").strip()
        if not home:
            raise RuntimeError("Neither XDG_CONFIG_HOME nor HOME is set")

        return Path(home) / ".config" / "onedrive"

    @property
    def default_refresh_token_path(self) -> Path:
        return self.default_onedrive_config_dir / "refresh_token"

    def prepare_runtime(self) -> None:
        ensure_directory(self.out_dir)
        ensure_directory(self.logs_dir)
        ensure_directory(self.state_dir)
        ensure_directory(self.work_root)

        if not self.debug_enabled:
            return

        wrapper_path = self.work_root / "onedrive-debug-wrapper.sh"
        wrapper_content = (
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"REAL_BIN={json.dumps(self.real_onedrive_bin)}\n"
            "exec \"${REAL_BIN}\" --verbose \"$@\"\n"
        )
        write_text_file(wrapper_path, wrapper_content)
        os.chmod(wrapper_path, 0o755)
        self.onedrive_bin = str(wrapper_path)

    def ensure_refresh_token_available(self) -> None:
        if not self.default_refresh_token_path.is_file():
            raise RuntimeError(
                f"Required refresh_token file not found at: {self.default_refresh_token_path}"
            )

    def should_run_case(self, case_id: str) -> bool:
        if not self.selected_case_ids:
            return True
        return _normalise_case_id(case_id) in self.selected_case_ids

    def selected_scenarios_for_case(self, case_id: str) -> set[str]:
        return set(self.selected_scenarios.get(_normalise_case_id(case_id), set()))

    def should_run_scenario(self, case_id: str, scenario_id: str) -> bool:
        selected = self.selected_scenarios_for_case(case_id)
        if not selected:
            return True
        return scenario_id in selected

    def _extract_config_value(self, config_text: str, key: str) -> str:
        for raw_line in config_text.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue

            lhs, rhs = line.split("=", 1)
            if lhs.strip() != key:
                continue

            value = rhs.strip()
            if value.startswith('"') and value.endswith('"') and len(value) >= 2:
                value = value[1:-1]
            return value.strip()

        return ""

    def validate_generated_config_dir(self, config_dir: Path) -> None:
        """
        Validate a generated runtime config dir so target-specific bootstrap
        mistakes fail immediately and explicitly.
        Only SharePoint requires a seeded config containing drive_id.
        """
        if self.e2e_target != "sharepoint":
            return

        config_path = config_dir / "config"
        if not config_path.is_file():
            raise RuntimeError(
                f"SharePoint target requested but generated config file is missing: {config_path}"
            )

        config_text = config_path.read_text(encoding="utf-8")
        drive_id = self._extract_config_value(config_text, "drive_id")
        if not drive_id:
            raise RuntimeError(
                f"SharePoint target requested but generated config has empty or missing drive_id: {config_path}"
            )

    def bootstrap_config_dir(self, config_dir: Path) -> Path:
        """
        Copy the existing refresh_token into a per-test/per-scenario config dir.
        If a base config.sharepoint exists, seed config with that content so all
        SharePoint scenarios inherit drive_id by default.
        """
        self.ensure_refresh_token_available()
        ensure_directory(config_dir)

        source = self.default_refresh_token_path
        destination = config_dir / "refresh_token"
        shutil.copy2(source, destination)
        os.chmod(destination, 0o600)

        base_config_text = get_optional_base_config_text()
        if base_config_text:
            write_text_file(config_dir / "config", base_config_text)
            os.chmod(config_dir / "config", 0o600)

        self.validate_generated_config_dir(config_dir)
        return destination

    def prepare_minimal_config_dir(self, config_dir: Path, config_text: str) -> Path:
        """
        Create a clean, runtime-ready OneDrive config dir containing only the
        minimum artefacts required for the client to start without immediately
        demanding a --resync.

        Files created:
        - refresh_token
        - config
        - .config.backup
        - .config.hash
        """
        self.ensure_refresh_token_available()

        if config_dir.exists():
            shutil.rmtree(config_dir)

        ensure_directory(config_dir)

        refresh_token_destination = config_dir / "refresh_token"
        shutil.copy2(self.default_refresh_token_path, refresh_token_destination)
        os.chmod(refresh_token_destination, 0o600)

        full_config_text = get_optional_base_config_text() + config_text

        config_path = config_dir / "config"
        config_path.write_text(full_config_text, encoding="utf-8")
        os.chmod(config_path, 0o600)

        backup_path = config_dir / ".config.backup"
        backup_path.write_text(full_config_text, encoding="utf-8")
        os.chmod(backup_path, 0o600)

        hash_path = config_dir / ".config.hash"
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(hash_path, 0o600)

        self.validate_generated_config_dir(config_dir)
        return config_path

    def log(self, message: str) -> None:
        ensure_directory(self.out_dir)
        line = f"[{timestamp_now()}] {message}\n"
        print(line, end="")
        write_text_file_append(self.master_log_file, line)

    @property
    def default_sync_dir(self) -> Path:
        home = os.environ.get("HOME", "").strip()
        if not home:
            raise RuntimeError("HOME is not set")
        return Path(home) / "OneDrive"

    @property
    def suite_cleanup_config_dir(self) -> Path:
        return self.work_root / "suite-cleanup-conf"

    @property
    def suite_cleanup_log_dir(self) -> Path:
        return self.logs_dir / "_suite_cleanup"

    @property
    def suite_cleanup_sync_dir(self) -> Path:
        return self.work_root / "suite-cleanup-syncroot"

    def bootstrap_suite_cleanup_config_dir(self) -> Path:
        if self.suite_cleanup_config_dir.exists():
            shutil.rmtree(self.suite_cleanup_config_dir)
        return self.bootstrap_config_dir(self.suite_cleanup_config_dir)
