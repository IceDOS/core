from pathlib import Path
import tempfile
import unittest

from build.util import sync_dir


class SyncDirTest(unittest.TestCase):
    def test_sync_dir_skips_result_symlink_and_avoids_copytree_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            dst = Path(tmp) / "dst"
            src.mkdir()
            (src / "file.txt").write_text("hello")
            (src / "result").symlink_to(src / "file.txt")
            (src / "result-test").symlink_to(src / "file.txt")

            sync_dir(src, dst)
            self.assertTrue((dst / "file.txt").is_file())
            self.assertFalse((dst / "result").exists())
            self.assertFalse((dst / "result-test").exists())

            # Second sync_dir into existing destination should succeed
            sync_dir(src, dst)
            self.assertFalse((dst / "result").exists())

    def test_sync_dir_skips_txn_and_pending(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            dst = Path(tmp) / "dst"
            src.mkdir()
            (src / ".txn").mkdir()
            (src / ".txn" / "manifest.json").write_text("{}")
            (src / ".txn.lock").write_text("")
            (src / ".update-pending").write_text("")
            (src / "normal.txt").write_text("normal")

            sync_dir(src, dst)
            self.assertTrue((dst / "normal.txt").is_file())
            self.assertFalse((dst / ".txn").exists())
            self.assertFalse((dst / ".txn.lock").exists())
            self.assertFalse((dst / ".update-pending").exists())


if __name__ == "__main__":
    unittest.main()
