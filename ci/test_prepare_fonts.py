"""Font preparation fails closed and leaves tested assets byte-identical."""
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import prepare_fonts


def digest(content):
    return {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}


class FontPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hmi-font-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.assets = Path(self.temporary.name)
        self.fonts = {"one.ttf": b"first-font-fixture", "two.ttf": b"second-font-fixture"}
        self.license = b"test license\n"
        (self.assets / "LICENSE.txt").write_bytes(self.license)
        self.archive = io.BytesIO()
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, content in self.fonts.items():
                archive.writestr(name, content)
            archive.writestr("../outside.txt", b"must not be extracted")
        self.archive_bytes = self.archive.getvalue()
        self.lock = {
            "schema": 1,
            "fonttools_version": "4.61.1",
            "licenses": {"LICENSE.txt": digest(self.license)},
            "fonts": {
                name: {
                    **digest(content), "format": "zip-member", "member": name,
                    "source": {**digest(self.archive_bytes), "url": "https://example.invalid/fonts.zip"},
                }
                for name, content in self.fonts.items()
            },
        }

    def create_fonts(self):
        for name, content in self.fonts.items():
            (self.assets / name).write_bytes(content)

    def local_download(self, source, destination):
        Path(destination).write_bytes(self.archive_bytes)
        prepare_fonts.verify_file(destination, source)

    def test_verified_assets_need_neither_network_nor_fonttools_and_keep_mtime(self):
        self.create_fonts()
        before = {p.name: p.stat().st_mtime_ns for p in self.assets.iterdir()}
        with patch.object(prepare_fonts, "download") as download, patch.object(prepare_fonts, "require_fonttools") as dependency:
            self.assertEqual(prepare_fonts.prepare_fonts(self.assets, self.lock), [])
        download.assert_not_called()
        dependency.assert_not_called()
        self.assertEqual(before, {p.name: p.stat().st_mtime_ns for p in self.assets.iterdir()})

    def test_corrupt_existing_font_is_rejected_without_replacing_or_downloading(self):
        self.create_fonts()
        corrupted = b"x" * len(self.fonts["one.ttf"])
        (self.assets / "one.ttf").write_bytes(corrupted)
        with patch.object(prepare_fonts, "download") as download:
            with self.assertRaisesRegex(prepare_fonts.FontPreparationError, "SHA256 mismatch"):
                prepare_fonts.prepare_fonts(self.assets, self.lock)
        download.assert_not_called()
        self.assertEqual((self.assets / "one.ttf").read_bytes(), corrupted)

    def test_changed_license_fails_before_any_download(self):
        (self.assets / "LICENSE.txt").write_bytes(b"changed")
        with patch.object(prepare_fonts, "download") as download:
            with self.assertRaisesRegex(prepare_fonts.FontPreparationError, "Size mismatch"):
                prepare_fonts.prepare_fonts(self.assets, self.lock)
        download.assert_not_called()

    def test_check_only_rejects_missing_fonts_without_download(self):
        with patch.object(prepare_fonts, "download") as download:
            with self.assertRaisesRegex(prepare_fonts.FontPreparationError, "Missing font assets"):
                prepare_fonts.prepare_fonts(self.assets, self.lock, check_only=True)
        download.assert_not_called()

    def test_clean_materialization_is_exact_and_only_reads_selected_zip_members(self):
        with patch.object(prepare_fonts, "download", side_effect=self.local_download):
            self.assertEqual(prepare_fonts.prepare_fonts(self.assets, self.lock), list(self.fonts))
        self.assertEqual(set(p.name for p in self.assets.iterdir()), {*self.fonts, "LICENSE.txt"})
        for name, expected in self.fonts.items():
            self.assertEqual((self.assets / name).read_bytes(), expected)
        self.assertEqual((self.assets / "LICENSE.txt").read_bytes(), self.license)

    def test_bad_second_output_publishes_neither_font_and_cleans_temporary_files(self):
        self.lock["fonts"]["two.ttf"]["sha256"] = "0" * 64
        with patch.object(prepare_fonts, "download", side_effect=self.local_download):
            with self.assertRaisesRegex(prepare_fonts.FontPreparationError, "SHA256 mismatch"):
                prepare_fonts.prepare_fonts(self.assets, self.lock)
        self.assertEqual([p.name for p in self.assets.iterdir()], ["LICENSE.txt"])

    def test_cjk_serializer_version_is_checked_before_download(self):
        self.lock["fonts"]["one.ttf"]["format"] = "ttc-face"
        with patch.object(prepare_fonts.metadata, "version", return_value="0.0"), patch.object(prepare_fonts, "download") as download:
            with self.assertRaisesRegex(prepare_fonts.FontPreparationError, "fonttools 4.61.1 is required"):
                prepare_fonts.prepare_fonts(self.assets, self.lock)
        download.assert_not_called()

    def response(self, data, *, length=None, url="https://example.invalid/fonts.zip"):
        response = io.BytesIO(data)
        response.headers = {} if length is None else {"Content-Length": str(length)}
        response.geturl = lambda: url
        return response

    def test_download_checks_hash_size_and_https(self):
        expected = {**digest(b"abc"), "url": "https://example.invalid/font"}
        destination = self.assets / "input"
        cases = [
            (b"abd", {}, "SHA256 mismatch"),
            (b"abcd", {}, "exceeds pinned size"),
            (b"ab", {}, "Size mismatch"),
            (b"abc", {"length": 4}, "Unexpected Content-Length"),
            (b"abc", {"url": "http://example.invalid/font"}, "redirected away from HTTPS"),
        ]
        for body, options, message in cases:
            with self.subTest(message=message):
                with patch.object(prepare_fonts.urllib.request, "urlopen", return_value=self.response(body, **options)):
                    with self.assertRaisesRegex(prepare_fonts.FontPreparationError, message):
                        prepare_fonts.download(expected, destination)
        with patch.object(prepare_fonts.urllib.request, "urlopen", return_value=self.response(b"abc", length=3)):
            prepare_fonts.download(expected, destination)
        self.assertEqual(destination.read_bytes(), b"abc")

    def test_download_deadline_is_bounded(self):
        expected = {**digest(b"abc"), "url": "https://example.invalid/font"}
        with patch.object(prepare_fonts.urllib.request, "urlopen", return_value=self.response(b"abc")):
            with patch.object(prepare_fonts.time, "monotonic", side_effect=[0, 121]):
                with self.assertRaisesRegex(prepare_fonts.FontPreparationError, "exceeded 120 seconds"):
                    prepare_fonts.download(expected, self.assets / "input")

    def test_committed_dependency_version_matches_recipe(self):
        lock = json.loads(prepare_fonts.LOCK_PATH.read_text(encoding="utf-8"))
        requirements = prepare_fonts.LOCK_PATH.with_name("requirements-fonts.txt").read_text(encoding="utf-8")
        self.assertIn("fonttools==" + lock["fonttools_version"], requirements.splitlines())
        # Require immutable input references, not moving upstream branch names.
        self.assertIn("165c01b46ea533872e002e0785ff17e44f6d97d8", lock["fonts"]["NotoSansCJKsc-Regular.otf"]["source"]["url"])
        self.assertIn("3012db47f3130e62f7cc0beabff968a33cbec8d8", lock["fonts"]["Roboto-Regular.ttf"]["source"]["url"])


if __name__ == "__main__":
    unittest.main()
