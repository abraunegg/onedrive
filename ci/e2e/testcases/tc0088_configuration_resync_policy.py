from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.utils import command_to_string, run_command, write_text_file


@dataclass(frozen=True)
class Transition:
    scenario: str
    label: str
    before: tuple[str, ...]
    after: tuple[str, ...]
    requires_resync: bool
    cli: tuple[str, ...] = ()
    sync_list_before: str | None = None
    sync_list_after: str | None = None
    causes: tuple[str, ...] = ()
    prefix_action: str = ""


class TestCase0088ConfigurationResyncPolicy(E2ETestCase):
    case_id = "0088"
    name = "configuration change resync policy validation"
    description = (
        "Verify config-hash and backup comparison, non-resync modifications, "
        "mandatory exit 78, and no accidental acceptance of unsafe changes"
    )
    EXIT_RESYNC_REQUIRED = 78
    STOP_MESSAGE = "An application configuration change has been detected where a --resync is required"

    # Cause mapping is explicitly specified for each policy expectation, rather
    # than inferred from the same before/after parsing algorithm used by config.d.
    # A testcase must not pass on exit 78 triggered by some other option.
    CAUSE_PATTERN = re.compile(
        r'(?P<key>drive_id|sync_dir|skip_file|skip_dir|skip_dotfiles|'
        r'skip_symlinks|sync_business_shared_items|check_nosync|skip_size)'
        r'(?: was modified since the last time the application was successfully run, --resync required'
        r'| newly added \.\.\. --resync needed'
        r'|: CLI override of config file option, --resync needed)'
        r'|(?P<list>sync_list file has been updated, --resync needed)'
    )
    CONFIG_LINE = re.compile(r'^\s*(?P<key>[a-z_]+)\s*=\s*"(?P<value>.*)"\s*$')

    @classmethod
    def _reported_causes(cls, output: str) -> set[str]:
        causes: set[str] = set()
        for line in output.splitlines():
            # Only examine the causal messages emitted by logAndSetDifference().
            # DEBUG key dumps, configuration displays and generic stop messages
            # must never qualify as proof of which option caused exit 78.
            match = cls.CAUSE_PATTERN.search(line)
            if match:
                causes.add('sync_list' if match.group('list') else match.group('key'))
        return causes

    @staticmethod
    def _config_text(sync_root: Path, lines: tuple[str, ...]) -> str:
        return '\n'.join([f'sync_dir = "{sync_root}"', *lines]) + '\n'

    @classmethod
    def _modify_prefix(cls, prefix: str, action: str) -> str:
        """Change only framework-generated drive_id; leave other base config alone.

        An intentionally invalid alternative drive ID is safe: expected exit 78
        must happen before Graph I/O. Any exit 1/Graph error is a hard failure.
        """
        if not action:
            return prefix
        lines = prefix.splitlines(keepends=True)
        existing = [i for i, line in enumerate(lines)
                    if (m := cls.CONFIG_LINE.match(line.rstrip('\r\n'))) and m.group('key') == 'drive_id']
        if action == 'drive_change':
            if not existing:
                # Accounts without a base drive_id exercise the 'newly added'
                # branch. Keep it in the scenario-specific part of the config.
                return prefix + 'drive_id = "TC0088_NON_EXISTENT_DRIVE_ID"\n'
            idx = existing[-1]
            original = cls.CONFIG_LINE.match(lines[idx].rstrip('\r\n')).group('value')
            alternate = ('Z' if original[:1] != 'Z' else 'Y') + original[1:]
            if alternate == original:
                raise ValueError('Unable to mutate drive_id')
            lines[idx] = f'drive_id = "{alternate}"\n'
            return ''.join(lines)
        if action == 'drive_remove':
            if not existing:
                # Missing drive_id already represents the default; there is
                # no meaningful removal on a non-SharePoint account.
                return prefix
            return ''.join(line for i, line in enumerate(lines) if i not in existing)
        if action == 'drive_empty':
            if not existing:
                return prefix + 'drive_id = ""\n'
            for i in existing:
                lines[i] = 'drive_id = ""\n'
            return ''.join(lines)
        raise ValueError(f'Unknown prefix action: {action}')

    @staticmethod
    def _cases() -> list[Transition]:
        cases: list[Transition] = []

        def add(label: str, before: tuple[str, ...] = (), after: tuple[str, ...] = (),
                *, causes: tuple[str, ...] = (), cli: tuple[str, ...] = (),
                sync_before: str | None = None, sync_after: str | None = None,
                prefix_action: str = '') -> None:
            number = len(cases) + 1
            cases.append(Transition(f'CR-{number:04d}', label, before, after,
                                    bool(causes), cli, sync_before, sync_after,
                                    causes, prefix_action))

        # Control cases: default, enabled flags, and special skip_file policy.
        control_baselines = (
            ('default', (), ()),
            ('nosync', ('check_nosync = "true"',), ()),
            ('size', ('skip_size = "1"',), ()),
            ('both', ('check_nosync = "true"', 'skip_size = "1"'), ()),
            ('custom_skip_file', ('skip_file = "*.tc0088ignored"',), ('skip_file',)),
            ('all_filters', ('check_nosync = "true"', 'skip_size = "1"',
                             'skip_file = "*.tc0088ignored"', 'skip_dir = "TC0088Excluded"'), ('skip_file',)),
        )
        for label, baseline, special_causes in control_baselines:
            add(f'{label}: unrelated space_reservation edit',
                baseline + ('space_reservation = "50"',),
                baseline + ('space_reservation = "60"',), causes=special_causes)
            add(f'{label}: comments only', baseline + ('# first comment',),
                baseline + ('# changed comment',), causes=special_causes)
            add(f'{label}: byte-identical config', baseline + ('# stable',),
                baseline + ('# stable',))

        # All these are runtime-only changes. The coexistence of check_nosync
        # and skip_size is the concrete regression from #3928.
        runtime_options = (
            ('threads', '1', '2'),
            ('monitor_interval', '300', '301'),
            ('monitor_log_frequency', '12', '13'),
            ('monitor_fullscan_frequency', '12', '13'),
            ('disable_websocket_support', 'false', 'true'),
            ('notify_monitor_start', 'true', 'false'),
            ('force_http_11', 'false', 'true'),
            ('rate_limit', '0', '10000000'),
            ('operation_timeout', '0', '120'),
            ('connect_timeout', '10', '20'),
            ('data_timeout', '60', '90'),
            ('dns_timeout', '60', '90'),
            ('display_transfer_metrics', 'false', 'true'),
            ('check_nomount', 'false', 'true'),
            ('disable_time_check', 'false', 'true'),
        )
        for key, a, b in runtime_options:
            add(f'runtime-only {key}', ('check_nosync = "true"', 'skip_size = "1"', f'{key} = "{a}"'),
                ('check_nosync = "true"', 'skip_size = "1"', f'{key} = "{b}"'))

        # Generate independent coverage for all policies; each expected cause
        # is authored explicitly and is not computed from process exit status.
        for key in ('check_nosync', 'skip_dotfiles', 'skip_symlinks', 'sync_business_shared_items'):
            f = f'{key} = "false"'
            t = f'{key} = "true"'
            add(f'{key}: false -> true', (f,), (t,), causes=(key,))
            add(f'{key}: true -> false', (t,), (f,), causes=(key,))
            add(f'{key}: absent -> true', (), (t,), causes=(key,))
            add(f'{key}: true -> absent', (t,), (), causes=(key,))
            add(f'{key}: absent -> explicit false', (), (f,))
            add(f'{key}: explicit false -> absent', (f,), ())
            add(f'{key}: stable true, harmless edit', (t, 'space_reservation = "50"'),
                (t, 'space_reservation = "60"'))
            add(f'{key}: stable false, harmless edit', (f, 'space_reservation = "50"'),
                (f, 'space_reservation = "60"'))

        for key, a, b in (('skip_size', '1', '2'),
                          ('skip_dir', 'TC0088Alpha', 'TC0088Beta')):
            default = '' if key == 'skip_dir' else '0'
            av, bv, zero = f'{key} = "{a}"', f'{key} = "{b}"', f'{key} = "{default}"'
            add(f'{key}: value changed', (av,), (bv,), causes=(key,))
            add(f'{key}: absent -> nondefault', (), (av,), causes=(key,))
            add(f'{key}: nondefault -> absent', (av,), (), causes=(key,))
            add(f'{key}: nondefault -> default', (av,), (zero,), causes=(key,))
            add(f'{key}: default -> nondefault', (zero,), (av,), causes=(key,))
            add(f'{key}: absent -> explicit default', (), (zero,))
            add(f'{key}: explicit default -> absent', (zero,), ())
            add(f'{key}: unchanged nondefault, harmless edit',
                (av, 'space_reservation = "50"'), (av, 'space_reservation = "60"'))

        # skip_file's special default comparison intentionally forces resync on
        # a config edit when a nondefault custom rule exists in the backup.
        a, b = 'skip_file = "*.tc0088alpha"', 'skip_file = "*.tc0088beta"'
        add('skip_file: changed custom rule', (a,), (b,), causes=('skip_file',))
        add('skip_file: add custom rule', (), (a,), causes=('skip_file',))
        add('skip_file: remove custom rule', (a,), (), causes=('skip_file',))
        add('skip_file: unchanged custom rule, unrelated edit',
            (a, 'space_reservation = "50"'), (a, 'space_reservation = "60"'),
            causes=('skip_file',))
        add('skip_file: two custom rules unchanged, unrelated edit',
            (a, b, 'space_reservation = "50"'),
            (a, b, 'space_reservation = "60"'), causes=('skip_file',))
        add('skip_file: two custom rules -> one', (a, b), (a,), causes=('skip_file',))
        add('skip_file: one custom rule -> two', (a,), (a, b), causes=('skip_file',))
        add('skip_file: nondefault -> explicit empty', (a,), ('skip_file = ""',), causes=('skip_file',))
        add('skip_file: explicit empty -> custom', ('skip_file = ""',), (a,), causes=('skip_file',))

        add('skip_dir: two rules unchanged, unrelated edit',
            ('skip_dir = "TC0088One"', 'skip_dir = "TC0088Two"', 'space_reservation = "50"'),
            ('skip_dir = "TC0088One"', 'skip_dir = "TC0088Two"', 'space_reservation = "60"'))
        add('skip_dir: two rules -> one', ('skip_dir = "TC0088One"', 'skip_dir = "TC0088Two"'),
            ('skip_dir = "TC0088One"',), causes=('skip_dir',))
        add('skip_dir: one rule -> two', ('skip_dir = "TC0088One"',),
            ('skip_dir = "TC0088One"', 'skip_dir = "TC0088Two"'), causes=('skip_dir',))

        # sync_dir differs from other options: a different path can affect data.
        # The expected exit 78 must occur before opening the changed sync root.
        # Retain the framework base sync_dir; alter just the scenario-owned one.
        add('sync_dir: changed path', (), (), causes=('sync_dir',), prefix_action='sync_path_change')
        add('sync_dir: removed (default restored)', (), (), causes=('sync_dir',), prefix_action='sync_path_remove')
        add('sync_dir: explicitly empty (default restored)', (), (), causes=('sync_dir',), prefix_action='sync_path_empty')
        add('sync_dir: CLI --syncdir override', (), (), causes=('sync_dir',),
            cli=('--syncdir', '__DIFFERENT_SYNC_DIR__'))

        # Real drive_id from framework base config is tested on SharePoint.
        # On accounts with no base drive_id, first test addition to configuration.
        add('drive_id: modified or newly added', (), (), causes=('drive_id',), prefix_action='drive_change')
        add('drive_id: removed from configured account', (), (), causes=('drive_id',), prefix_action='drive_remove')
        add('drive_id: explicitly emptied', (), (), causes=('drive_id',), prefix_action='drive_empty')
        add('drive_id: unchanged, unrelated edit', ('space_reservation = "50"',),
            ('space_reservation = "60"',))
        add('drive_id: plus skip_size change', ('skip_size = "1"',),
            ('skip_size = "2"',), causes=('drive_id', 'skip_size'), prefix_action='drive_change')
        add('drive_id: plus sync_dir change', (), (), causes=('drive_id', 'sync_dir'),
            prefix_action='drive_and_path_change')

        # Paired changes must *both* be reported by logAndSetDifference.
        add('check_nosync and skip_size both changed',
            ('check_nosync = "true"', 'skip_size = "1"'),
            ('check_nosync = "false"', 'skip_size = "2"'), causes=('check_nosync', 'skip_size'))
        add('check_nosync changed with harmless runtime edit',
            ('check_nosync = "true"', 'space_reservation = "50"'),
            ('check_nosync = "false"', 'space_reservation = "60"'), causes=('check_nosync',))
        add('skip_dir plus skip_dotfiles', ('skip_dir = "TC0088A"', 'skip_dotfiles = "false"'),
            ('skip_dir = "TC0088B"', 'skip_dotfiles = "true"'),
            causes=('skip_dir', 'skip_dotfiles'))
        add('skip_file plus skip_size', ('skip_file = "*.tc0088alpha"', 'skip_size = "1"'),
            ('skip_file = "*.tc0088beta"', 'skip_size = "2"'),
            causes=('skip_file', 'skip_size'))

        # Hash-controlled sync_list policy (initial state created by resync).
        add('sync_list: changed', (), (), causes=('sync_list',),
            sync_before='/$SCOPE\n', sync_after='/TC0088Different\n')
        add('sync_list: unchanged plus harmless config change',
            ('space_reservation = "50"',), ('space_reservation = "60"',),
            sync_before='/$SCOPE\n', sync_after='/$SCOPE\n')
        add('sync_list: change plus skip_size', ('skip_size = "1"',), ('skip_size = "2"',),
            causes=('sync_list', 'skip_size'),
            sync_before='/$SCOPE\n', sync_after='/TC0088Different\n')

        # CLI overrides must not be mistaken for backup-vs-file comparisons.
        add('CLI --check-for-nosync', (), (), causes=('check_nosync',), cli=('--check-for-nosync',))
        add('CLI --skip-size', (), (), causes=('skip_size',), cli=('--skip-size', '1'))
        add('CLI --skip-dot-files', (), (), causes=('skip_dotfiles',), cli=('--skip-dot-files',))
        add('CLI --skip-symlinks', (), (), causes=('skip_symlinks',), cli=('--skip-symlinks',))
        add('CLI --skip-dir', ('skip_dir = "TC0088Original"',),
            ('skip_dir = "TC0088Original"',), causes=('skip_dir',),
            cli=('--skip-dir', 'TC0088Different'))
        add('CLI --skip-file', ('skip_file = "*.tc0088original"',),
            ('skip_file = "*.tc0088original"',), causes=('skip_file',),
            cli=('--skip-file', '*.tc0088different'))
        return cases

    def run(self, context: E2EContext):
        layout = self.prepare_case_layout(context, case_dir_name="tc0088")
        cases = [s for s in self._cases() if context.should_run_scenario(self.case_id, s.scenario)]
        if not cases:
            return self.fail_result(reason="No TC0088 scenarios selected", artifacts=[], details={})

        # Use a real authenticated account, but a new isolated configuration for
        # every scenario. No dummy refresh tokens or fake successful outcomes.
        # Empty fixture scope keeps the validation small and avoids remote writes.
        sync_root = layout.work_dir / "syncroot"
        sync_root.mkdir(parents=True, exist_ok=True)
        scope = f"ZZ_E2E_TC0088_{context.run_id}_{os.getpid()}"
        artifacts: list[str] = []
        details: dict[str, object] = {"scenario_count": len(cases), "scope": scope}
        # Establish an actual small remote fixture so each allowed transition can
        # complete a real --single-directory pass rather than fail on an absent path.
        seed_conf = layout.work_dir / "seed-conf"
        context.prepare_minimal_config_dir(seed_conf, f'sync_dir = "{sync_root}"\n')
        write_text_file(sync_root / scope / "baseline.txt", "tc0088 baseline\n")
        seed_command = [context.onedrive_bin, "--sync", "--upload-only", "--resync",
                        "--resync-auth", "--single-directory", scope,
                        "--confdir", str(seed_conf)]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        seed_stdout = layout.log_dir / "seed.stdout"
        seed_stderr = layout.log_dir / "seed.stderr"
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        artifacts.extend([str(seed_stdout), str(seed_stderr)])
        if seed_result.returncode != 0:
            seed_output = (seed_result.stdout + "\n" + seed_result.stderr).strip()
            # Preserve full output in the artifacts, but surface the failure in
            # the workflow summary as well so it can be diagnosed immediately.
            diagnostic = seed_output[-4000:] if seed_output else "No client output captured"
            details["seed_command"] = command_to_string(seed_command)
            details["seed_exit"] = seed_result.returncode
            return self.fail_result(
                reason=(f"Remote fixture seed failed: exit {seed_result.returncode}; "
                        f"client output: {diagnostic}"),
                artifacts=artifacts, details=details,
            )
        failures: list[str] = []
        records: list[dict[str, object]] = []

        for scenario in cases:
            scenario_dir = layout.work_dir / scenario.scenario
            conf = scenario_dir / "conf"
            conf.mkdir(parents=True, exist_ok=True)
            # This helper creates .config.backup and .config.hash corresponding to
            # BEFORE. The runtime reads AFTER and checks the transition.
            initial = '\n'.join([f'sync_dir = "{sync_root}"', *scenario.before]) + '\n'
            context.prepare_minimal_config_dir(conf, initial)
            # The framework prefixes target-specific configuration (notably
            # SharePoint drive_id) before our scenario-specific settings. Keep
            # that prefix unchanged when moving from BEFORE to AFTER.
            baseline_config = (conf / "config").read_text(encoding="utf-8")
            if not baseline_config.endswith(initial):
                return self.fail_result(
                    reason=f"{scenario.scenario}: generated baseline does not end with scenario settings",
                    artifacts=artifacts, details=details,
                )
            target_prefix = baseline_config[:-len(initial)]
            if scenario.sync_list_before is not None:
                # Adding sync_list is itself a resync-sensitive change. Establish
                # the initial sync_list state with an authorised resync before
                # testing subsequent changes without --resync.
                write_text_file(conf / "sync_list", scenario.sync_list_before.replace("$SCOPE", scope))
            if scenario.sync_list_before is not None:
                prime_cmd = [context.onedrive_bin, "--sync", "--download-only",
                             "--resync", "--resync-auth",
                             "--single-directory", scope, "--confdir", str(conf)]
                prime = run_command(prime_cmd, cwd=context.repo_root)
                write_text_file(layout.log_dir / f"{scenario.scenario}_prime.stdout", prime.stdout)
                write_text_file(layout.log_dir / f"{scenario.scenario}_prime.stderr", prime.stderr)
                if prime.returncode != 0:
                    prime_output = (prime.stdout + "\n" + prime.stderr).strip()
                    failures.append(
                        f"{scenario.scenario} priming failed: exit {prime.returncode}; "
                        f"client output: {prime_output[-2000:] if prime_output else 'No client output captured'}"
                    )
                    records.append({"id": scenario.scenario, "label": scenario.label,
                                    "prime_exit": prime.returncode, "status": "fail"})
                    continue
            final = '\n'.join([f'sync_dir = "{sync_root}"', *scenario.after]) + '\n'
            # Preserve every framework setting unless the scenario is an
            # explicit drive_id or sync_dir transition.
            updated_prefix = target_prefix
            if scenario.prefix_action in ('drive_change', 'drive_and_path_change'):
                updated_prefix = self._modify_prefix(target_prefix, 'drive_change')
            if scenario.prefix_action in ('drive_remove', 'drive_empty'):
                # Only meaningful where the harness config already supplies an
                # account-specific drive_id. Do not silently turn an absent->
                # absent transition into a green 'removal' test.
                if not any((match := self.CONFIG_LINE.match(line)) and match.group('key') == 'drive_id'
                           for line in target_prefix.splitlines()):
                    records.append({'id': scenario.scenario, 'label': scenario.label,
                                    'status': 'not_applicable',
                                    'reason': 'No configured drive_id in framework base config'})
                    continue
                updated_prefix = self._modify_prefix(target_prefix, scenario.prefix_action)
            if scenario.prefix_action in ('sync_path_change', 'drive_and_path_change'):
                final = self._config_text(sync_root / 'TC0088_NONEXISTENT_ROOT', scenario.after)
            if scenario.prefix_action == 'sync_path_remove':
                final = '\n'.join(scenario.after) + '\n'
            if scenario.prefix_action == 'sync_path_empty':
                final = self._config_text(sync_root, scenario.after).replace(
                    f'sync_dir = "{sync_root}"', 'sync_dir = ""', 1)
            updated_config = updated_prefix + final
            if scenario.before == scenario.after and updated_config != baseline_config:
                return self.fail_result(
                    reason=f"{scenario.scenario}: unchanged scenario unexpectedly modified configuration",
                    artifacts=artifacts, details=details,
                )
            write_text_file(conf / "config", updated_config)
            if scenario.sync_list_after is not None:
                write_text_file(conf / "sync_list", scenario.sync_list_after.replace("$SCOPE", scope))
            cli = [str(sync_root / 'TC0088_DIFFERENT_CLI_ROOT') if arg == '__DIFFERENT_SYNC_DIR__'
                   else arg for arg in scenario.cli]
            cmd = [context.onedrive_bin, "--sync", "--download-only", "--verbose", "--verbose",
                   "--single-directory", scope, "--confdir", str(conf), *cli]
            result = run_command(cmd, cwd=context.repo_root)
            out = layout.log_dir / f"{scenario.scenario}.stdout"
            err = layout.log_dir / f"{scenario.scenario}.stderr"
            write_text_file(out, result.stdout)
            write_text_file(err, result.stderr)
            artifacts.extend([str(out), str(err)])
            text = result.stdout + '\n' + result.stderr
            expected = self.EXIT_RESYNC_REQUIRED if scenario.requires_resync else 0
            status_ok = result.returncode == expected
            message_ok = (self.STOP_MESSAGE in text) == scenario.requires_resync
            reported = self._reported_causes(text)
            expected_causes = set(scenario.causes)
            # Exact attribution is required. An unrelated exit 78 is a FAIL.
            causes_ok = reported == expected_causes
            if not status_ok or not message_ok or not causes_ok:
                failures.append(
                    f"{scenario.scenario} {scenario.label}: expected exit={expected}, "
                    f"stop={scenario.requires_resync}, causes={sorted(expected_causes)}; "
                    f"got exit={result.returncode}, stop={self.STOP_MESSAGE in text}, "
                    f"causes={sorted(reported)}"
                )
            records.append({"id": scenario.scenario, "label": scenario.label,
                            "expected_exit": expected, "actual_exit": result.returncode,
                            "stop_message": self.STOP_MESSAGE in text,
                            "expected_causes": sorted(expected_causes),
                            "reported_causes": sorted(reported),
                            "cause_match": causes_ok,
                            "command": command_to_string(cmd),
                            "status": "pass" if status_ok and message_ok and causes_ok else "fail"})

        result_file = layout.state_dir / "scenario_results.json"
        write_text_file(result_file, json.dumps(records, indent=2) + '\n')
        artifacts.append(str(result_file))
        details.update({"passed": sum(x["status"] == "pass" for x in records),
                        "not_applicable": sum(x["status"] == "not_applicable" for x in records),
                        "failed": len(failures), "failure_details": failures})
        if failures:
            return self.fail_result(reason="; ".join(failures[:10]), artifacts=artifacts, details=details)
        return self.pass_result(artifacts=artifacts, details=details)
