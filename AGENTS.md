# Instructions for AI Coding Agents

This file applies to the entire `abraunegg/onedrive` repository. It supplements, rather than replaces, the project's maintainer instructions and technical documentation. Follow the existing source code and documentation when investigating behaviour; do not assume that generic OneDrive, D language, or AI-generated patterns reflect this client's implementation.

## Read before making changes

1. **[`docs/contributing.md`](docs/contributing.md)** — mandatory coding style, compiler expectations, documentation and pull request evidence requirements.
2. **[`docs/client-architecture.md`](docs/client-architecture.md)** — synchronisation architecture and state reconciliation; read before changing core client behaviour.
3. **[`docs/end_to_end_testing.md`](docs/end_to_end_testing.md)** — authoritative description of the E2E testing strategy, scenarios and account coverage.
4. **[`.github/ISSUE_TEMPLATE/bug_report.yml`](.github/ISSUE_TEMPLATE/bug_report.yml)** — mandatory GitHub bug-report form; read and follow it before preparing or submitting a bug report.
5. Relevant documentation under `docs/`, existing tests under `ci/e2e/`, and existing implementations in `src/` before proposing a change.

If these sources conflict or the intended behaviour is unclear, document the uncertainty and request maintainer guidance rather than inventing a new policy.

## Mandatory baseline and evidence for bug reports and fixes

**AI-generated conclusions without adequate evidence and architectural understanding are not acceptable.** This applies equally to human-authored and AI-assisted submissions. An apparently plausible explanation, an isolated code fragment, or a patch that seems to work is not proof of a defect.

1. **Investigate the current upstream implementation first.** Before claiming a bug exists in the current client, identify the exact unmodified upstream `master` commit (full SHA), build/version, operating system, configuration and relevant execution mode. Do not use an older release, downstream package, fork or patched working tree as a substitute for the current baseline.
2. **Historical or downstream behaviour is not proof of a defect in current `master`.** A failure observed in an older release, third-party package, fork or modified build does not establish that the same failure or consequence exists in the current upstream implementation, even when the relevant source lines appear unchanged. Architecture, event handling, state transitions and downstream call paths may have changed substantially. Historical reports and source comparisons are useful starting points, **never substitutes for independent validation against unmodified current upstream code**.
3. **Demonstrate the failure before proposing the fix.** Reproduce the claimed behaviour on **unmodified current upstream code**, using actual application execution and appropriate filesystem/Microsoft Graph evidence. Record the exact conditions, steps, relevant logs and observable incorrect outcome. For a destructive-synchronisation claim, distinguish an incorrect remote deletion, move or replacement from eventual final-state convergence. Never claim a successful run on **patched** `master` proves the defect occurs on **unpatched** `master`.
4. **Trace the complete execution and state lifecycle.** Follow the event or API response through capture, filtering, coalescing, expected effects, reconciliation, database and filesystem state, the eventual Graph operation, and recovery/restart behaviour as applicable. Similar function bodies or matching log lines across releases are not evidence of equivalent end-to-end behaviour. Inspect relevant historical issues/PRs to understand *why* non-obvious handling exists before proposing to replace it.
5. **Separate fact, inference and hypothesis.** Clearly identify which behaviour was observed on which version, which code paths were inspected, what has not been run, and what remains unproven. If current-master execution is unavailable, describe a **suspected/unverified issue**, not a confirmed current-master regression or verified fix; request a current-baseline reproduction rather than inventing results.
6. **Do not submit a speculative fix as a confirmed correction.** A PR claiming to fix a current-version defect must link to a reproducible current-version failure or explicitly state that the prerequisite evidence is unavailable and obtain maintainer guidance before proceeding. A successful build, a plausible static analysis or an AI-generated explanation is insufficient.

**Triage consequence:** Submissions that claim a defect exists in current `master` based solely on observations from an older release, downstream package, fork or patched build, or on apparently identical source code, are **insufficiently substantiated and will be rejected or closed without a code change unless independent evidence against unmodified current upstream code is provided**. This standard applies regardless of whether a submission was written by a human or assisted by an AI coding tool.

## Mandatory GitHub bug-report template

**Every bug report MUST be submitted using the repository's official [Bug Report issue template](.github/ISSUE_TEMPLATE/bug_report.yml). This is a submission requirement, not a suggestion.** AI coding agents must follow it when preparing, drafting or opening an issue, including when filing on a user's behalf.

- Select **Bug Report** through the repository's GitHub **New issue** workflow. Do not submit a free-form issue, bypass the form through the GitHub API/CLI, or use a pull request, discussion or another issue template as a substitute for a bug report.
- **Preserve and complete every required field** in the template, including the actual operating system, installation method, account type, client version, configuration, curl version, filesystem/mount information, usage context, reproduction steps and complete relevant logs. Supply exact command output and evidence where requested; do not replace the form with an AI-written diagnosis or abbreviated summary.
- **Never invent, infer or fabricate template answers.** If required information or current-upstream reproduction evidence is unavailable, request it from the reporter before submission. Do not use invented values, placeholders or misleading `N/A` entries to circumvent required fields.
- Follow the template's instructions for debug logs and supporting material. Keep observed facts, environment details, source-code hypotheses and proposed fixes clearly separated. A completed form does not replace the current-upstream evidence requirements above.

**Triage consequence:** Bug reports that bypass the official template, omit required information or substitute unsupported AI-generated conclusions for evidence may be rejected or closed until they are correctly resubmitted.

## Architectural context is mandatory

- Read `docs/client-architecture.md`, the relevant `src/` call paths and the issue/PR history **before** diagnosing or modifying synchronisation behaviour. For monitor changes, study the observe/discover/reconcile/plan/apply model established by PR #3794; do not assume the pre-reconstruction event-as-command model still governs the client.
- Explain the purpose of existing safeguards, including event coalescing, move-cookie handling, expected client-generated filesystem effects, directory-watch rebasing, selective sync, database baseline preservation, authoritative reconciliation and data-preservation gates as relevant.
- Distinguish **content convergence** from **operation correctness**. Equal final local/remote contents do not prove that remote item identity, version history or correct move/delete semantics were preserved.
- Evaluate both the immediate proposed change and its effect on surrounding invariants: actual deletions must still propagate, excluded paths must remain excluded, valid watch descriptors must not be needlessly recreated, and legitimate local/remote changes must not silently drift apart.
- Do not replace a narrowly understood branch with a generic or simpler algorithm just because an AI tool labels it a correctness issue. State the existing design rationale, the precise demonstrated violation and why the proposed change preserves the protections already implemented.

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
2. **Extend the existing framework.** Prefer uplifting a relevant existing numbered test case with a focused scenario over creating a new standalone test case. Add a new numbered case only when existing coverage cannot reasonably be extended and the need is justified. Test actual client operations and outcomes, rather than only the return value of a mocked function.
3. **Test before and after.** When claiming a confirmed current-version defect, show a failing control against **unmodified current `master`** and the corresponding result with the proposed change. If that execution is unavailable, do not claim a confirmed reproduction or a verified fix. Validate positive and negative controls, both sync directions and unchanged behaviours where relevant.
4. **Consider account coverage.** Evaluate Personal, Business, SharePoint, Personal 15-character drive IDs and shared-folder cases as relevant; explain why any affected account context is excluded.
5. **Preserve fixture safety.** Reuse established setup, teardown and isolated test paths. Avoid modifying unrelated remote data, consuming production credentials or leaving test artefacts behind.
6. **Do not fabricate execution evidence.** If E2E execution is unavailable because credentials, GitHub Actions permissions or test environments are missing, say so explicitly. Submit the test uplift and clearly distinguish unexecuted tests from passing tests; maintainers can run credentialled suites.
7. **No unit-test code or synthetic application hooks.** Do not introduce D `unittest` blocks, separate unit tests, mocks for unit testing, unit-test harnesses, application fault-injection branches, test-only environment-variable behaviour or synthetic inotify events. Add or extend scenarios in the existing E2E framework instead, exercising genuine filesystem and Microsoft Graph operations. Do not open or modify the client-owned SQLite database concurrently while the client is running.

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

1. **Investigate:** Establish the exact unmodified current upstream baseline and reproduce the claimed defect before calling it confirmed. Read the relevant code, documentation, issue/PR history and E2E cases. Identify the current intended behaviour and the reason for any protective logic.
2. **Explain:** State the root cause, proposed change, scope, expected behavioural impact and data-integrity risks before making a non-trivial modification.
3. **Implement:** Make the smallest consistent change; preserve existing semantics outside the explicitly requested fix.
4. **Validate:** Build with the appropriate compiler and add or adjust E2E regression coverage for behavioural changes. Run what is possible and report precisely what was and was not executed.
5. **Document:** Update relevant docs and explain compatibility, migration or resync implications, if any.
6. **Report:** Provide a concise change summary, issue/discussion reference, before/after evidence, test-case identifiers, account coverage, remaining risks and limitations.

Do not claim that a change is safe, correct, fully tested, or backwards compatible solely because an AI agent wrote it or because it compiles. Do not propose schema-version bumps, forced resyncs, changed defaults or broad architectural rewrites as incidental fixes; these require deliberate maintainer review.

## Pull request expectations

Follow the **before/after evidence format in `docs/contributing.md`**. For changes affecting runtime behaviour, include:

- The specific problem, root cause and linked issue or discussion, with the exact **unmodified current upstream commit** used for the failing control.
- What changed, and what existing behaviour must remain unchanged; explain how the change respects the current architecture and historical safeguards.
- E2E cases added or updated (`ci/e2e/`) and expected scenarios, including negative controls where appropriate.
- Which E2E suites/accounts were actually run, with their outcomes; distinguish CI-pending or unavailable coverage.
- Build/compiler/distribution information, current-version before/after reproduction evidence, and any documentation updated.
- Known limitations, areas not tested and potential user-data or compatibility impact.

**Key rule:** First establish that the defect exists in the **current unmodified upstream implementation** and understand why the relevant code behaves as it does. Then fix the client **and** protect the fix with an E2E regression test. Do not introduce unit-test code; use the established E2E testing approach.
