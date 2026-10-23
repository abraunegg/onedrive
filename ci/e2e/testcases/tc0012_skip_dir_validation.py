from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


@dataclass(frozen=True)
class SkipDirScenario:
    scenario_id: str
    description: str
    direction: str
    skip_dir_entries: tuple[str, ...]
    strict: bool
    files: tuple[tuple[str, str], ...]
    expected_present: tuple[str, ...]
    expected_absent: tuple[str, ...]
    single_directory: str | None = None
    mode: str = "ordinary"  # ordinary, tracked_exclusion, invalid_config


@dataclass
class ScenarioResult:
    scenario_id: str
    description: str
    passed: bool
    failure_messages: list[str]
    artifacts: list[str]
    details: dict[str, object]


class TestCase0012SkipDirValidation(E2ETestCase):
    case_id = "0012"
    name = "skip_dir validation"
    description = (
        "Validate skip_dir semantic contracts across local and remote processing, including "
        "unanchored matching, strict full-path matching, sync-root anchored paths, wildcards, "
        "case-insensitive matching and multiple configured patterns"
    )

    LOCAL_TO_REMOTE = "local_to_remote"
    REMOTE_TO_LOCAL = "remote_to_local"

    def _write_config(
        self,
        config_path: Path,
        *,
        skip_dir_entries: tuple[str, ...] = (),
        strict: bool = False,
        label: str,
    ) -> None:
        lines = [
            f"# tc0012 {label} config",
            'bypass_data_preservation = "true"',
        ]

        for entry in skip_dir_entries:
            lines.append(f'skip_dir = "{entry}"')

        if skip_dir_entries:
            lines.append(
                f'skip_dir_strict_match = "{"true" if strict else "false"}"'
            )

        write_onedrive_config(config_path, "\n".join(lines) + "\n")

    @staticmethod
    def _write_metadata(path: Path, details: dict[str, object]) -> None:
        write_text_file(
            path,
            "\n".join(
                f"{key}={value!r}" for key, value in sorted(details.items())
            )
            + "\n",
        )

    @staticmethod
    def _append_scope(command: list[str], single_directory: str | None) -> None:
        if single_directory:
            command.extend(["--single-directory", single_directory])

    def _build_scenarios(self, suffix: str) -> list[SkipDirScenario]:
        loose_local_root = f"ZZ_E2E_TC0012_SD0001_{suffix}"
        loose_remote_root = f"ZZ_E2E_TC0012_SD0002_{suffix}"

        strict_local_root = f"ZZ_E2E_TC0012_SD0003_{suffix}"
        strict_remote_root = f"ZZ_E2E_TC0012_SD0004_{suffix}"

        anchored_loose = f"ZZ_E2E_TC0012_ANCHORED_LOOSE_{suffix}"
        anchored_loose_container = f"ZZ_E2E_TC0012_CONTAINER_LOOSE_{suffix}"

        anchored_strict = f"ZZ_E2E_TC0012_ANCHORED_STRICT_{suffix}"
        anchored_strict_container = f"ZZ_E2E_TC0012_CONTAINER_STRICT_{suffix}"

        multi_loose_root = f"ZZ E2E TC0012 SD0007 Project Files {suffix}"
        multi_strict_root = f"ZZ E2E TC0012 SD0008 Project Files {suffix}"

        mixed_local_root = f"ZZ_E2E_TC0012_SD0009_{suffix}"
        mixed_remote_root = f"ZZ_E2E_TC0012_SD0010_{suffix}"

        return [
            SkipDirScenario(
                scenario_id="SD-0001",
                description="unanchored directory name, non-strict, local to remote",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=("Cache",),
                strict=False,
                files=(
                    (f"{loose_local_root}/Cache/top.txt", "skip top\n"),
                    (f"{loose_local_root}/App/Cache/nested.txt", "skip nested\n"),
                    (f"{loose_local_root}/Keep/ok.txt", "keep\n"),
                ),
                expected_present=(f"{loose_local_root}/Keep/ok.txt",),
                expected_absent=(
                    f"{loose_local_root}/Cache/top.txt",
                    f"{loose_local_root}/App/Cache/nested.txt",
                ),
                single_directory=loose_local_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0002",
                description="unanchored directory name, non-strict, remote to local",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=("Cache",),
                strict=False,
                files=(
                    (f"{loose_remote_root}/Cache/top.txt", "skip top\n"),
                    (f"{loose_remote_root}/App/Cache/nested.txt", "skip nested\n"),
                    (f"{loose_remote_root}/Keep/ok.txt", "keep\n"),
                ),
                expected_present=(f"{loose_remote_root}/Keep/ok.txt",),
                expected_absent=(
                    f"{loose_remote_root}/Cache/top.txt",
                    f"{loose_remote_root}/App/Cache/nested.txt",
                ),
                single_directory=loose_remote_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0003",
                description="strict explicit full path, local to remote",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=(f"{strict_local_root}/App/Cache",),
                strict=True,
                files=(
                    (f"{strict_local_root}/Cache/top.txt", "top remains\n"),
                    (f"{strict_local_root}/App/Cache/nested.txt", "strict skip\n"),
                    (f"{strict_local_root}/Keep/ok.txt", "keep\n"),
                ),
                expected_present=(
                    f"{strict_local_root}/Cache/top.txt",
                    f"{strict_local_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{strict_local_root}/App/Cache/nested.txt",
                ),
                single_directory=strict_local_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0004",
                description="strict explicit full path, remote to local",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"{strict_remote_root}/App/Cache",),
                strict=True,
                files=(
                    (f"{strict_remote_root}/Cache/top.txt", "top remains\n"),
                    (f"{strict_remote_root}/App/Cache/nested.txt", "strict skip\n"),
                    (f"{strict_remote_root}/Keep/ok.txt", "keep\n"),
                ),
                expected_present=(
                    f"{strict_remote_root}/Cache/top.txt",
                    f"{strict_remote_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{strict_remote_root}/App/Cache/nested.txt",
                ),
                single_directory=strict_remote_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0005",
                description=(
                    "sync-root anchored single-segment path, non-strict, "
                    "remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"/{anchored_loose}",),
                strict=False,
                files=(
                    (
                        f"{anchored_loose}/root-only.txt",
                        "must skip only at sync root\n",
                    ),
                    (
                        f"{anchored_loose_container}/{anchored_loose}/"
                        "nested-must-sync.txt",
                        "same-named nested directory must remain in scope\n",
                    ),
                    (
                        f"{anchored_loose_container}/keep.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{anchored_loose_container}/{anchored_loose}/"
                    "nested-must-sync.txt",
                    f"{anchored_loose_container}/keep.txt",
                ),
                expected_absent=(
                    f"{anchored_loose}/root-only.txt",
                ),
                single_directory=None,
            ),
            SkipDirScenario(
                scenario_id="SD-0006",
                description=(
                    "sync-root anchored single-segment path, strict, "
                    "remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"/{anchored_strict}",),
                strict=True,
                files=(
                    (
                        f"{anchored_strict}/root-only.txt",
                        "must skip only at sync root\n",
                    ),
                    (
                        f"{anchored_strict_container}/{anchored_strict}/"
                        "nested-must-sync.txt",
                        "same-named nested directory must remain in scope\n",
                    ),
                    (
                        f"{anchored_strict_container}/keep.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{anchored_strict_container}/{anchored_strict}/"
                    "nested-must-sync.txt",
                    f"{anchored_strict_container}/keep.txt",
                ),
                expected_absent=(
                    f"{anchored_strict}/root-only.txt",
                ),
                single_directory=None,
            ),
            SkipDirScenario(
                scenario_id="SD-0007",
                description=(
                    "sync-root anchored multi-segment path with spaces and "
                    "trailing slash, non-strict, remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"/{multi_loose_root}/Cache Data/",),
                strict=False,
                files=(
                    (
                        f"{multi_loose_root}/Cache Data/"
                        "root-path-must-skip.txt",
                        "root-relative multi-segment path must skip\n",
                    ),
                    (
                        f"{multi_loose_root}/Container/{multi_loose_root}/"
                        "Cache Data/nested-suffix-must-sync.txt",
                        "same suffix below another prefix must remain in scope\n",
                    ),
                    (
                        f"{multi_loose_root}/Keep/ok.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{multi_loose_root}/Container/{multi_loose_root}/"
                    "Cache Data/nested-suffix-must-sync.txt",
                    f"{multi_loose_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{multi_loose_root}/Cache Data/"
                    "root-path-must-skip.txt",
                ),
                single_directory=multi_loose_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0008",
                description=(
                    "sync-root anchored multi-segment path with spaces and "
                    "trailing slash, strict, remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"/{multi_strict_root}/Cache Data/",),
                strict=True,
                files=(
                    (
                        f"{multi_strict_root}/Cache Data/"
                        "root-path-must-skip.txt",
                        "root-relative multi-segment path must skip\n",
                    ),
                    (
                        f"{multi_strict_root}/Container/{multi_strict_root}/"
                        "Cache Data/nested-suffix-must-sync.txt",
                        "same suffix below another prefix must remain in scope\n",
                    ),
                    (
                        f"{multi_strict_root}/Keep/ok.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{multi_strict_root}/Container/{multi_strict_root}/"
                    "Cache Data/nested-suffix-must-sync.txt",
                    f"{multi_strict_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{multi_strict_root}/Cache Data/"
                    "root-path-must-skip.txt",
                ),
                single_directory=multi_strict_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0009",
                description=(
                    "mixed patterns, repeated skip_dir entries, wildcard and "
                    "case-insensitive matching, local to remote"
                ),
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=(
                    "cache*|Case?Dir",
                    f"/{mixed_local_root}/Explicit*",
                ),
                strict=False,
                files=(
                    (
                        f"{mixed_local_root}/CacheAlpha/a.txt",
                        "skip wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/Nested/CACHEBeta/b.txt",
                        "skip case-insensitive wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/CaseXDir/c.txt",
                        "skip question wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/Nested/caseYdir/d.txt",
                        "skip case-insensitive question wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/ExplicitOne/e.txt",
                        "skip anchored wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/Nested/ExplicitOne/f.txt",
                        "anchored wildcard must not match nested suffix\n",
                    ),
                    (
                        f"{mixed_local_root}/Keep/ok.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{mixed_local_root}/Nested/ExplicitOne/f.txt",
                    f"{mixed_local_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{mixed_local_root}/CacheAlpha/a.txt",
                    f"{mixed_local_root}/Nested/CACHEBeta/b.txt",
                    f"{mixed_local_root}/CaseXDir/c.txt",
                    f"{mixed_local_root}/Nested/caseYdir/d.txt",
                    f"{mixed_local_root}/ExplicitOne/e.txt",
                ),
                single_directory=mixed_local_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0010",
                description=(
                    "mixed patterns, repeated skip_dir entries, wildcard and "
                    "case-insensitive matching, remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(
                    "cache*|Case?Dir",
                    f"/{mixed_remote_root}/Explicit*",
                ),
                strict=False,
                files=(
                    (
                        f"{mixed_remote_root}/CacheAlpha/a.txt",
                        "skip wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/Nested/CACHEBeta/b.txt",
                        "skip case-insensitive wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/CaseXDir/c.txt",
                        "skip question wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/Nested/caseYdir/d.txt",
                        "skip case-insensitive question wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/ExplicitOne/e.txt",
                        "skip anchored wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/Nested/ExplicitOne/f.txt",
                        "anchored wildcard must not match nested suffix\n",
                    ),
                    (
                        f"{mixed_remote_root}/Keep/ok.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{mixed_remote_root}/Nested/ExplicitOne/f.txt",
                    f"{mixed_remote_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{mixed_remote_root}/CacheAlpha/a.txt",
                    f"{mixed_remote_root}/Nested/CACHEBeta/b.txt",
                    f"{mixed_remote_root}/CaseXDir/c.txt",
                    f"{mixed_remote_root}/Nested/caseYdir/d.txt",
                    f"{mixed_remote_root}/ExplicitOne/e.txt",
                ),
                single_directory=mixed_remote_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0011",
                description='literal square brackets and false-positive digit' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Photos [2023]',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0011_{suffix}" + '/Photos [2023]/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0011_{suffix}" + '/Photos 2/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0011_{suffix}" + '/Photos 3/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0011_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0011_{suffix}" + '/Photos 2/retained.txt',
                    f"ZZ_E2E_TC0012_SD0011_{suffix}" + '/Photos 3/retained.txt',
                    f"ZZ_E2E_TC0012_SD0011_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0011_{suffix}" + '/Photos [2023]/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0011_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0012",
                description='literal square brackets and false-positive digit' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Photos [2023]',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0012_{suffix}" + '/Photos [2023]/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0012_{suffix}" + '/Photos 2/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0012_{suffix}" + '/Photos 3/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0012_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0012_{suffix}" + '/Photos 2/retained.txt',
                    f"ZZ_E2E_TC0012_SD0012_{suffix}" + '/Photos 3/retained.txt',
                    f"ZZ_E2E_TC0012_SD0012_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0012_{suffix}" + '/Photos [2023]/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0012_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0013",
                description='literal braces and false-positive quantifier' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Backup{1}',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0013_{suffix}" + '/Backup{1}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0013_{suffix}" + '/Backup/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0013_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0013_{suffix}" + '/Backup/retained.txt',
                    f"ZZ_E2E_TC0012_SD0013_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0013_{suffix}" + '/Backup{1}/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0013_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0014",
                description='literal braces and false-positive quantifier' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Backup{1}',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0014_{suffix}" + '/Backup{1}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0014_{suffix}" + '/Backup/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0014_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0014_{suffix}" + '/Backup/retained.txt',
                    f"ZZ_E2E_TC0012_SD0014_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0014_{suffix}" + '/Backup{1}/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0014_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0015",
                description='literal dollar anchor' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Budget$2026',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0015_{suffix}" + '/Budget$2026/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0015_{suffix}" + '/Budget/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0015_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0015_{suffix}" + '/Budget/retained.txt',
                    f"ZZ_E2E_TC0012_SD0015_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0015_{suffix}" + '/Budget$2026/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0015_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0016",
                description='literal dollar anchor' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Budget$2026',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0016_{suffix}" + '/Budget$2026/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0016_{suffix}" + '/Budget/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0016_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0016_{suffix}" + '/Budget/retained.txt',
                    f"ZZ_E2E_TC0012_SD0016_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0016_{suffix}" + '/Budget$2026/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0016_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0017",
                description='literal caret anchor' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Q^A',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0017_{suffix}" + '/Q^A/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0017_{suffix}" + '/QA/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0017_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0017_{suffix}" + '/QA/retained.txt',
                    f"ZZ_E2E_TC0012_SD0017_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0017_{suffix}" + '/Q^A/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0017_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0018",
                description='literal caret anchor' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Q^A',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0018_{suffix}" + '/Q^A/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0018_{suffix}" + '/QA/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0018_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0018_{suffix}" + '/QA/retained.txt',
                    f"ZZ_E2E_TC0012_SD0018_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0018_{suffix}" + '/Q^A/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0018_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0019",
                description='unbalanced opening bracket' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Draft [old',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0019_{suffix}" + '/Draft [old/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0019_{suffix}" + '/Draft old/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0019_{suffix}" + '/Draft old/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0019_{suffix}" + '/Draft [old/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0019_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0020",
                description='unbalanced opening bracket' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Draft [old',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0020_{suffix}" + '/Draft [old/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0020_{suffix}" + '/Draft old/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0020_{suffix}" + '/Draft old/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0020_{suffix}" + '/Draft [old/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0020_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0021",
                description='unbalanced opening brace' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Draft {old',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0021_{suffix}" + '/Draft {old/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0021_{suffix}" + '/Draft old/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0021_{suffix}" + '/Draft old/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0021_{suffix}" + '/Draft {old/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0021_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0022",
                description='unbalanced opening brace' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Draft {old',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0022_{suffix}" + '/Draft {old/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0022_{suffix}" + '/Draft old/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0022_{suffix}" + '/Draft old/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0022_{suffix}" + '/Draft {old/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0022_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0023",
                description='unbalanced closing bracket and brace' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Draft ]old}',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0023_{suffix}" + '/Draft ]old}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0023_{suffix}" + '/Draft old/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0023_{suffix}" + '/Draft old/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0023_{suffix}" + '/Draft ]old}/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0023_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0024",
                description='unbalanced closing bracket and brace' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Draft ]old}',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0024_{suffix}" + '/Draft ]old}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0024_{suffix}" + '/Draft old/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0024_{suffix}" + '/Draft old/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0024_{suffix}" + '/Draft ]old}/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0024_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0025",
                description='literal metacharacters with star wildcard and pipe alternatives' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('*[draft]*|Backup{1}|Budget$*',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Report [draft] v2/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Backup{1}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Budget$2026/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Report draft v2/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Backup/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Report draft v2/retained.txt',
                    f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Backup/retained.txt',
                    f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Report [draft] v2/blocked.txt',
                    f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Backup{1}/blocked.txt',
                    f"ZZ_E2E_TC0012_SD0025_{suffix}" + '/Budget$2026/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0025_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0026",
                description='literal metacharacters with star wildcard and pipe alternatives' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('*[draft]*|Backup{1}|Budget$*',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Report [draft] v2/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Backup{1}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Budget$2026/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Report draft v2/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Backup/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Keep/ok.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Report draft v2/retained.txt',
                    f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Backup/retained.txt',
                    f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Keep/ok.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Report [draft] v2/blocked.txt',
                    f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Backup{1}/blocked.txt',
                    f"ZZ_E2E_TC0012_SD0026_{suffix}" + '/Budget$2026/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0026_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0027",
                description='literal bracket in strict path' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=(f"ZZ_E2E_TC0012_SD0027_{suffix}" + '/Projects [2023]/Cache',),
                strict=True,
                files=(
                    (f"ZZ_E2E_TC0012_SD0027_{suffix}" + '/Projects [2023]/Cache/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0027_{suffix}" + '/Projects 2/Cache/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0027_{suffix}" + '/Elsewhere/Cache/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0027_{suffix}" + '/Projects 2/Cache/retained.txt',
                    f"ZZ_E2E_TC0012_SD0027_{suffix}" + '/Elsewhere/Cache/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0027_{suffix}" + '/Projects [2023]/Cache/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0027_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0028",
                description='literal bracket in strict path' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"ZZ_E2E_TC0012_SD0028_{suffix}" + '/Projects [2023]/Cache',),
                strict=True,
                files=(
                    (f"ZZ_E2E_TC0012_SD0028_{suffix}" + '/Projects [2023]/Cache/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0028_{suffix}" + '/Projects 2/Cache/retained.txt', 'keep\n'),
                    (f"ZZ_E2E_TC0012_SD0028_{suffix}" + '/Elsewhere/Cache/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0028_{suffix}" + '/Projects 2/Cache/retained.txt',
                    f"ZZ_E2E_TC0012_SD0028_{suffix}" + '/Elsewhere/Cache/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0028_{suffix}" + '/Projects [2023]/Cache/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0028_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0029",
                description='non-strict segment exclusion with bracket' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Cache [old]',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0029_{suffix}" + '/Nested/Cache [old]/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0029_{suffix}" + '/Nested/Cache old/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0029_{suffix}" + '/Nested/Cache old/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0029_{suffix}" + '/Nested/Cache [old]/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0029_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0030",
                description='non-strict segment exclusion with bracket' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Cache [old]',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0030_{suffix}" + '/Nested/Cache [old]/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0030_{suffix}" + '/Nested/Cache old/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0030_{suffix}" + '/Nested/Cache old/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0030_{suffix}" + '/Nested/Cache [old]/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0030_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0031",
                description='question mark wildcard with literal braces' + " (local to remote)",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=('Build?{1}',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0031_{suffix}" + '/BuildA{1}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0031_{suffix}" + '/BuildB{1}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0031_{suffix}" + '/BuildA/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0031_{suffix}" + '/BuildA/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0031_{suffix}" + '/BuildA{1}/blocked.txt',
                    f"ZZ_E2E_TC0012_SD0031_{suffix}" + '/BuildB{1}/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0031_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0032",
                description='question mark wildcard with literal braces' + " (remote to local)",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=('Build?{1}',),
                strict=False,
                files=(
                    (f"ZZ_E2E_TC0012_SD0032_{suffix}" + '/BuildA{1}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0032_{suffix}" + '/BuildB{1}/blocked.txt', 'blocked\n'),
                    (f"ZZ_E2E_TC0012_SD0032_{suffix}" + '/BuildA/retained.txt', 'keep\n'),
                ),
                expected_present=(
                    f"ZZ_E2E_TC0012_SD0032_{suffix}" + '/BuildA/retained.txt',
                ),
                expected_absent=(
                    f"ZZ_E2E_TC0012_SD0032_{suffix}" + '/BuildA{1}/blocked.txt',
                    f"ZZ_E2E_TC0012_SD0032_{suffix}" + '/BuildB{1}/blocked.txt',
                ),
                single_directory=f"ZZ_E2E_TC0012_SD0032_{suffix}",
            ),
            # Supported explicit rooted multi-component path matching; unlike
            # single-component non-strict rules, bare "App/Private" does not
            # match an arbitrary suffix of a longer path.
            SkipDirScenario(
                scenario_id="SD-0033", description="explicit sync-root multi-component directory path (upload)",
                direction=self.LOCAL_TO_REMOTE, skip_dir_entries=(f"/ZZ_E2E_TC0012_SD0033_{suffix}/App/Private",), strict=True,
                files=((f"ZZ_E2E_TC0012_SD0033_{suffix}/App/Private/no.txt", "skip\n"),
                       (f"ZZ_E2E_TC0012_SD0033_{suffix}/App/Public/yes.txt", "keep\n")),
                expected_present=(f"ZZ_E2E_TC0012_SD0033_{suffix}/App/Public/yes.txt",),
                expected_absent=(f"ZZ_E2E_TC0012_SD0033_{suffix}/App/Private/no.txt",),
                single_directory=f"ZZ_E2E_TC0012_SD0033_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0034", description="explicit sync-root multi-component directory path (download)",
                direction=self.REMOTE_TO_LOCAL, skip_dir_entries=(f"/ZZ_E2E_TC0012_SD0034_{suffix}/App/Private",), strict=True,
                files=((f"ZZ_E2E_TC0012_SD0034_{suffix}/App/Private/no.txt", "skip\n"),
                       (f"ZZ_E2E_TC0012_SD0034_{suffix}/App/Public/yes.txt", "keep\n")),
                expected_present=(f"ZZ_E2E_TC0012_SD0034_{suffix}/App/Public/yes.txt",),
                expected_absent=(f"ZZ_E2E_TC0012_SD0034_{suffix}/App/Private/no.txt",),
                single_directory=f"ZZ_E2E_TC0012_SD0034_{suffix}",
            ),
            SkipDirScenario(
                scenario_id="SD-0035", description="issues #2910/#1122 tracked directory newly excluded; preserve online data",
                direction=self.LOCAL_TO_REMOTE, skip_dir_entries=("Excluded",), strict=False,
                files=((f"ZZ_E2E_TC0012_SD0035_{suffix}/Excluded/tracked.txt", "must survive\n"),
                       (f"ZZ_E2E_TC0012_SD0035_{suffix}/Retained/sibling.txt", "must survive\n")),
                expected_present=(f"ZZ_E2E_TC0012_SD0035_{suffix}/Excluded/tracked.txt",
                                  f"ZZ_E2E_TC0012_SD0035_{suffix}/Retained/sibling.txt"),
                expected_absent=(), single_directory=f"ZZ_E2E_TC0012_SD0035_{suffix}",
                mode="tracked_exclusion",
            ),
            SkipDirScenario(
                scenario_id="SD-0036", description="issue #3475 reject .* in skip_dir before sync",
                direction=self.LOCAL_TO_REMOTE, skip_dir_entries=(".*|Archived Sites",), strict=False,
                files=((f"ZZ_E2E_TC0012_SD0036_{suffix}/keep.txt", "no upload\n"),),
                expected_present=(), expected_absent=(), mode="invalid_config",
            ),
        ]

    def _run_scenario(
        self,
        context: E2EContext,
        scenario: SkipDirScenario,
        *,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        if scenario.mode == "tracked_exclusion":
            return self._run_tracked_exclusion(
                context, scenario, scenario_work_dir=scenario_work_dir,
                scenario_log_dir=scenario_log_dir,
                scenario_state_dir=scenario_state_dir,
            )
        if scenario.mode == "invalid_config":
            return self._run_invalid_config(
                context, scenario, scenario_work_dir=scenario_work_dir,
                scenario_log_dir=scenario_log_dir,
                scenario_state_dir=scenario_state_dir,
            )
        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        subject_root = scenario_work_dir / "subject-syncroot"
        subject_conf = scenario_work_dir / "conf-subject"
        other_root = scenario_work_dir / "other-syncroot"
        other_conf = scenario_work_dir / "conf-other"

        reset_directory(subject_root)
        reset_directory(other_root)

        if scenario.direction == self.LOCAL_TO_REMOTE:
            source_root = subject_root
            source_conf = subject_conf
            result_root = other_root
            result_conf = other_conf
        elif scenario.direction == self.REMOTE_TO_LOCAL:
            source_root = other_root
            source_conf = other_conf
            result_root = subject_root
            result_conf = subject_conf
        else:
            raise ValueError(
                f"Unknown TC0012 scenario direction: {scenario.direction}"
            )

        for relative_path, file_content in scenario.files:
            write_text_file(source_root / relative_path, file_content)

        context.bootstrap_config_dir(subject_conf)
        self._write_config(
            subject_conf / "config",
            skip_dir_entries=scenario.skip_dir_entries,
            strict=scenario.strict,
            label=f"{scenario.scenario_id} subject",
        )

        context.bootstrap_config_dir(other_conf)
        self._write_config(
            other_conf / "config",
            label=f"{scenario.scenario_id} unfiltered",
        )

        phase1_stdout = scenario_log_dir / "phase1_source_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_source_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_result_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_result_stderr.log"
        result_manifest_file = scenario_state_dir / "result_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(result_manifest_file),
            str(metadata_file),
        ]

        # Phase 1 always seeds the remote side from the scenario's source
        # client. For local-to-remote scenarios this is the filtered subject
        # client; for remote-to-local scenarios this is the unfiltered client.
        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(source_root),
            "--confdir",
            str(source_conf),
        ]
        self._append_scope(phase1_command, scenario.single_directory)

        context.log(
            f"Executing Test Case {self.case_id} {scenario.scenario_id} "
            f"phase 1: {command_to_string(phase1_command)}"
        )
        phase1_result = run_command(
            phase1_command,
            cwd=context.repo_root,
        )
        write_text_file(phase1_stdout, phase1_result.stdout)
        write_text_file(phase1_stderr, phase1_result.stderr)

        # Phase 2 uses a fresh client to observe what phase 1 placed online.
        # For local-to-remote scenarios this is deliberately unfiltered so the
        # resulting manifest proves that the source-side skip_dir rule worked.
        # For remote-to-local scenarios this is the filtered subject client so
        # the remote JSON filtering path is exercised directly.
        phase2_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(result_root),
            "--confdir",
            str(result_conf),
        ]
        self._append_scope(phase2_command, scenario.single_directory)

        context.log(
            f"Executing Test Case {self.case_id} {scenario.scenario_id} "
            f"phase 2: {command_to_string(phase2_command)}"
        )
        phase2_result = run_command(
            phase2_command,
            cwd=context.repo_root,
        )
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)

        result_manifest = build_manifest(result_root)
        write_manifest(result_manifest_file, result_manifest)

        failures: list[str] = []

        if phase1_result.returncode != 0:
            failures.append(
                f"source phase failed with status {phase1_result.returncode}"
            )

        if phase2_result.returncode != 0:
            failures.append(
                f"result phase failed with status {phase2_result.returncode}"
            )

        if (
            phase1_result.returncode == 0
            and phase2_result.returncode == 0
        ):
            for expected in scenario.expected_present:
                if expected not in result_manifest:
                    failures.append(
                        f"expected included path is missing: {expected}"
                    )

            for unwanted in scenario.expected_absent:
                if unwanted in result_manifest:
                    failures.append(
                        f"expected skipped path is present: {unwanted}"
                    )

        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id,
            "description": scenario.description,
            "direction": scenario.direction,
            "skip_dir_entries": list(scenario.skip_dir_entries),
            "skip_dir_strict_match": scenario.strict,
            "single_directory": scenario.single_directory,
            "phase1_returncode": phase1_result.returncode,
            "phase2_returncode": phase2_result.returncode,
            "expected_present": list(scenario.expected_present),
            "expected_absent": list(scenario.expected_absent),
            "result_manifest": result_manifest,
            "failure_messages": failures,
        }
        self._write_metadata(metadata_file, details)

        return ScenarioResult(
            scenario_id=scenario.scenario_id,
            description=scenario.description,
            passed=not failures,
            failure_messages=failures,
            artifacts=artifacts,
            details=details,
        )

    def _run_tracked_exclusion(
        self, context: E2EContext, scenario: SkipDirScenario, *,
        scenario_work_dir: Path, scenario_log_dir: Path, scenario_state_dir: Path,
    ) -> ScenarioResult:
        """Verify required exit 78, then supported resync and online preservation.

        A skip_file/skip_dir configuration change must not be silently used
        with a pre-existing state database. This explicitly tests the refusal
        AND preserves all seeded remote fixture bytes after supported recovery.
        """
        for d in (scenario_work_dir, scenario_log_dir, scenario_state_dir):
            reset_directory(d)
        subject_root = scenario_work_dir / "subject-syncroot"
        subject_conf = scenario_work_dir / "conf-subject"
        reset_directory(subject_root)
        context.bootstrap_config_dir(subject_conf)
        self._write_config(subject_conf / "config", label="initial unfiltered tracked baseline")
        for rel, content in scenario.files:
            write_text_file(subject_root / rel, content)

        artifacts: list[str] = []
        commands: list[dict[str, object]] = []
        failures: list[str] = []
        expected_contents = dict(scenario.files)
        snapshots: dict[str, list[str]] = {}

        def execute(label: str, root: Path, conf: Path, args: list[str], *, expected_rc: int = 0) -> str:
            command = [context.onedrive_bin, "--sync", "--verbose", *args,
                       "--syncdir", str(root), "--confdir", str(conf)]
            self._append_scope(command, scenario.single_directory)
            result = run_command(command, cwd=context.repo_root)
            out = scenario_log_dir / f"{label}_stdout.log"
            err = scenario_log_dir / f"{label}_stderr.log"
            write_text_file(out, result.stdout)
            write_text_file(err, result.stderr)
            artifacts.extend((str(out), str(err)))
            commands.append({"phase": label, "command": command_to_string(command),
                             "returncode": result.returncode, "expected_returncode": expected_rc})
            if result.returncode != expected_rc:
                failures.append(f"{label} returned {result.returncode}, expected {expected_rc}")
            return result.stdout + "\n" + result.stderr

        def independently_verify(label: str) -> None:
            if failures:
                return
            # Fresh verifier state avoids accidentally relying on a prior delta
            # cursor/database rather than checking authoritative remote objects.
            root = scenario_work_dir / f"{label}-syncroot"
            conf = scenario_work_dir / f"{label}-conf"
            reset_directory(root)
            context.bootstrap_config_dir(conf)
            self._write_config(conf / "config", label=f"{label} unfiltered verification")
            execute(label, root, conf, ["--download-only", "--resync", "--resync-auth"])
            manifest = build_manifest(root)
            snapshots[label] = sorted(manifest)
            path = scenario_state_dir / f"{label}_manifest.txt"
            write_manifest(path, manifest)
            artifacts.append(str(path))
            if failures:
                return
            for rel, data in expected_contents.items():
                if rel not in manifest:
                    failures.append(f"{label}: expected remotely preserved path absent: {rel}")
                elif (root / rel).read_bytes() != data.encode("utf-8"):
                    failures.append(f"{label}: remote file bytes changed: {rel}")
            for unwanted in scenario.expected_absent:
                if unwanted in manifest:
                    failures.append(f"{label}: unexpected remote object: {unwanted}")

        execute("01_seed_tracked_remote", subject_root, subject_conf,
                ["--upload-only", "--resync", "--resync-auth"])
        independently_verify("02_remote_baseline")
        if not failures:
            self._write_config(subject_conf / "config", skip_dir_entries=scenario.skip_dir_entries,
                               strict=scenario.strict, label="newly excluded tracked object")
            refused_output = execute("03_configuration_change_refused", subject_root, subject_conf,
                                     [], expected_rc=78)
            if "resync" not in refused_output.lower():
                failures.append("exit 78 without a resync-required diagnostic")
        independently_verify("04_remote_after_refusal")
        if not failures:
            execute("05_supported_resync", subject_root, subject_conf,
                    ["--resync", "--resync-auth"])
        if not failures:
            execute("06_followup_reconciliation", subject_root, subject_conf, [])
        independently_verify("07_remote_after_recovery")

        if not failures and snapshots.get("02_remote_baseline") != snapshots.get("07_remote_after_recovery"):
            failures.append("remote manifest changed during filtering configuration transition")
        subject_manifest = build_manifest(subject_root)
        path = scenario_state_dir / "subject_manifest.txt"
        write_manifest(path, subject_manifest)
        artifacts.append(str(path))
        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id, "mode": scenario.mode,
            "description": scenario.description, "commands": commands,
            "expected_remote_present": list(scenario.expected_present),
            "remote_manifests": snapshots, "subject_manifest": subject_manifest,
            "failure_messages": failures,
        }
        metadata = scenario_state_dir / "metadata.txt"
        self._write_metadata(metadata, details)
        artifacts.append(str(metadata))
        return ScenarioResult(scenario.scenario_id, scenario.description, not failures,
                              failures, artifacts, details)

    def _run_invalid_config(
        self, context: E2EContext, scenario: SkipDirScenario, *,
        scenario_work_dir: Path, scenario_log_dir: Path, scenario_state_dir: Path,
    ) -> ScenarioResult:
        """Reject an invalid rule before synchronisation; do not seed/delete remote data."""
        for d in (scenario_work_dir, scenario_log_dir, scenario_state_dir):
            reset_directory(d)
        syncroot = scenario_work_dir / "subject-syncroot"
        conf = scenario_work_dir / "conf-subject"
        reset_directory(syncroot)
        context.bootstrap_config_dir(conf)
        self._write_config(conf / "config", skip_dir_entries=scenario.skip_dir_entries,
                           strict=scenario.strict, label="invalid pattern must fail closed")
        # An otherwise valid local fixture makes an accidental sync observable
        # without introducing any destructive remote test data.
        fixture = scenario.files[0][0]
        write_text_file(syncroot / fixture, scenario.files[0][1])
        command = [context.onedrive_bin, "--sync", "--upload-only", "--verbose",
                   "--syncdir", str(syncroot), "--confdir", str(conf)]
        result = run_command(command, cwd=context.repo_root)
        stdout = scenario_log_dir / "rejected_stdout.log"
        stderr = scenario_log_dir / "rejected_stderr.log"
        write_text_file(stdout, result.stdout)
        write_text_file(stderr, result.stderr)
        output = result.stdout + "\n" + result.stderr
        option = "skip_file" if self.case_id == "0011" else "skip_dir"
        failures = []
        if result.returncode == 0:
            failures.append("invalid configuration was accepted (exit status 0)")
        if f"Invalid {option} entry" not in output:
            failures.append(f"missing expected Invalid {option} entry diagnostic")
        # Stronger invariant: startup validation must reject before Graph work.
        if "Attempting to contact the Microsoft OneDrive Service" in output or                 "Fetching items from the OneDrive API" in output or                 "Uploading file:" in output:
            failures.append("client started online processing despite invalid configuration")
        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id, "mode": scenario.mode,
            "returncode": result.returncode, "failure_messages": failures,
        }
        metadata = scenario_state_dir / "metadata.txt"
        self._write_metadata(metadata, details)
        return ScenarioResult(scenario.scenario_id, scenario.description, not failures,
                              failures, [str(stdout), str(stderr), str(metadata)], details)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name=f"tc{self.case_id}",
            ensure_refresh_token=True,
        )

        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        suffix = f"{context.run_id}_{os.getpid()}"

        scenarios = [
            scenario
            for scenario in self._build_scenarios(suffix)
            if context.should_run_scenario(
                self.case_id,
                scenario.scenario_id,
            )
        ]

        results: list[ScenarioResult] = []

        for scenario in scenarios:
            scenario_dir_name = (
                scenario.scenario_id.lower().replace("-", "")
            )

            results.append(
                self._run_scenario(
                    context,
                    scenario,
                    scenario_work_dir=(
                        case_work_dir / scenario_dir_name
                    ),
                    scenario_log_dir=(
                        case_log_dir / scenario_dir_name
                    ),
                    scenario_state_dir=(
                        state_dir / scenario_dir_name
                    ),
                )
            )

        all_artifacts: list[str] = []
        details: dict[str, object] = {
            "executed_scenario_ids": [
                result.scenario_id for result in results
            ],
        }
        failed_results: list[ScenarioResult] = []

        summary_lines: list[str] = []

        for result in results:
            all_artifacts.extend(result.artifacts)
            details[result.scenario_id] = result.details

            if result.passed:
                summary_lines.append(
                    f"{result.scenario_id} [PASS] {result.description}"
                )
            else:
                failed_results.append(result)
                summary_lines.append(
                    f"{result.scenario_id} [FAIL] {result.description} — "
                    + "; ".join(result.failure_messages)
                )

        summary_file = state_dir / "scenario_summary.txt"
        write_text_file(
            summary_file,
            "\n".join(summary_lines)
            + ("\n" if summary_lines else ""),
        )
        all_artifacts.append(str(summary_file))

        details["failed_scenario_ids"] = [
            result.scenario_id for result in failed_results
        ]

        metadata_file = state_dir / "metadata.txt"
        self._write_metadata(metadata_file, details)
        all_artifacts.append(str(metadata_file))

        deduped_artifacts: list[str] = []
        seen: set[str] = set()

        for artifact in all_artifacts:
            if artifact not in seen:
                deduped_artifacts.append(artifact)
                seen.add(artifact)

        if failed_results:
            failure_text = "; ".join(
                f"{result.scenario_id}: "
                + ", ".join(result.failure_messages)
                for result in failed_results
            )

            return self.fail_result(
                self.case_id,
                self.name,
                (
                    f"{len(failed_results)} of {len(results)} "
                    f"filtering scenarios failed — {failure_text}"
                ),
                deduped_artifacts,
                details,
            )

        return self.pass_result(
            self.case_id,
            self.name,
            deduped_artifacts,
            details,
        )
