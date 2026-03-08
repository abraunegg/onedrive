# End to End Testing of OneDrive Client for Linux

Placeholder document that will detail all test cases and coverage

| Test Case | Description | Details |
|---|---|---|
| 0001 | Basic Resync | - validate that the E2E framework can invoke the client\n- validate that the configured environment is sufficient to run a basic sync\n- provide a simple baseline smoke test before more advanced E2E scenarios |
| 0002 | 'sync_list' Validation | This validates sync_list as a policy-conformance test.\n\n The test is considered successful when all observed sync operations involving the fixture tree match the active sync_list rules.\n\nThis test covers exclusions, inclusions, wildcard and globbing for paths and files |