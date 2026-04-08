# E2E automatic failure rerun support

This folder now supports a two-pass CI model:

1. Run the primary E2E suite normally using `ci/e2e/run.py`
2. Parse `results.json` and automatically rerun only failed cases/scenarios with debug enabled using `ci/e2e/rerun_failures.py`

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
