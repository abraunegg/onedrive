# Instructions for AI Coding Agents

This file applies to the entire `abraunegg/onedrive` repository. It supplements, rather than replaces, the project's maintainer instructions and technical documentation. Follow the existing source code and documentation when investigating behaviour; do not assume that generic OneDrive, D language, or AI-generated patterns reflect this client's implementation.

## Read before making changes

1. **[`docs/contributing.md`](docs/contributing.md)** — mandatory coding style, compiler expectations, documentation and pull request evidence requirements.
2. **[`docs/client-architecture.md`](docs/client-architecture.md)** — synchronisation architecture and state reconciliation; read before changing core client behaviour.
3. **[`docs/end_to_end_testing.md`](docs/end_to_end_testing.md)** — authoritative description of the E2E testing strategy, scenarios and account coverage.
4. Relevant documentation under `docs/`, existing tests under `ci/e2e/`, and existing implementations in `src/` before proposing a change.

If these sources conflict or the intended behaviour is unclear, document the uncertainty and request maintainer guidance rather than inventing a new policy.

## Repository and technology

- The application is a **D-language Linux OneDrive synchronisation client**. Python in `ci/e2e/` is the end-to-end test harness, **not** the application implementation language.
- `src/` contains the client implementation; `ci/e2e/` contains the Python E2E framework and scenarios; `docs/` contains user, architecture, contribution and test documentation; `.github/workflows/` contains CI workflows.
- The project uses Autotools/configure and Make for builds, libcurl for network communication, SQLite for synchronisation state, and Microsoft Graph and Microsoft identity services for remote access and authentication.
- Respect the existing build and packaging mechanisms. Do not introduce a new dependency, test framework, build system or runtime requirement merely because it is conventional elsewhere.

## Mandatory engineering principles

### Protect user data and synchronisation correctness

- Synchronisation is **reconciliation**, not a simple file-copy operation. Distinguish (1) remote OneDrive state, (2) the local SQLite synchronisation baseline, and (3) the live local filesystem. These are not interchangeable.
- Never advance database state as though a filesystem or remote operation succeeded when it did not. Preserve item identity, parent/drive relationships, delta cursor semantics and recovery across interrupted operations.
- Examine both upload and download directions, local and remote deletions, rename/move handling, collisions, conflicts, retries and restart behaviour before changing related code.
- Do not silently change the meaning of configuration options, skip/filter patterns, default behaviour or error handling. A refactor must preserve existing observable semantics unless a behavioural change is explicitly intended and documented.
- Do not replace existing safeguards with a simpler algorithm without establishing why those safeguards exist, including historical issue fixes.

### Consider every relevant execution context

- Consider `--sync` and the repeated lifecycle of `--monitor`; monitor-mode changes must account for notification handling, filesystem events, cleanup, repeated scans and long-running resource use.
- Consider the modes and options affected by the change, including upload-only, download-only, dry-run, local-first, single-directory, shared folders, Personal, Business and SharePoint as applicable.
- Changes involving network responses must preserve operation-specific handling for authentication, throttling, conflicts, preconditions, missing remote items and transient failures. Do not generalise distinct HTTP errors into one recovery path without evidence.
- Avoid changes that introduce data loss, unnecessary re-upload/re-download, database drift or unbounded memory growth.

### Follow established code and documentation conventions

- Follow **`docs/contributing.md`**: existing tab indentation, 1TBS braces (including single-statement blocks), naming conventions and **British English** spelling in comments and documentation.
- Comment **why** non-obvious logic exists, not just what individual statements do; retain relevant issue references and historical explanations.
- Do not modify application logging text, severity, notification channels or output formats without discussing the change with the maintainer first, as required by the contribution guidelines.
- Update the appropriate user documentation, configuration guidance, man page and related examples when observable behaviour changes.
- Keep changes narrowly scoped. Avoid unrelated rewrites, formatting churn, speculative optimisations and mass-renaming.

## Testing policy — E2E coverage is required

**Do not add D `unittest` blocks, standalone unit-test code, mock-based unit tests, or a new unit-testing framework to this repository.** The project uses its established Python-based E2E framework under `ci/e2e/` to validate real client behaviour against Microsoft OneDrive. For bug fixes or changes affecting synchronisation behaviour, agents **must assess and implement appropriate E2E coverage** as part of the proposed change. Compilation checks do not replace E2E validation.

1. **Inspect existing E2E cases first.** Consult `docs/end_to_end_testing.md` and `ci/e2e/` to locate scenarios exercising the affected functionality and identify the relevant test suites.
2. **Extend the existing framework.** Where behaviour is changed or a regression is fixed, add a focused regression scenario or extend an existing case using the established E2E conventions. Test actual client operations and outcomes, rather than only the return value of a mocked function.
3. **Test before and after where possible.** Demonstrate how the existing implementation fails the regression scenario and how the proposed fix succeeds. Validate positive and negative controls, both sync directions and unchanged behaviours where relevant.
4. **Consider account coverage.** Evaluate Personal, Business, SharePoint, Personal 15-character drive IDs and shared-folder cases as relevant; explain why any affected account context is excluded.
5. **Preserve fixture safety.** Reuse established setup, teardown and isolated test paths. Avoid modifying unrelated remote data, consuming production credentials or leaving test artefacts behind.
6. **Do not fabricate execution evidence.** If E2E execution is unavailable because credentials, GitHub Actions permissions or test environments are missing, say so explicitly. Submit the test uplift and clearly distinguish unexecuted tests from passing tests; maintainers can run credentialled suites.
7. **No unit-test code.** Do not introduce D `unittest` blocks, separate unit tests, mocks for unit testing, or unit-test harnesses—even for isolated logic. Add or extend scenarios in the existing E2E framework instead. Do not replace E2E coverage with unit tests.

For changes strictly limited to documentation, packaging metadata or other areas with no client behaviour impact, explain why no E2E uplift is necessary. Do not create artificial E2E cases solely to satisfy a checklist.

## Building and checking changes

- Prefer a **distribution-packaged LDC compiler**, including compatibility validation on the oldest supported applicable distribution, as specified in `docs/contributing.md` and `docs/install.md`.
- A typical development build, when dependencies are available, is:

  ```sh
  ./configure DC=ldc2 --enable-debug --enable-notifications
  make clean
  make
  ./onedrive --version
  ```

- Report the actual compiler and platform tested. DMD and supported GDC configurations may be used for supplementary testing; do not substitute a newer compiler for minimum-supported-platform validation without stating the limitation.
- Building successfully establishes only that the code compiles; it does **not** establish correct remote synchronisation, conflict protection or database state.
- Never run destructive synchronisation, resync or tests against a user's real OneDrive account or data without explicit authorisation. Use isolated disposable test accounts and directories.

## Workflow for every code change

1. **Investigate:** Read the relevant code, documentation, issue/PR history and E2E cases. Identify the current intended behaviour and the reason for any protective logic.
2. **Explain:** State the root cause, proposed change, scope, expected behavioural impact and data-integrity risks before making a non-trivial modification.
3. **Implement:** Make the smallest consistent change; preserve existing semantics outside the explicitly requested fix.
4. **Validate:** Build with the appropriate compiler and add or adjust E2E regression coverage for behavioural changes. Run what is possible and report precisely what was and was not executed.
5. **Document:** Update relevant docs and explain compatibility, migration or resync implications, if any.
6. **Report:** Provide a concise change summary, issue/discussion reference, before/after evidence, test-case identifiers, account coverage, remaining risks and limitations.

Do not claim that a change is safe, correct, fully tested, or backwards compatible solely because an AI agent wrote it or because it compiles. Do not propose schema-version bumps, forced resyncs, changed defaults or broad architectural rewrites as incidental fixes; these require deliberate maintainer review.

## Pull request expectations

Follow the **before/after evidence format in `docs/contributing.md`**. For changes affecting runtime behaviour, include:

- The specific problem, root cause and linked issue or discussion.
- What changed, and what existing behaviour must remain unchanged.
- E2E cases added or updated (`ci/e2e/`) and expected scenarios, including negative controls where appropriate.
- Which E2E suites/accounts were actually run, with their outcomes; distinguish CI-pending or unavailable coverage.
- Build/compiler/distribution information and any documentation updated.
- Known limitations, areas not tested and potential user-data or compatibility impact.

**Key rule:** The appropriate response to a synchronisation bug is to fix the client **and** protect the fix with an E2E regression test. Do not introduce unit-test code; use the established E2E testing approach.
