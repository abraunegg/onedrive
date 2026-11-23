from pathlib import Path

from framework.result import TestResult
from framework.shared_folder_collision import SharedFolderCollisionCase


class _BusinessSharePointCollision(SharedFolderCollisionCase):
    case_id = "bsftc0008"
    name = "Business Shared Folder Issue #3990 owner-path collisions and sync_list"
    description = "Verify owner-path collisions for SharePoint-backed and user-owned Business shares"
    account_type = "business"
    scenario_prefix = "SP"
    case_dir_name = "bsftc0008-sharepoint"
    share_relative = Path("Data/BSF_CORE")
    fixture_parent_relative = share_relative / "DATASET_B/nested/upload-target"
    preserved_file_relative = share_relative / "DATASET_B/README.txt"
    second_share_relative = Path("Data/BSF_MIXED_FILES")
    second_file_relative = second_share_relative / "DATASET_B/L1/L2/L3/deepfile.txt"


class _BusinessUserOwnedCollision(SharedFolderCollisionCase):
    case_id = "bsftc0008"
    name = "Business Shared Folder Issue #3990 owner-path collisions and sync_list"
    description = "Verify owner-path collisions for user-owned Business Shared Folders"
    account_type = "business"
    scenario_prefix = "UO"
    case_dir_name = "bsftc0008-user-owned"
    share_relative = Path("test user's files - Sub Folder 3")
    fixture_parent_relative = share_relative / "awerqwerqwer"
    preserved_file_relative = fixture_parent_relative / "file0.data"
    second_share_relative = Path("Data/BSF_CORE")
    second_file_relative = second_share_relative / "DATASET_B/README.txt"


class BusinessSharedFolderTestCase0008OwnerPathCollision(_BusinessSharePointCollision):
    def run(self, context):
        artifacts = []
        details = {"issue": 3990, "backend_results": {}}
        requested = context.selected_scenarios_for_case(self.case_id)
        targets = (
            ("SharePoint-backed", "SP-", _BusinessSharePointCollision()),
            ("user-owned", "UO-", _BusinessUserOwnedCollision()),
        )
        for backend, prefix, case in targets:
            if requested and not any(value.startswith(prefix) for value in requested):
                continue
            result = SharedFolderCollisionCase.run(case, context)
            artifacts.extend(result.artifacts)
            details["backend_results"][backend] = result.details
            if result.status != "pass":
                return TestResult.fail_result(
                    self.case_id, self.name, f"{backend}: {result.reason}", artifacts, details
                )
        details["executed_scenario_ids"] = [
            scenario_id
            for backend_details in details["backend_results"].values()
            for scenario_id in backend_details.get("executed_scenario_ids", [])
        ]
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
