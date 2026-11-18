# E2E automatic failure rerun support

This folder now supports a two-pass CI model:

1. Run the primary E2E suite normally using `ci/e2e/run.py`
2. Parse `results.json` and automatically rerun only failed cases/scenarios with debug enabled using `ci/e2e/rerun_failures.py`

## TC0002 — `sync_list` rule-processing contract

TC0002's **primary objective** is to establish that the client reads and applies
**the exact rules in each scenario's `sync_list`, in their declared order**, and
selects the included files/directories while excluding the specified paths.
This covers precedence, rooted versus unrooted rules, ancestors needed for
included descendants, wildcard matching, trailing slashes, and combinations
of inclusion and exclusion. The configured rules and each scenario's expected
path-level outcomes define the contract, not the presence or absence of a
particular resync flag.

The TC0002 command intentionally includes `--resync --resync-auth` to provide a
reproducible evaluation baseline. **Do not audit TC0002 as a database-lifecycle
or resync-required test.** Other tests cover persistent-database transitions.
The `--download-only --cleanup-local-files` scenarios additionally validate
that the same selection decisions preserve out-of-scope local data and remove
eligible in-scope local-only data where explicitly expected. `sync_list` is a
selection profile, not a general local-file retention override.

Evidence depends on the scenario mode:

- **Single pass:** compare the client's actual include/process/skip events with
  the scenario's exact expected and forbidden paths. These decisions validate
  rule processing; they do **not** independently verify remote file contents.
- **Cleanup regression:** run an unrestricted seed followed by restricted
  cleanup, compare before/after local manifests and expected removal/retention
  decisions. Issue [#3655](https://github.com/abraunegg/onedrive/issues/3655)
  is a relevant trailing-slash regression.
- **Root-file contract:** run upload and fresh-download checks with
  `sync_root_files` both enabled and disabled.

When auditing TC0002, inspect **every scenario**: ordered rule text, intended
selection, actual command and effective configuration, emitted decisions, and
whatever local/remote outcome that scenario really asserts. Do not equate a
zero exit or matching log with a remote readback that was not performed.
Historical `sync_list` issues also include [#3931](https://github.com/abraunegg/onedrive/issues/3931)
for shared-folder inclusion/exclusion ordering.

## TC0019 — option incompatibility and startup validation

TC0019 preserves the existing real logging and runtime-config synchronisation
scenario (`OC-0001`) and additionally stress-tests
`ApplicationConfig.checkForBasicOptionConflicts()` using isolated per-scenario
configurations (`OC-0002` onward). Three invalid configurations are deliberately
rejected by the config parser *before* the basic-conflict checker (OC-0002,
OC-0004 and OC-0034); these are explicitly marked as parser-stage tests.
The new checks cover invalid permissions,
conflicting operation modes, resync/query combinations, missing option
prerequisites, invalid argument values, the #3970 `mirror_local_state` rules,
CLI/config-file precedence, multi-error diagnostics, and accepted controls.
CLI-only commands are passed on the command line; they are not written as
unsupported config-file keys. OC-0033 confirms that an empty configured
`log_dir` falls back to the default instead of being rejected.

The option-validation scenarios execute the real client with
`--display-running-config --dry-run --logout`; unlike `--display-config`,
`--display-running-config` does not bypass option validation. The dry-run logout
provides a safe, successful early-exit path for positive controls. These
scenarios must not perform Microsoft Graph operations or modify the test's
local canary or protected config/database state. Each rejection must return
`EXIT_FAILURE` (`1`) with its **specific expected diagnostic**; an unrelated
error or resync-required exit (`78`) is not accepted. Validator-stage cases
require effective-option output; parser-stage rejection cases must terminate
before that display, with their actual parser diagnostic. OC-0033 is an
accepted parser-normalisation control (exit `0`), not a rejection.

Per-scenario stdout/stderr and a machine-readable result matrix are preserved
under `logs/tc0019/option_conflicts` and `state/tc0019/option_conflicts.json`.
The `failed_scenario_ids` and `executed_scenario_ids` results support targeted
automatic debug reruns. For example:

```bash
python3 -u ci/e2e/run.py --case-id 0019 \
  --scenario 0019:OC-0054,OC-0059,OC-0064 \
  --debug --output-subdir tc0019-options-debug
```

TC0019 checks that valid `local_first + mirror_local_state` configuration is
**accepted**; actual remote-only deletion functionality remains covered by
TC0064. This is distinct from TC0088, which validates mandatory resync
transitions and exit status `78` rather than incompatible startup options.

## Primary run

```bash
python3 -u ci/e2e/run.py
```

## Automatic debug rerun

```bash
python3 -u ci/e2e/rerun_failures.py   --results ci/e2e/out/results.json   --output-subdir debug-rerun   --run-label debug-rerun
```

This will:
- read the failed cases from the primary `results.json`
- narrow the rerun to only failed case IDs
- narrow scenario-based cases to only failed scenario IDs when available
- rerun with debug verbosity enabled
- write rerun outputs into `ci/e2e/out/debug-rerun/`

## Direct filtered reruns

### Rerun one case

```bash
python3 -u ci/e2e/run.py --case-id 0024 --debug --output-subdir tc0024-debug
```

### Rerun multiple cases

```bash
python3 -u ci/e2e/run.py --case-id 0002,0021,0024 --debug --output-subdir targeted-debug
```

### Rerun only selected scenarios

```bash
python3 -u ci/e2e/run.py   --case-id 0002,0021   --scenario 0002:SL-0004,SL-0018   --scenario 0021:RT-0001   --debug   --output-subdir targeted-scenarios-debug
```

## Environment-driven controls

These are also supported if you prefer using workflow env vars:
- `E2E_DEBUG=1`
- `E2E_OUTPUT_SUBDIR=<subdir>`
- `E2E_RUN_LABEL=<label>`
- `E2E_SKIP_SUITE_CLEANUP=1`
- `E2E_SELECTED_CASES=0002,0021`
- `E2E_SELECTED_SCENARIOS_JSON={"0002": ["SL-0004"], "0021": ["RT-0001"]}`

## CI artifact credential boundary

The GitHub E2E workflows upload `ci/e2e/out` for diagnostics. Authentication
configuration directories, including every `refresh_token`, must remain in the
private runner work tree (`E2EContext.work_root`) and must **never** be created
beneath `ci/e2e/out`. The final `artifact_safety.py` check runs even if the test
suite fails. If a refresh token or symbolic link is found in the artifact tree,
the upload is blocked; the workflow also explicitly excludes `refresh_token`
filenames as a separate safeguard. Do not add a test that writes authentication
files under the published logs/state directories.
