"""Exercise installation and cleanup in a temporary directory, without Nix."""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"


@unittest.skipUnless(os.geteuid() == 0, "requires root to test setuid ownership")
class InstallFlClashX(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="flclashx-install-test-")
        self.root = Path(self.temp.name)
        self.opt = self.root / "opt"
        self.v1 = self.make_package("a" * 32, "0.4.2")
        self.v2 = self.make_package("b" * 32, "0.4.3")

    def tearDown(self):
        self.temp.cleanup()

    def make_package(self, digest, version):
        package = self.root / f"{digest}-flclashx-{version}"
        bundle = package / "share/flclashx"
        (bundle / "lib").mkdir(parents=True)
        for name in ["FlClashX", "FlClashCore"]:
            shutil.copyfile("/bin/true", bundle / name)
            (bundle / name).chmod(0o755)
        (bundle / "lib/library.so.1").write_text(version)
        (bundle / "lib/library.so").symlink_to("library.so.1")
        return package

    def run_installer(self, package, success=True):
        result = subprocess.run(
            ["bash", str(INSTALLER), str(package), str(self.opt)],
            capture_output=True, text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def current(self):
        return self.opt / "FlClashX"

    def test_install_copies_bundle_and_sets_only_core_setuid(self):
        self.run_installer(self.v1)
        current = self.current()
        self.assertTrue(current.is_symlink())
        self.assertTrue(current.resolve().is_relative_to(self.opt))
        self.assertNotEqual(current.resolve(), self.v1 / "share/flclashx")
        core = (current / "FlClashCore").stat()
        self.assertEqual((core.st_uid, core.st_gid), (0, 0))
        self.assertEqual(stat.S_IMODE(core.st_mode), 0o4755)
        self.assertEqual(stat.S_IMODE((current / "FlClashX").stat().st_mode), 0o755)
        self.assertEqual((current / "lib/library.so").read_text(), "0.4.2")
        self.assertTrue((current / "lib/library.so").is_symlink())
        self.assertEqual((current / ".nix-package").read_text().strip(), str(self.v1))

    def test_same_package_keeps_existing_files(self):
        self.run_installer(self.v1)
        inode = (self.current() / "FlClashCore").stat().st_ino
        self.run_installer(self.v1)
        self.assertEqual((self.current() / "FlClashCore").stat().st_ino, inode)

    def test_update_removes_old_copy_and_rollback_recreates_it(self):
        self.run_installer(self.v1)
        old = self.current().resolve()
        self.run_installer(self.v2)
        self.assertFalse(old.exists())
        self.assertEqual((self.current() / "lib/library.so").read_text(), "0.4.3")
        self.run_installer(self.v1)
        self.assertEqual((self.current() / "lib/library.so").read_text(), "0.4.2")

    def test_invalid_bundle_keeps_current_installation(self):
        self.run_installer(self.v1)
        old = self.current().resolve()
        (self.v2 / "share/flclashx/FlClashCore").unlink()
        self.run_installer(self.v2, success=False)
        self.assertEqual(self.current().resolve(), old)

    def test_recovers_complete_copy_without_public_link(self):
        self.run_installer(self.v1)
        old = self.current().resolve()
        self.current().unlink()
        self.run_installer(self.v1)
        self.assertEqual(self.current().resolve(), old)

    def test_refuses_world_writable_directory(self):
        self.opt.mkdir(mode=0o777)
        self.opt.chmod(0o777)
        self.run_installer(self.v1, success=False)
        self.assertFalse(self.current().exists())

    def test_refuses_directory_collision_and_symlink_parent(self):
        self.opt.mkdir()
        self.current().mkdir()
        self.run_installer(self.v1, success=False)
        shutil.rmtree(self.opt)
        self.opt.symlink_to(self.root)
        self.run_installer(self.v1, success=False)

    def test_removal_is_idempotent_and_preserves_unmanaged_files(self):
        self.run_installer(self.v1)
        unmanaged = self.opt / "FlClashX-versions/unmanaged"
        unmanaged.mkdir()
        (unmanaged / "keep").write_text("keep")
        self.run_installer("--remove")
        self.assertFalse(self.current().is_symlink())
        self.assertFalse((self.opt / "FlClashX-versions" / self.v1.name).exists())
        self.assertEqual((unmanaged / "keep").read_text(), "keep")
        self.run_installer("--remove")


if __name__ == "__main__":
    unittest.main(verbosity=2)
