from __future__ import annotations

# Use the established two-client E2E executor from TC0012. Both test cases
# exercise the same upload/download contract but configure different masks.
from pathlib import Path

from framework.utils import write_onedrive_config
from testcases.tc0012_skip_dir_validation import SkipDirScenario, TestCase0012SkipDirValidation


class TestCase0011SkipFileValidation(TestCase0012SkipDirValidation):
    case_id = "0011"
    name = "skip_file validation"
    description = "Bidirectional skip_file regression scenarios, including literal regex metacharacters"

    def _write_config(
        self,
        config_path: Path,
        *,
        skip_dir_entries: tuple[str, ...] = (),
        strict: bool = False,
        label: str,
    ) -> None:
        # The inherited executor passes scenario patterns through this argument;
        # TC0011 uses them as skip_file masks, never skip_dir masks.
        lines = [f"# tc0011 {label} config", 'bypass_data_preservation = "true"']
        if skip_dir_entries:
            lines.append(f'skip_file = "{"|".join(skip_dir_entries)}"')
        write_onedrive_config(config_path, "\n".join(lines) + "\n")

    def _build_scenarios(self, suffix: str) -> list[SkipDirScenario]:
        # skip_file supports filename masks anywhere (e.g. blah.txt, *.txt),
        # or an exact path relative to sync_dir, rooted with '/' (e.g.
        # /Documents [2023]/blocked.txt). The latter slash is NOT the host
        # filesystem root. Both upload and download must honour this contract.

        scenarios: list[SkipDirScenario] = []
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0001",
            description='legacy extension exclusion' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('*.tmp|*.swp',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0001_{suffix}" + '/keep.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0001_{suffix}" + '/skip.tmp', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0001_{suffix}" + '/editor.swp', 'skip\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0001_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0001_{suffix}" + '/skip.tmp',
                f"ZZ_E2E_TC0011_SF0001_{suffix}" + '/editor.swp',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0001_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0002",
            description='legacy extension exclusion' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('*.tmp|*.swp',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0002_{suffix}" + '/keep.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0002_{suffix}" + '/skip.tmp', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0002_{suffix}" + '/editor.swp', 'skip\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0002_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0002_{suffix}" + '/skip.tmp',
                f"ZZ_E2E_TC0011_SF0002_{suffix}" + '/editor.swp',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0002_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0003",
            description='square brackets literal and false-positive character-class' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('Report [2023].txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0003_{suffix}" + '/Report [2023].txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0003_{suffix}" + '/Report 2.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0003_{suffix}" + '/Report 3.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0003_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0003_{suffix}" + '/Report 2.txt',
                f"ZZ_E2E_TC0011_SF0003_{suffix}" + '/Report 3.txt',
                f"ZZ_E2E_TC0011_SF0003_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0003_{suffix}" + '/Report [2023].txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0003_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0004",
            description='square brackets literal and false-positive character-class' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('Report [2023].txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0004_{suffix}" + '/Report [2023].txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0004_{suffix}" + '/Report 2.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0004_{suffix}" + '/Report 3.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0004_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0004_{suffix}" + '/Report 2.txt',
                f"ZZ_E2E_TC0011_SF0004_{suffix}" + '/Report 3.txt',
                f"ZZ_E2E_TC0011_SF0004_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0004_{suffix}" + '/Report [2023].txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0004_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0005",
            description='braces literal and false-positive quantifier' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('Backup{1}.txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0005_{suffix}" + '/Backup{1}.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0005_{suffix}" + '/Backup.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0005_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0005_{suffix}" + '/Backup.txt',
                f"ZZ_E2E_TC0011_SF0005_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0005_{suffix}" + '/Backup{1}.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0005_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0006",
            description='braces literal and false-positive quantifier' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('Backup{1}.txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0006_{suffix}" + '/Backup{1}.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0006_{suffix}" + '/Backup.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0006_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0006_{suffix}" + '/Backup.txt',
                f"ZZ_E2E_TC0011_SF0006_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0006_{suffix}" + '/Backup{1}.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0006_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0007",
            description='literal dollar anchor in valid names' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('Budget$*',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0007_{suffix}" + '/Budget$2026.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0007_{suffix}" + '/BudgetReport.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0007_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0007_{suffix}" + '/BudgetReport.txt',
                f"ZZ_E2E_TC0011_SF0007_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0007_{suffix}" + '/Budget$2026.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0007_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0008",
            description='literal dollar anchor in valid names' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('Budget$*',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0008_{suffix}" + '/Budget$2026.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0008_{suffix}" + '/BudgetReport.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0008_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0008_{suffix}" + '/BudgetReport.txt',
                f"ZZ_E2E_TC0011_SF0008_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0008_{suffix}" + '/Budget$2026.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0008_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0009",
            description='literal caret anchor' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('a^b.txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0009_{suffix}" + '/a^b.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0009_{suffix}" + '/ab.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0009_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0009_{suffix}" + '/ab.txt',
                f"ZZ_E2E_TC0011_SF0009_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0009_{suffix}" + '/a^b.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0009_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0010",
            description='literal caret anchor' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('a^b.txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0010_{suffix}" + '/a^b.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0010_{suffix}" + '/ab.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0010_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0010_{suffix}" + '/ab.txt',
                f"ZZ_E2E_TC0011_SF0010_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0010_{suffix}" + '/a^b.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0010_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0011",
            description='unbalanced opening square bracket' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('Draft [old',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0011_{suffix}" + '/Draft [old', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0011_{suffix}" + '/Draft old', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0011_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0011_{suffix}" + '/Draft old',
                f"ZZ_E2E_TC0011_SF0011_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0011_{suffix}" + '/Draft [old',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0011_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0012",
            description='unbalanced opening square bracket' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('Draft [old',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0012_{suffix}" + '/Draft [old', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0012_{suffix}" + '/Draft old', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0012_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0012_{suffix}" + '/Draft old',
                f"ZZ_E2E_TC0011_SF0012_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0012_{suffix}" + '/Draft [old',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0012_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0013",
            description='unbalanced opening brace' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('Draft {old',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0013_{suffix}" + '/Draft {old', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0013_{suffix}" + '/Draft old', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0013_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0013_{suffix}" + '/Draft old',
                f"ZZ_E2E_TC0011_SF0013_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0013_{suffix}" + '/Draft {old',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0013_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0014",
            description='unbalanced opening brace' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('Draft {old',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0014_{suffix}" + '/Draft {old', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0014_{suffix}" + '/Draft old', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0014_{suffix}" + '/keep.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0014_{suffix}" + '/Draft old',
                f"ZZ_E2E_TC0011_SF0014_{suffix}" + '/keep.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0014_{suffix}" + '/Draft {old',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0014_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0015",
            description='unbalanced closing bracket and brace' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('Draft ]old}',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0015_{suffix}" + '/Draft ]old}', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0015_{suffix}" + '/Draft old', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0015_{suffix}" + '/Draft old',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0015_{suffix}" + '/Draft ]old}',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0015_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0016",
            description='unbalanced closing bracket and brace' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('Draft ]old}',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0016_{suffix}" + '/Draft ]old}', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0016_{suffix}" + '/Draft old', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0016_{suffix}" + '/Draft old',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0016_{suffix}" + '/Draft ]old}',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0016_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0017",
            description='multiple rules with wildcard and literals' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('*[draft]*|Backup{1}.txt|Budget$*',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Report [draft] v2.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Backup{1}.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Budget$2026.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Report draft v2.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Backup.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Report draft v2.txt',
                f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Backup.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Report [draft] v2.txt',
                f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Backup{1}.txt',
                f"ZZ_E2E_TC0011_SF0017_{suffix}" + '/Budget$2026.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0017_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0018",
            description='multiple rules with wildcard and literals' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('*[draft]*|Backup{1}.txt|Budget$*',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Report [draft] v2.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Backup{1}.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Budget$2026.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Report draft v2.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Backup.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Report draft v2.txt',
                f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Backup.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Report [draft] v2.txt',
                f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Backup{1}.txt',
                f"ZZ_E2E_TC0011_SF0018_{suffix}" + '/Budget$2026.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0018_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0019",
            description='question wildcard and literal brace' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('file?{1}.txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0019_{suffix}" + '/fileA{1}.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0019_{suffix}" + '/fileB{1}.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0019_{suffix}" + '/fileA.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0019_{suffix}" + '/fileA.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0019_{suffix}" + '/fileA{1}.txt',
                f"ZZ_E2E_TC0011_SF0019_{suffix}" + '/fileB{1}.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0019_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0020",
            description='question wildcard and literal brace' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('file?{1}.txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0020_{suffix}" + '/fileA{1}.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0020_{suffix}" + '/fileB{1}.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0020_{suffix}" + '/fileA.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0020_{suffix}" + '/fileA.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0020_{suffix}" + '/fileA{1}.txt',
                f"ZZ_E2E_TC0011_SF0020_{suffix}" + '/fileB{1}.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0020_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0021",
            description='case-insensitive matching and literal metacharacters' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=('REPORT [Q4].TXT',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0021_{suffix}" + '/report [q4].txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0021_{suffix}" + '/report q.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0021_{suffix}" + '/report q.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0021_{suffix}" + '/report [q4].txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0021_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0022",
            description='case-insensitive matching and literal metacharacters' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=('REPORT [Q4].TXT',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0022_{suffix}" + '/report [q4].txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0022_{suffix}" + '/report q.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0022_{suffix}" + '/report q.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0022_{suffix}" + '/report [q4].txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0022_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0023",
            description='sync-root anchored full path rule with literal brackets' + " (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=(f"/ZZ_E2E_TC0011_SF0023_{suffix}" + '/Documents [2023]/blocked.txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0023_{suffix}" + '/Documents [2023]/blocked.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0023_{suffix}" + '/Elsewhere/blocked.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0023_{suffix}" + '/Documents 2/blocked.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0023_{suffix}" + '/Elsewhere/blocked.txt',
                f"ZZ_E2E_TC0011_SF0023_{suffix}" + '/Documents 2/blocked.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0023_{suffix}" + '/Documents [2023]/blocked.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0023_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0024",
            description='sync-root anchored full path rule with literal brackets' + " (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=(f"/ZZ_E2E_TC0011_SF0024_{suffix}" + '/Documents [2023]/blocked.txt',),
            strict=False,
            files=(
                (f"ZZ_E2E_TC0011_SF0024_{suffix}" + '/Documents [2023]/blocked.txt', 'skip\n'),
                (f"ZZ_E2E_TC0011_SF0024_{suffix}" + '/Elsewhere/blocked.txt', 'keep\n'),
                (f"ZZ_E2E_TC0011_SF0024_{suffix}" + '/Documents 2/blocked.txt', 'keep\n'),
            ),
            expected_present=(
                f"ZZ_E2E_TC0011_SF0024_{suffix}" + '/Elsewhere/blocked.txt',
                f"ZZ_E2E_TC0011_SF0024_{suffix}" + '/Documents 2/blocked.txt',
            ),
            expected_absent=(
                f"ZZ_E2E_TC0011_SF0024_{suffix}" + '/Documents [2023]/blocked.txt',
            ),
            single_directory=f"ZZ_E2E_TC0011_SF0024_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0025",
            description="Office owner-file exclusion pattern parses without failure (local to remote)",
            direction=self.LOCAL_TO_REMOTE,
            skip_dir_entries=("~$*|*.tmp",),
            strict=False,
            files=((f"ZZ_E2E_TC0011_SF0025_{suffix}/keep.txt", "keep\n"), (f"ZZ_E2E_TC0011_SF0025_{suffix}/skip.tmp", "skip\n")),
            expected_present=(f"ZZ_E2E_TC0011_SF0025_{suffix}/keep.txt",),
            expected_absent=(f"ZZ_E2E_TC0011_SF0025_{suffix}/skip.tmp",),
            single_directory=f"ZZ_E2E_TC0011_SF0025_{suffix}",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0026",
            description="Office owner-file exclusion pattern parses without failure (remote to local)",
            direction=self.REMOTE_TO_LOCAL,
            skip_dir_entries=("~$*|*.tmp",),
            strict=False,
            files=((f"ZZ_E2E_TC0011_SF0026_{suffix}/keep.txt", "keep\n"), (f"ZZ_E2E_TC0011_SF0026_{suffix}/skip.tmp", "skip\n")),
            expected_present=(f"ZZ_E2E_TC0011_SF0026_{suffix}/keep.txt",),
            expected_absent=(f"ZZ_E2E_TC0011_SF0026_{suffix}/skip.tmp",),
            single_directory=f"ZZ_E2E_TC0011_SF0026_{suffix}",
        ))
        for number, direction in ((27, self.LOCAL_TO_REMOTE), (28, self.REMOTE_TO_LOCAL)):
            root = f"ZZ_E2E_TC0011_SF{number:04d}_{suffix}"
            scenarios.append(SkipDirScenario(
                scenario_id=f"SF-{number:04d}",
                description="issue #52 filename containing spaces with rooted exclusion",
                direction=direction,
                skip_dir_entries=(f"/{root}/My Documents/private report.txt",),
                strict=False,
                files=((f"{root}/My Documents/private report.txt", "skip\n"),
                       (f"{root}/Other/private report.txt", "keep\n"),
                       (f"{root}/My Documents/public report.txt", "keep\n")),
                expected_present=(f"{root}/Other/private report.txt",
                                  f"{root}/My Documents/public report.txt"),
                expected_absent=(f"{root}/My Documents/private report.txt",),
                single_directory=root,
            ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0029", description="tracked file newly excluded must not delete remote item",
            direction=self.LOCAL_TO_REMOTE, skip_dir_entries=("tracked.tmp",), strict=False,
            files=((f"ZZ_E2E_TC0011_SF0029_{suffix}/tracked.tmp", "remote preserve\n"),
                   (f"ZZ_E2E_TC0011_SF0029_{suffix}/retained.txt", "remote preserve\n")),
            expected_present=(f"ZZ_E2E_TC0011_SF0029_{suffix}/tracked.tmp",
                              f"ZZ_E2E_TC0011_SF0029_{suffix}/retained.txt"),
            expected_absent=(), single_directory=f"ZZ_E2E_TC0011_SF0029_{suffix}",
            mode="tracked_exclusion",
        ))
        scenarios.append(SkipDirScenario(
            scenario_id="SF-0030", description="reject .* in skip_file before sync",
            direction=self.LOCAL_TO_REMOTE, skip_dir_entries=(".*",), strict=False,
            files=((f"ZZ_E2E_TC0011_SF0030_{suffix}/keep.txt", "no upload\n"),),
            expected_present=(), expected_absent=(), mode="invalid_config",
        ))
        return scenarios
