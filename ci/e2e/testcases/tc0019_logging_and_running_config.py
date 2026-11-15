from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_onedrive_config, write_text_file


@dataclass(frozen=True)
class OptionConflictScenario:
    scenario_id: str
    label: str
    config: tuple[str, ...] = ()
    cli: tuple[str, ...] = ()
    errors: tuple[str, ...] = ()
    effective: tuple[tuple[str, str], ...] = ()
    # Accepted combinations use --dry-run --logout to test the startup validator
    # without a sync, an authentication change, or any Graph operations.
    expected_exit: int = 1


class TestCase0019LoggingAndRunningConfig(E2ETestCase):
    case_id = "0019"
    name = "logging, running config and option conflict validation"
    description = (
        "Validate custom log_dir and effective runtime configuration, then "
        "stress-test checkForBasicOptionConflicts with isolated negative and "
        "positive controls, including mirror_local_state compatibility"
    )

    LOGGING_SCENARIO = "OC-0001"
    CONFIG_OPTION_PATTERN = re.compile(
        r"^Config option '(?P<name>[^']+)'\s*=\s*(?P<value>.*?)\s*$",
        re.MULTILINE,
    )
    # Only these startup markers are checked. Merely mentioning OneDrive in a
    # configuration dump is not evidence of a remote operation.
    REMOTE_ACTIVITY_MARKERS = (
        "Attempting to contact the Microsoft OneDrive Service",
        "Testing network connectivity",
        "Starting a sync with Microsoft OneDrive",
        "Performing initial synchronisation",
        "Successfully deleted item from Microsoft OneDrive",
    )

    @staticmethod
    def _scenarios() -> list[OptionConflictScenario]:
        cases: list[OptionConflictScenario] = []

        def add(label: str, *, config: tuple[str, ...] = (),
                cli: tuple[str, ...] = (), errors: tuple[str, ...] = (),
                effective: tuple[tuple[str, str], ...] = (),
                accepted: bool = False) -> None:
            cases.append(OptionConflictScenario(
                scenario_id=f"OC-{len(cases) + 2:04d}", label=label,
                config=config, cli=cli, errors=errors, effective=effective,
                expected_exit=0 if accepted else 1,
            ))

        # Permission validation and mutually exclusive operational modes.
        for key in ("sync_dir_permissions", "sync_file_permissions"):
            for value in ("-1", "778"):
                add(f"reject {key}={value}", config=(f'{key} = "{value}"',),
                    errors=(f"ERROR: Invalid 'User|Group|Other' permissions set for '{key}'",))
        add("upload_only and download_only", cli=("--upload-only", "--download-only"),
            errors=("ERROR: --upload-only and --download-only cannot be used together",),
            effective=(("upload_only", "true"), ("download_only", "true")))
        add("sync and monitor", cli=("--sync", "--monitor"),
            errors=("ERROR: --sync and --monitor cannot be used together",))
        add("no_remote_delete requires upload_only",
            config=('no_remote_delete = "true"',),
            errors=("ERROR: --no-remote-delete can only be used with --upload-only",))
        add("remove_source_files requires upload_only",
            config=('remove_source_files = "true"',),
            errors=("ERROR: --remove-source-files can only be used with --upload-only",))
        add("cleanup_local_files requires download_only",
            config=('cleanup_local_files = "true"',),
            errors=("ERROR: --cleanup-local-files can only be used with --download-only",))

        # Query-mode conflicts: each flag is exercised against both resync forms.
        for opt, setting, diagnostic in (
            ("list-shared-items", 'list_business_shared_items = "true"',
             "ERROR: --list-shared-items cannot be used with --resync or --resync-auth"),
            ("display-sync-status", 'display_sync_status = "true"',
             "ERROR: --display-sync-status cannot be used with --resync or --resync-auth"),
            ("modified-by", 'modified_by = "test-user"',
             "ERROR: --modified-by cannot be used with --resync or --resync-auth"),
            ("get-file-link", 'get_file_link = "sample.txt"',
             "ERROR: --get-file-link cannot be used with --resync or --resync-auth"),
            ("create-share-link", 'create_share_link = "sample.txt"',
             "ERROR: --create-share-link cannot be used with --resync or --resync-auth"),
            ("get-sharepoint-drive-id", 'sharepoint_library_name = "Documents"',
             "ERROR: --get-sharepoint-drive-id cannot be used with --resync or --resync-auth"),
        ):
            for resync_flag in ("--resync", "--resync-auth"):
                add(f"{opt} incompatible with {resync_flag}",
                    config=(setting,), cli=(resync_flag,), errors=(diagnostic,))

        for cli_opt in ("--sync", "--monitor"):
            add(f"list-shared-items incompatible with {cli_opt}",
                config=('list_business_shared_items = "true"',), cli=(cli_opt,),
                errors=("ERROR: --list-shared-items cannot be used with --sync or --monitor",))
            add(f"display-sync-status incompatible with {cli_opt}",
                config=('display_sync_status = "true"',), cli=(cli_opt,),
                errors=(f"ERROR: {cli_opt} and --display-sync-status cannot be used together",))
            add(f"display-quota incompatible with {cli_opt}",
                config=('display_quota = "true"',), cli=(cli_opt,),
                errors=(f"ERROR: {cli_opt} and --display-quota cannot be used together",))

        add("sync-shared-files requires sync_business_shared_items",
            config=('sync_business_shared_files = "true"',),
            errors=("ERROR: The --sync-shared-files option can only be utilised",))
        add("force-sync without --single-directory", cli=("--sync", "--force-sync"),
            errors=("ERROR: --force-sync can only be used with --sync --single-directory",))
        add("force-sync with monitor", cli=("--monitor", "--force-sync", "--single-directory", "testscope"),
            errors=("ERROR: --force-sync can only be used with --sync --single-directory",))
        add("azure_ad_endpoint requires tenant ID",
            config=('azure_ad_endpoint = "https://login.example.invalid"',),
            errors=("ERROR: config option 'azure_tenant_id' cannot be empty",))
        add("enabled logging requires log_dir",
            config=('enable_logging = "true"', 'log_dir = ""'),
            errors=("ERROR: config option 'log_dir' cannot be empty",))
        add("empty sync_dir", config=('sync_dir = "   "',),
            errors=("ERROR: --syncdir value cannot be empty",))

        for cli_opt in ("--sync", "--monitor"):
            for key, display in (
                ("create_directory", "create-directory"),
                ("remove_directory", "remove-directory"),
                ("source_directory", "source-directory"),
                ("destination_directory", "destination-directory"),
            ):
                add(f"{display} incompatible with {cli_opt}",
                    config=(f'{key} = "testscope"',), cli=(cli_opt,),
                    errors=(f"ERROR: {cli_opt} and --{display} cannot be used together",))

        add("download_only with local_first", cli=("--download-only", "--local-first"),
            errors=("ERROR: --download-only cannot be used with --local-first",))
        for key, display in (
            ("modified_by", "modified-by"),
            ("get_file_link", "get-file-link"),
            ("create_share_link", "create-share-link"),
            ("create_directory", "create-directory"),
            ("remove_directory", "remove-directory"),
            ("source_directory", "source-directory"),
            ("destination_directory", "destination-directory"),
        ):
            add(f"reject directive-like {display} value",
                config=(f'{key} = "--not-an-argument"',),
                errors=(f"ERROR: --{display} missing a valid entry",))
        add("use_intune_sso and use_device_auth",
            config=('use_intune_sso = "true"', 'use_device_auth = "true"'),
            errors=("ERROR: 'use_intune_sso' and 'use_device_auth' cannot be used together",))
        add("force and resync", cli=("--force", "--resync"),
            errors=("ERROR: --force and --resync cannot be used together",))

        # PR #3971, issue #3970. Verify the three new checks from the config
        # file, command line, and mixed sources, as well as error aggregation.
        mirror_requires_local = "ERROR: --mirror-local-state requires --local-first"
        mirror_no_upload = "ERROR: --mirror-local-state cannot be used with --upload-only"
        mirror_no_download = "ERROR: --mirror-local-state cannot be used with --download-only"
        add("mirror without local_first (config)",
            config=('mirror_local_state = "true"',), errors=(mirror_requires_local,),
            effective=(("mirror_local_state", "true"), ("local_first", "false")))
        add("mirror with upload_only and local_first (config)",
            config=('mirror_local_state = "true"', 'local_first = "true"', 'upload_only = "true"'),
            errors=(mirror_no_upload,),
            effective=(("mirror_local_state", "true"), ("local_first", "true"), ("upload_only", "true")))
        add("mirror with download_only and local_first (config)",
            config=('mirror_local_state = "true"', 'local_first = "true"', 'download_only = "true"'),
            errors=(mirror_no_download, "ERROR: --download-only cannot be used with --local-first"),
            effective=(("download_only", "true"), ("mirror_local_state", "true")))
        add("mirror without local_first (CLI)", cli=("--mirror-local-state",),
            errors=(mirror_requires_local,), effective=(("mirror_local_state", "true"),))
        add("mirror + local_first + upload_only (CLI)",
            cli=("--mirror-local-state", "--local-first", "--upload-only"),
            errors=(mirror_no_upload,), effective=(("local_first", "true"), ("upload_only", "true")))
        add("mirror + local_first + download_only (CLI)",
            cli=("--mirror-local-state", "--local-first", "--download-only"),
            errors=(mirror_no_download, "ERROR: --download-only cannot be used with --local-first"))
        add("mirror configured, upload_only CLI override",
            config=('mirror_local_state = "true"', 'local_first = "true"'),
            cli=("--upload-only",), errors=(mirror_no_upload,))
        add("upload_only configured, mirror CLI override",
            config=('upload_only = "true"', 'local_first = "true"'),
            cli=("--mirror-local-state",), errors=(mirror_no_upload,))
        add("mirror configured, local_first CLI override",
            config=('mirror_local_state = "true"',), cli=("--local-first", "--upload-only"),
            errors=(mirror_no_upload,), effective=(("local_first", "true"),))
        add("all invalid mirror combinations; aggregate diagnostics",
            config=('mirror_local_state = "true"', 'upload_only = "true"', 'download_only = "true"'),
            errors=(mirror_requires_local, mirror_no_upload, mirror_no_download,
                    "ERROR: --upload-only and --download-only cannot be used together"))

        # Positive controls: the validator must not start rejecting supported
        # combinations. These are isolated, read-only startup checks, not E2E
        # functional synchronisation (TC0064 covers the valid mirror workflow).
        add("baseline accepted", accepted=True,
            effective=(("mirror_local_state", "false"), ("upload_only", "false")))
        add("mirror and local_first accepted (config)", accepted=True,
            config=('mirror_local_state = "true"', 'local_first = "true"'),
            effective=(("mirror_local_state", "true"), ("local_first", "true")))
        add("mirror and local_first accepted (CLI)", accepted=True,
            cli=("--mirror-local-state", "--local-first"),
            effective=(("mirror_local_state", "true"), ("local_first", "true")))
        add("upload_only and local_first accepted without mirror", accepted=True,
            config=('upload_only = "true"', 'local_first = "true"'),
            effective=(("upload_only", "true"), ("mirror_local_state", "false")))
        add("download_only accepted without local_first", accepted=True,
            cli=("--download-only",), effective=(("download_only", "true"), ("local_first", "false")))
        add("no_remote_delete accepted with upload_only", accepted=True,
            config=('upload_only = "true"', 'no_remote_delete = "true"'))
        add("remove_source_files accepted with upload_only", accepted=True,
            config=('upload_only = "true"', 'remove_source_files = "true"'))
        add("cleanup_local_files accepted with download_only", accepted=True,
            config=('download_only = "true"', 'cleanup_local_files = "true"'))
        add("sync shared files accepted with Business Shared Items", accepted=True,
            config=('sync_business_shared_files = "true"', 'sync_business_shared_items = "true"'))
        add("tenant provided for azure endpoint", accepted=True,
            config=('azure_ad_endpoint = "https://login.example.invalid"',
                    'azure_tenant_id = "example.invalid"'))
        add("normal permission bounds accepted", accepted=True,
            config=('sync_dir_permissions = "700"', 'sync_file_permissions = "600"'))
        add("force-sync accepted with sync and single-directory", accepted=True,
            cli=("--sync", "--single-directory", "testscope", "--force-sync"))

        return cases

    @staticmethod
    def _config_for_scenario(sync_root: Path, scenario: OptionConflictScenario) -> str:
        # One canonical value per key: avoid relying on duplicate-key parser
        # semantics when deliberately testing an invalid sync_dir.
        base = {'sync_dir': str(sync_root)}
        other_lines: list[str] = []
        for line in scenario.config:
            if line.startswith('sync_dir = '):
                base['sync_dir'] = line.split('=', 1)[1].strip().strip('"')
            else:
                other_lines.append(line)
        return f'sync_dir = "{base["sync_dir"]}"\n' + '\n'.join(other_lines) + '\n'

    @staticmethod
    def _snapshot(paths: list[Path]) -> dict[str, tuple[int, str, int, int] | None]:
        # Do not emit the refresh-token digest in logs or user-facing metadata.
        state: dict[str, tuple[int, str, int, int] | None] = {}
        for path in paths:
            if not path.is_file():
                state[path.name] = None
            else:
                raw = path.read_bytes()
                stat = path.stat()
                state[path.name] = (len(raw), hashlib.sha256(raw).hexdigest(),
                                    stat.st_mtime_ns, stat.st_mode)
        return state

    @classmethod
    def _effective_values(cls, output: str) -> dict[str, str]:
        return {match.group('name').strip(): match.group('value').strip()
                for match in cls.CONFIG_OPTION_PATTERN.finditer(output)}

    def _run_logging_scenario(self, context: E2EContext, layout) -> tuple[list[str], dict[str, object], list[str]]:
        sync_root = layout.work_dir / "syncroot"
        confdir = layout.work_dir / "conf-main"
        root_name = f"ZZ_E2E_TC0019_{context.run_id}_{os.getpid()}"
        app_log_dir = layout.log_dir / "app-logs"

        write_text_file(sync_root / root_name / "logging.txt", "log me\n")
        context.bootstrap_config_dir(confdir)
        write_onedrive_config(
            confdir / "config",
            "# tc0019 config\n"
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n',
        )
        stdout_file = layout.log_dir / "logging_stdout.log"
        stderr_file = layout.log_dir / "logging_stderr.log"
        metadata_file = layout.state_dir / "metadata.txt"
        command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--resync", "--resync-auth", "--single-directory", root_name,
            "--syncdir", str(sync_root), "--confdir", str(confdir),
        ]
        context.log(f"TC0019 {self.LOGGING_SCENARIO}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        log_entries = (sorted(str(p.relative_to(app_log_dir)) for p in app_log_dir.rglob('*') if p.is_file())
                       if app_log_dir.exists() else [])
        write_text_file(metadata_file, '\n'.join([
            f"scenario={self.LOGGING_SCENARIO}", f"root_name={root_name}",
            f"returncode={result.returncode}",
            *[f'log_file={entry}' for entry in log_entries],
        ]) + '\n')
        artifacts = [str(stdout_file), str(stderr_file), str(metadata_file)]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))
        details = {'scenario_id': self.LOGGING_SCENARIO, 'returncode': result.returncode,
                   'root_name': root_name, 'log_file_count': len(log_entries)}
        failures: list[str] = []
        if result.returncode != 0:
            failures.append(f'{self.LOGGING_SCENARIO}: logging validation exit={result.returncode}')
        if not log_entries:
            failures.append(f'{self.LOGGING_SCENARIO}: no application log files created')
        elif not any((app_log_dir / entry).stat().st_size > 0 for entry in log_entries):
            failures.append(f'{self.LOGGING_SCENARIO}: all application log files are empty')
        output = result.stdout.lower()
        if 'log_dir' not in output or str(app_log_dir).lower() not in output:
            failures.append(f'{self.LOGGING_SCENARIO}: active log_dir not displayed')
        return artifacts, details, failures

    def _run_option_scenarios(self, context: E2EContext, layout,
                              scenarios: list[OptionConflictScenario]) -> tuple[list[str], dict[str, object], list[str]]:
        output_dir = layout.log_dir / 'option_conflicts'
        output_dir.mkdir(parents=True, exist_ok=True)
        summary_file = layout.state_dir / 'option_conflicts.json'
        failure_log = layout.state_dir / 'option_conflicts_failures.txt'
        records: list[dict[str, object]] = []
        failures: list[str] = []

        for scenario in scenarios:
            scenario_root = layout.work_dir / 'option_conflicts' / scenario.scenario_id
            sync_root = scenario_root / 'syncroot'
            conf = scenario_root / 'conf'
            # A canary catches accidental local writes even on a rejected
            # configuration. Nothing from these scenarios is synced to Graph.
            canary = sync_root / 'local-preservation-canary.txt'
            write_text_file(canary, 'TC0019 local filesystem must remain unchanged\n')
            config_text = self._config_for_scenario(sync_root, scenario)
            context.prepare_minimal_config_dir(conf, config_text)
            original_canary = self._snapshot([canary])
            original_local_paths = {str(p.relative_to(sync_root)) for p in sync_root.rglob('*')}
            config_files = [conf / name for name in
                            ('config', '.config.backup', '.config.hash', 'refresh_token', 'items.sqlite3')]
            original_config = self._snapshot(config_files)
            original_conf_names = {p.name for p in conf.iterdir()}

            # --display-running-config reports the final values, then executes
            # checkForBasicOptionConflicts(). Unlike --display-config it does
            # not exit before validation. --dry-run --logout provides a bounded
            # successful path WITHOUT Microsoft Graph or destructive logout.
            command = [context.onedrive_bin, '--display-running-config', '--dry-run', '--logout',
                       *scenario.cli, '--confdir', str(conf)]
            context.log(f'TC0019 {scenario.scenario_id}: {scenario.label} :: {command_to_string(command)}')
            result = run_command(command, cwd=context.repo_root)
            stdout = output_dir / f'{scenario.scenario_id}.stdout.log'
            stderr = output_dir / f'{scenario.scenario_id}.stderr.log'
            write_text_file(stdout, result.stdout)
            write_text_file(stderr, result.stderr)
            combined = result.stdout + '\n' + result.stderr
            visible = self._effective_values(combined)
            errors: list[str] = []
            if result.returncode != scenario.expected_exit:
                errors.append(f'expected exit {scenario.expected_exit}, got {result.returncode}')
            for marker in scenario.errors:
                if marker not in combined:
                    errors.append(f'missing diagnostic: {marker}')
            # Accepted controls must be accepted by the conflict checker, not
            # merely return 0 after an unrelated option diagnostic.
            if scenario.expected_exit == 0 and 'ERROR:' in combined:
                errors.append('unexpected ERROR diagnostic in accepted control')
            for key, expected in scenario.effective:
                if visible.get(key) != expected:
                    errors.append(f'effective {key} expected {expected}, got {visible.get(key)!r}')
            if not visible:
                errors.append('missing --display-running-config effective options')
            unexpected_remote = [m for m in self.REMOTE_ACTIVITY_MARKERS if m in combined]
            if unexpected_remote:
                errors.append(f'unexpected network/sync activity marker: {unexpected_remote}')
            if self._snapshot([canary]) != original_canary:
                errors.append('local preservation canary changed')
            if {str(p.relative_to(sync_root)) for p in sync_root.rglob('*')} != original_local_paths:
                errors.append('local filesystem contents changed')
            # A rejected configuration must not update authentication state,
            # config backups/hashes, or create an item database.
            if scenario.expected_exit == 1 and self._snapshot(config_files) != original_config:
                errors.append('rejected configuration modified runtime config/auth/database state')
            if scenario.expected_exit == 1 and {p.name for p in conf.iterdir()} != original_conf_names:
                errors.append('rejected configuration created or removed runtime config files')
            if (conf / 'items.sqlite3').exists():
                errors.append('items.sqlite3 unexpectedly created')

            record: dict[str, object] = {
                'scenario_id': scenario.scenario_id,
                'label': scenario.label,
                'expected_exit': scenario.expected_exit,
                'returncode': result.returncode,
                'expected_diagnostics': list(scenario.errors),
                'cli_flags': list(scenario.cli),
                'command': command_to_string(command),
                'result': 'PASS' if not errors else 'FAIL',
                'errors': errors,
                'stdout': str(stdout),
                'stderr': str(stderr),
            }
            records.append(record)
            if errors:
                failures.append(f'{scenario.scenario_id} ({scenario.label}): ' + '; '.join(errors))

        write_text_file(summary_file, json.dumps({
            'case_id': self.case_id,
            'executed_scenarios': len(scenarios),
            'passed_scenarios': len(scenarios) - len(failures),
            'failed_scenarios': len(failures),
            'results': records,
        }, indent=2, sort_keys=True) + '\n')
        write_text_file(failure_log, '\n'.join(failures) + ('\n' if failures else ''))
        return [str(output_dir), str(summary_file), str(failure_log)], {
            'option_scenarios': len(scenarios),
            'option_passed': len(scenarios) - len(failures),
            'option_failed': len(failures),
            'option_failed_scenario_ids': [r['scenario_id'] for r in records if r['result'] == 'FAIL'],
        }, failures

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name='tc0019', ensure_refresh_token=True)
        logging_selected = context.should_run_scenario(self.case_id, self.LOGGING_SCENARIO)
        all_cases = self._scenarios()
        selected = [c for c in all_cases if context.should_run_scenario(self.case_id, c.scenario_id)]
        if not logging_selected and not selected:
            return self.fail_result(reason='No TC0019 scenarios selected', artifacts=[], details={})

        artifacts: list[str] = []
        details: dict[str, object] = {
            'total_scenarios': len(selected) + int(logging_selected),
            'selected_option_scenarios': [c.scenario_id for c in selected],
            'logging_selected': logging_selected,
            'executed_scenario_ids': ([self.LOGGING_SCENARIO] if logging_selected else [])
                                     + [c.scenario_id for c in selected],
        }
        failures: list[str] = []
        failed_scenario_ids: list[str] = []
        if logging_selected:
            a, d, f = self._run_logging_scenario(context, layout)
            artifacts.extend(a)
            details['logging'] = d
            failures.extend(f)
            if f:
                failed_scenario_ids.append(self.LOGGING_SCENARIO)
        if selected:
            a, d, f = self._run_option_scenarios(context, layout, selected)
            artifacts.extend(a)
            details.update(d)
            failures.extend(f)
            failed_scenario_ids.extend(d['option_failed_scenario_ids'])

        details['scenario_count'] = len(details['executed_scenario_ids'])
        details['failed_scenarios'] = len(failed_scenario_ids)
        details['failed_scenario_ids'] = failed_scenario_ids
        if failures:
            return self.fail_result(reason=(
                f'TC0019: {len(failures)} scenario(s) failed: ' + ' | '.join(failures[:5])
            ), artifacts=artifacts, details=details)
        return self.pass_result(artifacts=artifacts, details=details)
