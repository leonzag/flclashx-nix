"""Exercise installation and cleanup in a temporary directory, without Nix."""

import os
from pathlib import Path
import shutil
import shlex
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
            shutil.copyfile(shutil.which("true"), bundle / name)
            (bundle / name).chmod(0o755)
        (bundle / "lib/library.so.1").write_text(version)
        (bundle / "lib/library.so").symlink_to("library.so.1")
        return package

    def run_installer(self, package, success=True, env=None):
        result = subprocess.run(
            ["bash", str(INSTALLER), str(package), str(self.opt)],
            capture_output=True, text=True, env=env,
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
        self.assertTrue(current.is_dir())
        self.assertFalse(current.is_symlink())
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

    def test_service_restart_updates_and_rollback_restores_bundle(self):
        self.run_installer(self.v1)
        self.run_installer("--remove")
        self.assertFalse(self.current().exists())
        self.run_installer(self.v2)
        self.assertEqual((self.current() / "lib/library.so").read_text(), "0.4.3")
        self.run_installer("--remove")
        self.run_installer(self.v1)
        self.assertEqual((self.current() / "lib/library.so").read_text(), "0.4.2")

    def test_invalid_bundle_keeps_current_installation(self):
        self.run_installer(self.v1)
        old = self.current().resolve()
        (self.v2 / "share/flclashx/FlClashCore").unlink()
        self.run_installer(self.v2, success=False)
        self.assertEqual(self.current().resolve(), old)
        self.assertEqual((self.current() / "lib/library.so").read_text(), "0.4.2")

    def test_refuses_replacing_bundle_before_service_stop(self):
        self.run_installer(self.v1)
        self.run_installer(self.v2, success=False)
        self.assertEqual((self.current() / "lib/library.so").read_text(), "0.4.2")

    def test_failed_install_leaves_no_partial_bundle(self):
        (self.v1 / "share/flclashx/FlClashCore").unlink()
        self.run_installer(self.v1, success=False)
        self.assertFalse(self.current().exists())
        self.assertEqual(list(self.opt.glob(".FlClashX.*")), [])

    def test_copy_failure_cleans_temporary_directory(self):
        commands = self.root / "commands"
        commands.mkdir()
        fake_cp = commands / "cp"
        fake_cp.write_text(f'#!/bin/sh\n{shlex.quote(shutil.which("cp"))} "$@"\nexit 1\n')
        fake_cp.chmod(0o755)
        env = dict(os.environ, PATH=f'{commands}:{os.environ["PATH"]}')
        self.run_installer(self.v1, success=False, env=env)
        self.assertFalse(self.current().exists())
        self.assertEqual(list(self.opt.glob(".FlClashX.*")), [])

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
        unmanaged = self.opt / "another-app"
        unmanaged.mkdir()
        (unmanaged / "keep").write_text("keep")
        self.run_installer("--remove")
        self.assertFalse(self.current().exists())
        self.assertEqual((unmanaged / "keep").read_text(), "keep")
        self.run_installer("--remove")

    @unittest.skipUnless(os.environ.get("FLCLASHX_LEGACY_INSTALLER"), "legacy installer fixture not provided")
    def test_migrate_from_legacy_service_and_rollback(self):
        legacy = os.environ["FLCLASHX_LEGACY_INSTALLER"]

        def run_legacy(package):
            subprocess.run(["bash", legacy, str(package), str(self.opt)], check=True, capture_output=True)

        run_legacy(self.v1)
        self.assertTrue(self.current().is_symlink())
        # NixOS runs the loaded old unit's ExecStop before loading the new unit.
        run_legacy("--remove")
        self.run_installer(self.v2)
        self.assertFalse(self.current().is_symlink())
        self.assertEqual((self.current() / "lib/library.so").read_text(), "0.4.3")
        self.run_installer("--remove")
        run_legacy(self.v1)
        self.assertTrue(self.current().is_symlink())
        self.assertEqual((self.current() / "lib/library.so").read_text(), "0.4.2")


if __name__ == "__main__":
    unittest.main(verbosity=2)
