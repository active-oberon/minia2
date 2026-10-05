import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

MODULE = Path(__file__).with_name("manage.py")
spec = importlib.util.spec_from_file_location("desktop_packages", MODULE)
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image = self.root / "image"
        for folder in ("bin", "data", "source", "work", "apps"):
            (self.image / folder).mkdir(parents=True)
        (self.image / "oberon.cfg").write_text(
            "Files.AddSearchPath bin~\nFiles.SetWorkPath work~\nConfiguration.Init~\n",
            encoding="utf-8")
        (self.image / "minia2-image.json").write_text(
            json.dumps({"platform": "Win64"}), encoding="utf-8")
        self.package = self.root / "clock.zip"
        manager.zip_package(
            self.package,
            {"name": "clock", "version": "1", "platform": "Win64",
             "requires": [], "commands": ["WMClock.Open"]},
            {"bin/WMClock.GofWw": b"object", "data/WMClock.rep": b"asset"})

    def test_install_and_remove(self):
        manager.install(argparse.Namespace(image=self.image, package=str(self.package)))
        self.assertEqual((self.image / "apps/clock/bin/WMClock.GofWw").read_bytes(), b"object")
        config = (self.image / "oberon.cfg").read_text(encoding="utf-8")
        self.assertLess(config.index("System.DoFile apps.cfg~"),
                        config.index("Files.SetWorkPath work~"))
        self.assertIn("apps/clock/data", (self.image / "apps.cfg").read_text(encoding="utf-8"))
        manager.remove(argparse.Namespace(image=self.image, name="clock"))
        self.assertFalse((self.image / "apps/clock").exists())
        self.assertEqual((self.image / "apps.cfg").read_text(encoding="utf-8"), "")

    def test_rejects_wrong_platform_and_core_collision(self):
        with self.assertRaisesRegex(ValueError, "wrong package platform"):
            manager.read_package(self.package, "Linux64")
        (self.image / "bin/WMClock.GofWw").write_bytes(b"core")
        with self.assertRaisesRegex(ValueError, "collides"):
            manager.install(argparse.Namespace(image=self.image, package=str(self.package)))

    def test_rejects_archive_path_escape(self):
        bad = self.root / "bad.zip"
        body = b"escape"
        manifest = {"format": manager.FORMAT, "name": "bad", "version": "1",
                    "platform": "Win64", "files": {"bin/../escape": manager.sha(body)}}
        with zipfile.ZipFile(bad, "w") as archive:
            archive.writestr("a2app.json", json.dumps(manifest))
            archive.writestr("bin/../escape", body)
        with self.assertRaisesRegex(ValueError, "invalid package entry"):
            manager.install(argparse.Namespace(image=self.image, package=str(bad)))
        self.assertFalse((self.root / "escape").exists())


if __name__ == "__main__":
    unittest.main()
