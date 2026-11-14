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
