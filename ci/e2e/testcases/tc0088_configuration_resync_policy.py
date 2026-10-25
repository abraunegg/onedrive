from __future__ import annotations

import json
import os
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


class TestCase0088ConfigurationResyncPolicy(E2ETestCase):
    case_id = "0088"
    name = "configuration change resync policy validation"
    description = (
        "Verify config-hash and backup comparison, non-resync modifications, "
        "mandatory exit 78, and no accidental acceptance of unsafe changes"
    )
    EXIT_RESYNC_REQUIRED = 78
    STOP_MESSAGE = "An application configuration change has been detected where a --resync is required"

    @staticmethod
    def _cases() -> list[Transition]:
        cases: list[Transition] = []
        index = 0

        def add(label: str, before: tuple[str, ...], after: tuple[str, ...], stop: bool,
                *, cli: tuple[str, ...] = (), sync_before: str | None = None,
                sync_after: str | None = None) -> None:
            nonlocal index
            index += 1
            cases.append(Transition(f"CR-{index:04d}", label, before, after, stop,
                                    cli, sync_before, sync_after))

        # An otherwise harmless edit must not become a mandatory resync simply
        # because an unchanged filtering option exists in the backup config.
        for baseline_label, baseline in (
            ("default", ()),
            ("nosync", ('check_nosync = "true"',)),
            ("size", ('skip_size = "1"',)),
            ("both", ('check_nosync = "true"', 'skip_size = "1"')),
            ("custom_skip_file", ('skip_file = "*.tc0088ignored"',)),
            ("all_filters", ('check_nosync = "true"', 'skip_size = "1"',
                             'skip_file = "*.tc0088ignored"', 'skip_dir = "TC0088Excluded"')),
        ):
            add(f"{baseline_label}: unrelated space_reservation edit", baseline + ('space_reservation = "50"',),
                baseline + ('space_reservation = "60"',), baseline_label in ("custom_skip_file", "all_filters"))
            add(f"{baseline_label}: comments only", baseline + ('# first comment',),
                baseline + ('# changed comment',), baseline_label in ("custom_skip_file", "all_filters"))
            add(f"{baseline_label}: no semantic modification", baseline + ('# stable',),
                baseline + ('# stable',), False)

        # Exercise runtime-only options with the very combination that exposed #3928.
        runtime_options = (
            ('threads = "1"', 'threads = "2"'),
            ('monitor_interval = "300"', 'monitor_interval = "301"'),
            ('monitor_log_frequency = "12"', 'monitor_log_frequency = "13"'),
            ('monitor_fullscan_frequency = "12"', 'monitor_fullscan_frequency = "13"'),
            ('disable_websocket_support = "false"', 'disable_websocket_support = "true"'),
            ('notify_monitor_start = "true"', 'notify_monitor_start = "false"'),
            ('force_http_11 = "false"', 'force_http_11 = "true"'),
            ('rate_limit = "0"', 'rate_limit = "10000000"'),
            ('operation_timeout = "0"', 'operation_timeout = "120"'),
            ('connect_timeout = "10"', 'connect_timeout = "20"'),
            ('data_timeout = "60"', 'data_timeout = "90"'),
            ('dns_timeout = "60"', 'dns_timeout = "90"'),
            ('display_transfer_metrics = "false"', 'display_transfer_metrics = "true"'),
            ('check_nomount = "false"', 'check_nomount = "true"'),
            ('disable_time_check = "false"', 'disable_time_check = "true"'),
        )
        for old, new in runtime_options:
            add(f"runtime {old.split(' =')[0]}",
                ('check_nosync = "true"', 'skip_size = "1"', old),
                ('check_nosync = "true"', 'skip_size = "1"', new), False)

        sensitive = (
            ('check_nosync', 'false', 'true'),
            ('skip_size', '1', '2'),
            ('skip_dotfiles', 'false', 'true'),
            ('skip_symlinks', 'false', 'true'),
            ('sync_business_shared_items', 'false', 'true'),
            ('skip_file', '*.tc0088alpha', '*.tc0088beta'),
            ('skip_dir', 'TC0088Alpha', 'TC0088Beta'),
        )
        for key, old, new in sensitive:
            base = (f'{key} = "{old}"',)
            changed = (f'{key} = "{new}"',)
            add(f"{key}: change", base, changed, True)
            add(f"{key}: unchanged plus unrelated edit", base + ('space_reservation = "50"',),
                base + ('space_reservation = "60"',), key == "skip_file")
            if old not in ('false',):
                add(f"{key}: new non-default", (), changed, True)
            if key in ('check_nosync', 'skip_dotfiles', 'skip_symlinks', 'sync_business_shared_items'):
                add(f"{key}: add true", (), (f'{key} = "true"',), True)
            if key in ('check_nosync', 'skip_dotfiles', 'skip_symlinks', 'sync_business_shared_items'):
                add(f"{key}: remove true", (f'{key} = "true"',), (), True)
            elif key in ('skip_size', 'skip_dir', 'skip_file'):
                add(f"{key}: remove nondefault", changed, (), True)

        add("multiple sensitive options", ('check_nosync = "true"', 'skip_size = "1"'),
            ('check_nosync = "false"', 'skip_size = "2"'), True)
        add("sensitive plus unrelated edit", ('check_nosync = "true"', 'space_reservation = "50"'),
            ('check_nosync = "false"', 'space_reservation = "60"'), True)
        add("skip_file repeated entries, unrelated edit",
            ('skip_file = "*.tc0088one"', 'skip_file = "*.tc0088two"', 'space_reservation = "50"'),
            ('skip_file = "*.tc0088one"', 'skip_file = "*.tc0088two"', 'space_reservation = "60"'), True)
        add("skip_dir repeated entries, unrelated edit",
            ('skip_dir = "TC0088One"', 'skip_dir = "TC0088Two"', 'space_reservation = "50"'),
            ('skip_dir = "TC0088One"', 'skip_dir = "TC0088Two"', 'space_reservation = "60"'), False)
        add("sync_list updated", (), (), True, sync_before="/$SCOPE\n",
            sync_after="/TC0088Different\n")
        add("sync_list unchanged, harmless config edit", ('space_reservation = "50"',),
            ('space_reservation = "60"',), False, sync_before="/$SCOPE\n",
            sync_after="/$SCOPE\n")
        add("CLI --check-for-nosync override", (), (), True, cli=("--check-for-nosync",))
        add("CLI --skip-size override", (), (), True, cli=("--skip-size", "1"))
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
            updated_config = target_prefix + final
            if scenario.before == scenario.after and updated_config != baseline_config:
                return self.fail_result(
                    reason=f"{scenario.scenario}: unchanged scenario unexpectedly modified configuration",
                    artifacts=artifacts, details=details,
                )
            write_text_file(conf / "config", updated_config)
            if scenario.sync_list_after is not None:
                write_text_file(conf / "sync_list", scenario.sync_list_after.replace("$SCOPE", scope))
            cmd = [context.onedrive_bin, "--sync", "--download-only", "--verbose",
                   "--single-directory", scope, "--confdir", str(conf), *scenario.cli]
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
            if not status_ok or not message_ok:
                failures.append(f"{scenario.scenario} {scenario.label}: expected exit {expected} "
                                f"and stop_message={scenario.requires_resync}, got exit {result.returncode} "
                                f"and stop_message={self.STOP_MESSAGE in text}")
            records.append({"id": scenario.scenario, "label": scenario.label,
                            "expected_exit": expected, "actual_exit": result.returncode,
                            "stop_message": self.STOP_MESSAGE in text,
                            "command": command_to_string(cmd),
                            "status": "pass" if status_ok and message_ok else "fail"})

        result_file = layout.state_dir / "scenario_results.json"
        write_text_file(result_file, json.dumps(records, indent=2) + '\n')
        artifacts.append(str(result_file))
        details.update({"passed": sum(x["status"] == "pass" for x in records),
                        "failed": len(failures), "failure_details": failures})
        if failures:
            return self.fail_result(reason="; ".join(failures[:10]), artifacts=artifacts, details=details)
        return self.pass_result(artifacts=artifacts, details=details)
