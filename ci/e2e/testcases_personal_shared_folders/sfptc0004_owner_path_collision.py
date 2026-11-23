from pathlib import Path

from framework.shared_folder_collision import SharedFolderCollisionCase


class SharedFolderPersonalTestCase0004OwnerPathCollision(SharedFolderCollisionCase):
    case_id = "sfptc0004"
    name = "Personal Shared Folder Issue #3990 owner-path collisions and sync_list"
    description = "Validate exact-name and prefix-name collisions after online changes, with safe sync_list permutations"
    account_type = "personal"
    share_relative = Path("SHARED_FOLDERS/SUB_FOLDER_1/CORE")
    fixture_parent_relative = share_relative / "nested/upload-target"
    preserved_file_relative = share_relative / "README.txt"
    second_share_relative = Path("MINIMAL")
    second_file_relative = second_share_relative / "single.txt"
