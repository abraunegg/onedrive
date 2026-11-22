"""Issue #3990 live Shared Folder path-collision regression coverage.

Only this testcase's uniquely named child under an existing upload-target is mutable.
No fixture objects are modified, renamed, or deleted.  Unsafe reconciliation fails
closed and leaves the owned subtree for inspection rather than risking cleanup.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class CollisionFailure(RuntimeError):
    pass


@dataclass(frozen=True)
class CollisionScenario:
    scenario_id: str
    description: str
    sync_list: tuple[str, ...] | None
    expected_keys: frozenset[str]
    include_second_shortcut: bool = False


class SharedFolderCollisionCase(E2ETestCase):
    """Common live E2E implementation; account fixtures are selected by subclasses."""

    account_type: str = ""
    share_relative: Path = Path()
    fixture_parent_relative: Path = Path()
    preserved_file_relative: Path = Path()
    second_share_relative: Path = Path()
    second_file_relative: Path = Path()
    case_dir_name: str = ""
    scenario_prefix: str = "SL"

    def _write_config(
        self, context: E2EContext, confdir: Path, sync_root: Path,
        sync_list: tuple[str, ...] | None,
    ) -> None:
        config = (
            f"# {self.case_id} Issue 3990 owner-path collision regression\n"
            f'sync_dir = "{sync_root}"\n'
            'threads = "2"\n'
        )
        if self.account_type == "business":
            config += 'sync_business_shared_items = "true"\n'
        context.prepare_minimal_config_dir(confdir, config)
        if sync_list is not None:
            write_text_file(confdir / "sync_list", "\n".join(sync_list) + "\n")

    def _execute(
        self, context: E2EContext, label: str, confdir: Path, log_dir: Path,
        artifacts: list[str], *, resync: bool = False,
        download_only: bool = False, upload_only: bool = False, local_first: bool = False,
    ):
        command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--verbose"]
        if download_only:
            command.append("--download-only")
        if upload_only:
            command.append("--upload-only")
        if local_first:
            command.append("--local-first")
        if resync:
            command.extend(["--resync", "--resync-auth"])
        command.extend(["--confdir", str(confdir)])
        context.log(f"Executing {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        stdout_file = log_dir / f"{label}-stdout.log"
        stderr_file = log_dir / f"{label}-stderr.log"
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        artifacts.extend([str(stdout_file), str(stderr_file)])
        if result.returncode != 0:
            raise CollisionFailure(f"{label} exited with status {result.returncode}; see {stdout_file}")
        return result

    def _fresh_client(
        self, context: E2EContext, layout, label: str,
        sync_list: tuple[str, ...] | None, artifacts: list[str],
    ):
        sync_root = layout.work_dir / f"{label}-syncroot"
        confdir = layout.work_dir / f"{label}-conf"
        reset_directory(sync_root)
        self._write_config(context, confdir, sync_root, sync_list)
        result = self._execute(
            context, f"{label}-resync", confdir, layout.log_dir, artifacts,
            resync=True, download_only=True,
        )
        return sync_root, confdir, result

    def _owner_metadata(self, stdout: str) -> dict:
        """Use the owner item's Graph name, not the local shortcut alias."""
        needle = f"Syncing this OneDrive {self.account_type.title()} Shared Folder:"
        expected_shortcut = self.share_relative.as_posix()
        selected = False
        for line in stdout.splitlines():
            if needle in line:
                selected = line.split(needle, 1)[1].strip().lstrip("./") == expected_shortcut
                continue
            marker = "Submitting this 'driveData' for bounded processing = "
            if selected and marker in line:
                try:
                    owner = json.loads(line.split(marker, 1)[1].strip())
                except (ValueError, TypeError) as exc:
                    raise CollisionFailure("Cannot decode Shared Folder owner Graph metadata") from exc
                name = owner.get("name")
                item_id = owner.get("id")
                if not isinstance(name, str) or not name or name in (".", "..") or "/" in name or "\\" in name:
                    raise CollisionFailure("Graph did not provide a safe, named Shared Folder owner root")
                if not isinstance(item_id, str) or not item_id:
                    raise CollisionFailure("Graph did not provide an owner root item ID")
                # SharePoint-backed shares may represent a drive root.  Keep that
                # fact explicit: the original buggy substring matched the *local
                # shortcut name*, not Graph's `root` facet/name.
                return {"name": name, "id": item_id, "drive_root": "root" in owner}
        raise CollisionFailure(
            "Owner-side Graph root metadata was not observed for the selected shortcut; "
            "refusing to substitute the local shortcut name"
        )

    def _verify_remote_anchor(self, confdir: Path, owner: dict) -> None:
        database_path = confdir / "items.sqlite3"
        if not database_path.is_file():
            raise CollisionFailure("Initial sync did not create items.sqlite3")
        with sqlite3.connect(f"file:{database_path}?mode=ro", uri=True) as connection:
            rows = connection.execute(
                "SELECT remoteId, remoteDriveId FROM item WHERE name = ? AND type = 'remote'",
                (self.share_relative.name,),
            ).fetchall()
        if len(rows) != 1 or not rows[0][0] or not rows[0][1]:
            raise CollisionFailure("Expected exactly one verified remote shortcut anchor in item database")
        # Personal Graph identifiers may differ in case; owner item identity is otherwise exact.
        left, right = rows[0][0], owner["id"]
        if (left.lower() if self.account_type == "personal" else left) != (
            right.lower() if self.account_type == "personal" else right
        ):
            raise CollisionFailure("Selected shortcut remoteId does not match the Graph owner root item ID")

    @staticmethod
    def _sha(data: bytes) -> str:
        return hashlib.sha256(data).hexdigest()

    def _identity(self, confdir: Path, filename: str) -> tuple[str, str]:
        with sqlite3.connect(f"file:{confdir / 'items.sqlite3'}?mode=ro", uri=True) as connection:
            rows = connection.execute(
                "SELECT driveId, id FROM item WHERE name = ? AND type = 'file'",
                (filename,),
            ).fetchall()
        if len(rows) != 1 or not all(rows[0]):
            raise CollisionFailure(f"Expected exactly one owned file database identity for {filename!r}; found {len(rows)}")
        if self.account_type == "personal":
            return (str(rows[0][0]).lower(), str(rows[0][1]).lower())
        return (str(rows[0][0]), str(rows[0][1]))

    def _verify_files(
        self, sync_root: Path, owned_relative: Path, files: dict[str, Path],
        expected_keys: frozenset[str], contents: dict[str, bytes], label: str,
        state_dir: Path, artifacts: list[str], *, second_file: bool = False,
        expect_preserved: bool | None = None,
    ) -> None:
        manifest_file = state_dir / f"{label}-manifest.txt"
        manifest = build_typed_manifest(sync_root)
        write_manifest(manifest_file, manifest)
        artifacts.append(str(manifest_file))
        problems: list[str] = []
        for key, relative in files.items():
            p = sync_root / relative
            if key in expected_keys:
                if not p.is_file():
                    problems.append(f"missing expected selected file: {relative}")
                elif p.read_bytes() != contents[key]:
                    problems.append(f"selected file content differs: {relative}")
            elif p.exists():
                problems.append(f"excluded file unexpectedly present: {relative}")

        # Catch root escapes and relocations, not just missing expected paths.
        tracked_names = {p.name for p in files.values()}
        for p in sync_root.rglob("*"):
            if p.is_file() and p.name in tracked_names:
                relative = p.relative_to(sync_root)
                if relative not in files.values():
                    problems.append(f"Issue #3990 ghost/misplaced file: {relative}")
            if p.is_dir() and p.name == owned_relative.name and p.relative_to(sync_root) != owned_relative:
                problems.append(f"unexpected reserved directory outside verified share: {p.relative_to(sync_root)}")

        preserved_exists = (sync_root / self.preserved_file_relative).is_file()
        if expect_preserved is True and not preserved_exists:
            problems.append("included fixture sentinel missing from selected scope")
        if expect_preserved is False and preserved_exists:
            problems.append("unselected fixture sentinel leaked into sync_list scope")
        if second_file and not (sync_root / self.second_file_relative).is_file():
            problems.append("multiple-shortcut selection did not materialise the second shared folder")
        if not second_file and (sync_root / self.second_file_relative).is_file():
            problems.append("excluded second shortcut leaked into the selected sync_list scope")
        if problems:
            raise CollisionFailure(f"{label}: " + "; ".join(problems[:12]))

    def _scenarios(self, owned: Path, files: dict[str, Path], owner: str) -> list[CollisionScenario]:
        base = "/" + owned.as_posix()
        share = "/" + self.share_relative.as_posix() + "/"
        all_keys = frozenset(files)
        prefix_keys = frozenset(("prefix", "prefix_deep"))
        exact_keys = frozenset(("exact", "exact_deep"))
        scenarios = [
            CollisionScenario("SL-0000", "default sync without sync_list", None, all_keys, True),
            CollisionScenario("SL-0001", "entire Shared Folder included", (share,), all_keys),
            CollisionScenario("SL-0002", "deep test-owned subtree include", (base + "/",), all_keys),
            CollisionScenario("SL-0003", "exact file beneath prefix-name collision", ("/" + files["prefix"].as_posix(),), frozenset(("prefix",))),
            CollisionScenario("SL-0004", "exact file beneath exact-name collision", ("/" + files["exact"].as_posix(),), frozenset(("exact",))),
            CollisionScenario("SL-0005", "exclusion-first prefix-name branch", (f"!{base}/{owner} response/", base + "/"), all_keys - frozenset(("prefix",))),
            CollisionScenario("SL-0006", "wildcard prefix-name directory inclusion", (f"{base}/{owner} resp*/",), frozenset(("prefix",))),
            CollisionScenario("SL-0007", "recursive glob beneath nested name collision", (f"{base}/**/{files['prefix_deep'].name}",), frozenset(("prefix_deep",))),
            CollisionScenario("SL-0008", "exclusion-first exact-name branch", (f"!{base}/{owner}/", base + "/"), all_keys - frozenset(("exact",))),
            CollisionScenario("SL-0009", "wildcard exclusion of nested collision branches", (f"!{base}/Level2/*", base + "/"), all_keys - frozenset(("prefix_deep", "exact_deep"))),
            CollisionScenario("SL-0010", "multiple Shared Folder shortcuts included", (base + "/", "/" + self.second_share_relative.as_posix() + "/"), all_keys, True),
        ]
        if self.scenario_prefix != "SL":
            scenarios = [CollisionScenario(f"{self.scenario_prefix}-{item.scenario_id[3:]}", item.description,
                                           item.sync_list, item.expected_keys, item.include_second_shortcut)
                         for item in scenarios]
        return scenarios

    def run(self, context: E2EContext):
        layout = self.prepare_case_layout(context, case_dir_name=self.case_dir_name or self.case_id, ensure_refresh_token=True)
        artifacts: list[str] = []
        details: dict[str, object] = {"issue": 3990, "account_type": self.account_type, "destructive_fixture_changes": False}
        metadata_file = layout.state_dir / "metadata.json"
        artifacts.append(str(metadata_file))
        seed_attempted = False
        cleanup_completed = False
        failure = ""
        selected_scenario_ids: list[str] = []
        owned_relative = Path()
        try:
            safe_run_id = re.sub(r"[^A-Za-z0-9_-]", "", str(context.run_id))[-18:] or "local"
            safe_label = re.sub(r"[^A-Za-z0-9_-]", "", str(context.run_label))[:18] or "primary"
            reserved = f"ZZ_E2E_{self.case_id.upper()}_{safe_run_id}_{safe_label}"
            if len(reserved) > 100 or not re.fullmatch(r"[A-Za-z0-9_-]+", reserved):
                raise CollisionFailure("Unsafe testcase-owned directory identifier")
            owned_relative = self.fixture_parent_relative / reserved
            details["reserved_relative_path"] = owned_relative.as_posix()

            # The seed account has a fresh DB; no pre-existing fixture may be touched.
            seed_root = layout.work_dir / "seed-syncroot"
            seed_conf = layout.work_dir / "seed-conf"
            reset_directory(seed_root)
            share_selection = ("/" + self.share_relative.as_posix() + "/",)
            self._write_config(context, seed_conf, seed_root, share_selection)
            baseline = self._execute(context, "baseline-download", seed_conf, layout.log_dir, artifacts, resync=True, download_only=True)
            owner = self._owner_metadata(baseline.stdout)
            self._verify_remote_anchor(seed_conf, owner)
            details["owner_root_name"] = owner["name"]
            details["owner_is_drive_root"] = owner["drive_root"]
            # The historical defect searched for the shortcut *name* inside the
            # owner's parentReference.path. It is not always the owner root name
            # (notably SharePoint drive roots and renamed user-owned shortcuts).
            collision_name = self.share_relative.name
            details["substring_collision_name"] = collision_name
            parent = seed_root / self.fixture_parent_relative
            preserved = seed_root / self.preserved_file_relative
            if not parent.is_dir() or not preserved.is_file():
                raise CollisionFailure("Preserved Shared Folder fixture upload-target or sentinel file is missing")
            preserved_sha = self._sha(preserved.read_bytes())
            owned_root = seed_root / owned_relative
            if owned_root.exists():
                raise CollisionFailure("Test-owned directory already exists online; refusing to overwrite it")

            uid = safe_run_id
            keys: dict[str, Path] = {
                "prefix": Path(f"{collision_name} response/Photos/{self.case_id}-prefix-{uid}.txt"),
                "exact": Path(f"{collision_name}/Docs/{self.case_id}-exact-{uid}.txt"),
                "prefix_deep": Path(f"Level2/{owner['name']} response/More/{self.case_id}-prefix-deep-{uid}.txt"),
                "exact_deep": Path(f"Level2/{owner['name']}/More/{self.case_id}-exact-deep-{uid}.txt"),
                "control": Path(f"control/{self.case_id}-control-{uid}.txt"),
            }
            files = {k: owned_relative / rel for k, rel in keys.items()}
            # Only the case-owned subtree is created; all original parents are immutable.
            contents = {k: f"Issue #3990 {self.case_id} {safe_run_id} {k} revision 0\n".encode() for k in files}
            # Do not create a new Shared Folder directory and all descendants in
            # one upload pass.  The newly created parent can be present online
            # before it is resolvable through the shortcut during that same pass.
            # Seed only one level at a time and reconcile the owner-side IDs
            # before creating children under those parents.
            directories = {owned_relative}
            for relative in files.values():
                parent_relative = relative.parent
                while parent_relative != self.fixture_parent_relative:
                    if not parent_relative.is_relative_to(owned_relative):
                        raise CollisionFailure("Unsafe seed directory outside testcase-owned subtree")
                    directories.add(parent_relative)
                    parent_relative = parent_relative.parent
            stages: dict[int, list[Path]] = {}
            for relative in directories:
                depth = len(relative.relative_to(self.fixture_parent_relative).parts)
                stages.setdefault(depth, []).append(relative)
            for depth in sorted(stages):
                for relative in sorted(stages[depth]):
                    path = seed_root / relative
                    if path.exists():
                        raise CollisionFailure(f"Reserved seed directory unexpectedly exists: {relative}")
                    path.mkdir()  # Its parent was seeded and reconciled at the preceding depth.
                seed_attempted = True
                self._execute(context, f"seed-depth-{depth}-upload-only", seed_conf,
                              layout.log_dir, artifacts, upload_only=True)
                # Ensure the client database recognises the newly created owner-
                # drive parent IDs before the following level is uploaded.
                self._execute(context, f"seed-depth-{depth}-reconcile", seed_conf,
                              layout.log_dir, artifacts, resync=True, download_only=True)
            for key, rel in files.items():
                dest = seed_root / rel
                if not dest.parent.is_dir():
                    raise CollisionFailure(f"Seed file parent is missing: {rel.parent}")
                dest.write_bytes(contents[key])
            self._execute(context, "seed-files-upload-only", seed_conf,
                          layout.log_dir, artifacts, upload_only=True)

            # Independent Graph round-trip proves the seed exists online before mutation.
            check_root, check_conf, _ = self._fresh_client(
                context, layout, "seed-remote-verify", share_selection, artifacts,
            )
            self._verify_files(check_root, owned_relative, files, frozenset(files), contents,
                               "seed-remote-verify", layout.state_dir, artifacts)
            if self._sha((check_root / self.preserved_file_relative).read_bytes()) != preserved_sha:
                raise CollisionFailure("Preserved sentinel changed during seed upload")
            baseline_ids = {k: self._identity(check_conf, p.name) for k, p in files.items()}
            # A different client (the seed client) now changes *online* eTags/content.
            for key in ("prefix", "exact", "prefix_deep", "exact_deep"):
                contents[key] = f"Issue #3990 {self.case_id} {safe_run_id} {key} revision 1\n".encode()
                dest = seed_root / files[key]
                dest.write_bytes(contents[key])
                future = int(time.time()) + 120
                os.utime(dest, (future, future))
            self._execute(context, "remote-update-upload-only", seed_conf, layout.log_dir, artifacts,
                          upload_only=True, local_first=True)

            # Reconcile the *existing* download-only client to trigger the reporter's
            # actual changed-eTag code path; fail before any bidirectional operation.
            delta = self._execute(context, "remote-update-download-only", check_conf,
                                  layout.log_dir, artifacts, download_only=True)
            self._verify_files(check_root, owned_relative, files, frozenset(files), contents,
                               "changed-etag-download-only", layout.state_dir, artifacts)
            if any(self._identity(check_conf, p.name) != baseline_ids[k] for k, p in files.items()):
                raise CollisionFailure("Owner-drive item identities changed during download-only reconciliation")
            # A misplaced move is a hard failure even if a subsequent download restored the file.
            if any("Moving " in line and any(p.name in line for p in files.values())
                   for line in delta.stdout.splitlines()):
                raise CollisionFailure("Changed-eTag reconciliation attempted to relocate an Issue #3990 file")

            # Only after download-only safety gates may normal bidirectional reconciliation run.
            bidirectional = self._execute(context, "bidirectional-noop", check_conf,
                                          layout.log_dir, artifacts)
            self._verify_files(check_root, owned_relative, files, frozenset(files), contents,
                               "bidirectional-noop", layout.state_dir, artifacts)
            for line in bidirectional.stdout.splitlines():
                if any(p.name in line for p in files.values()) and any(
                    verb in line for verb in ("Moving ", "Deleting ", "Uploading ", "Successfully deleted")
                ):
                    raise CollisionFailure(f"Unexpected destructive/reupload action during noop: {line[:240]}")

            # Fresh remote snapshot checks both content and stable online item IDs.
            remote_root, remote_conf, _ = self._fresh_client(
                context, layout, "post-reconcile-remote-verify", share_selection, artifacts,
            )
            self._verify_files(remote_root, owned_relative, files, frozenset(files), contents,
                               "post-reconcile-remote-verify", layout.state_dir, artifacts)
            if any(self._identity(remote_conf, p.name) != baseline_ids[k] for k, p in files.items()):
                raise CollisionFailure("An online file was deleted/recreated or moved during reconciliation")
            if self._sha((remote_root / self.preserved_file_relative).read_bytes()) != preserved_sha:
                raise CollisionFailure("A preserved remote fixture was modified")

            # Each sync_list permutation uses its own clean client/DB and a fresh Graph query.
            for scenario in self._scenarios(owned_relative, files, collision_name):
                if not context.should_run_scenario(self.case_id, scenario.scenario_id):
                    continue
                selected_scenario_ids.append(scenario.scenario_id)
                context.log(f"Running {self.case_id} {scenario.scenario_id}: {scenario.description}")
                scenario_root, scenario_conf, scenario_result = self._fresh_client(
                    context, layout, scenario.scenario_id, scenario.sync_list, artifacts,
                )
                self._verify_files(scenario_root, owned_relative, files, scenario.expected_keys,
                                   contents, scenario.scenario_id, layout.state_dir, artifacts,
                                   second_file=scenario.include_second_shortcut,
                                   expect_preserved=scenario.scenario_id.endswith(("0000", "0001")))
                for key in scenario.expected_keys:
                    if self._identity(scenario_conf, files[key].name) != baseline_ids[key]:
                        raise CollisionFailure(f"{scenario.scenario_id}: selected file lost original remote identity")

                # Exercise the *same* changed-eTag reconciliation path under this
                # sync_list configuration. Initial selection alone is insufficient
                # to reproduce #3990. Mutate only a selected, case-owned file online.
                priority = ("prefix", "exact", "prefix_deep", "exact_deep", "control")
                key_to_change = next(key for key in priority if key in scenario.expected_keys)
                revision = len(selected_scenario_ids) + 1
                contents[key_to_change] = (
                    f"Issue #3990 {self.case_id} {safe_run_id} {key_to_change} revision {revision} "
                    f"{scenario.scenario_id}\n"
                ).encode()
                source_file = seed_root / files[key_to_change]
                source_file.write_bytes(contents[key_to_change])
                future_mtime = int(time.time()) + 120 + revision * 60
                os.utime(source_file, (future_mtime, future_mtime))
                self._execute(
                    context, f"{scenario.scenario_id}-online-change", seed_conf,
                    layout.log_dir, artifacts, upload_only=True, local_first=True,
                )
                changed_result = self._execute(
                    context, f"{scenario.scenario_id}-changed-etag-download-only", scenario_conf,
                    layout.log_dir, artifacts, download_only=True,
                )
                self._verify_files(
                    scenario_root, owned_relative, files, scenario.expected_keys, contents,
                    f"{scenario.scenario_id}-changed-etag", layout.state_dir, artifacts,
                    second_file=scenario.include_second_shortcut,
                    expect_preserved=scenario.scenario_id.endswith(("0000", "0001")),
                )
                if any(
                    "Moving " in line and files[key_to_change].name in line
                    for line in changed_result.stdout.splitlines()
                ):
                    raise CollisionFailure(
                        f"{scenario.scenario_id}: remote change incorrectly moved the selected collision file"
                    )
                if self._identity(scenario_conf, files[key_to_change].name) != baseline_ids[key_to_change]:
                    raise CollisionFailure(f"{scenario.scenario_id}: eTag reconciliation changed remote item identity")
                # The independently downloaded root must also observe the online
                # update; this catches a delete/recreate or unintended remote move.
                self._execute(
                    context, f"{scenario.scenario_id}-independent-verify", remote_conf,
                    layout.log_dir, artifacts, download_only=True,
                )
                self._verify_files(
                    remote_root, owned_relative, files, frozenset(files), contents,
                    f"{scenario.scenario_id}-independent-verify", layout.state_dir, artifacts,
                )
                for key, relative in files.items():
                    if self._identity(remote_conf, relative.name) != baseline_ids[key]:
                        raise CollisionFailure(f"{scenario.scenario_id}: online item identity changed")
                details.setdefault("passed_scenario_ids", []).append(scenario.scenario_id)
                context.log(f"Scenario {scenario.scenario_id} PASSED")

            # Strict cleanup only after all identity/path/scope checks have passed.
            cleanup_root, cleanup_conf, _ = self._fresh_client(
                context, layout, "cleanup-discover", share_selection, artifacts,
            )
            self._verify_files(cleanup_root, owned_relative, files, frozenset(files), contents,
                               "cleanup-discover", layout.state_dir, artifacts)
            cleanup_owned_path = cleanup_root / owned_relative
            if not cleanup_owned_path.is_dir() or not cleanup_owned_path.name.startswith("ZZ_E2E_"):
                raise CollisionFailure("Refusing cleanup of an unverified reserved subtree")
            shutil.rmtree(cleanup_owned_path)
            self._execute(context, "cleanup-owned-delete", cleanup_conf, layout.log_dir, artifacts)
            empty_root, _, _ = self._fresh_client(
                context, layout, "cleanup-remote-verify", share_selection, artifacts,
            )
            if (empty_root / owned_relative).exists():
                raise CollisionFailure("Reserved testcase subtree is still present online after cleanup")
            if self._sha((empty_root / self.preserved_file_relative).read_bytes()) != preserved_sha:
                raise CollisionFailure("Preserved fixture changed during cleanup")
            cleanup_completed = True
        except (CollisionFailure, OSError, sqlite3.Error, ValueError) as exc:
            failure = str(exc)
            context.log(f"{self.case_id} FAIL: {failure}")
        finally:
            details["executed_scenario_ids"] = selected_scenario_ids
            details["scenario_count"] = len(selected_scenario_ids)
            details["cleanup_verified"] = cleanup_completed
            if not cleanup_completed and seed_attempted:
                details["cleanup_warning"] = (
                    "For safety, destructive cleanup was NOT attempted after a regression; "
                    f"inspect the possibly created test-owned remote subtree: {owned_relative.as_posix()}"
                )
            write_text_file(metadata_file, json.dumps(details, indent=2, sort_keys=True) + "\n")
        if failure:
            return self.fail_result(self.case_id, self.name, failure, artifacts, details)
        if not cleanup_completed:
            return self.fail_result(self.case_id, self.name, "Owned remote subtree cleanup not verified", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
