import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("update_feed", ROOT / "scripts/update-feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        (self.root / "Resources").mkdir()
        self.info_path = self.root / "Resources/Info.plist"
        self.info = {
            "CFBundleIdentifier": "com.example.meterlark",
            "CFBundleVersion": "42",
            "CFBundleShortVersionString": "2.0.0",
            "LSMinimumSystemVersion": "14.0",
            "SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
            "SUFeedURL": feed.REPOSITORY + "/releases/latest/download/appcast.xml",
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
        }
        self.info_path.write_bytes(plistlib.dumps(self.info))
        self.archive = self.root / "Meterlark-2.0.0-arm64.zip"
        self.write_archive(self.info)
        self.signature = base64.b64encode(bytes(64)).decode()
        self.feed_path = self.root / "appcast.xml"
        self.xml = ET.Element("rss")
        channel = ET.SubElement(self.xml, "channel")
        self.item = ET.SubElement(channel, "item")
        for name, value in [("version", "42"), ("shortVersionString", "2.0.0"),
                            ("minimumSystemVersion", "14.0"), ("hardwareRequirements", "arm64")]:
            ET.SubElement(self.item, f"{{{feed.SPARKLE}}}{name}").text = value
        self.enclosure = ET.SubElement(self.item, "enclosure", {
            "url": feed.REPOSITORY + "/releases/download/v2.0.0/" + self.archive.name,
            "length": str(self.archive.stat().st_size),
            f"{{{feed.SPARKLE}}}edSignature": self.signature,
        })

    def write_archive(self, info):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Meterlark.app/Contents/Info.plist", plistlib.dumps(info))

    def verify(self):
        ET.ElementTree(self.xml).write(self.feed_path)
        return feed.verify(self.info_path, self.archive, self.feed_path)

    def test_internal_build_and_display_version_are_not_interchanged(self):
        self.assertEqual(self.verify(), self.signature)
        self.item.find(f"{{{feed.SPARKLE}}}version").text = "2.0.0"
        with self.assertRaisesRegex(ValueError, "version"):
            self.verify()

    def test_rotated_public_key_rejects_stale_archive_with_same_version(self):
        self.write_archive({**self.info, "SUPublicEDKey": base64.b64encode(bytes([1]) * 32).decode()})
        with self.assertRaisesRegex(ValueError, "SUPublicEDKey"):
            self.verify()

    def test_release_asset_url_cannot_point_to_another_version(self):
        self.enclosure.set("url", feed.REPOSITORY + "/releases/download/v1.0.0/old.zip")
        with self.assertRaisesRegex(ValueError, "URL"):
            self.verify()

    def test_archive_replacement_changes_download_length(self):
        self.enclosure.set("length", str(self.archive.stat().st_size + 1))
        with self.assertRaisesRegex(ValueError, "length"):
            self.verify()

    def test_wrong_architecture_is_rejected(self):
        self.item.find(f"{{{feed.SPARKLE}}}hardwareRequirements").text = "x86_64"
        with self.assertRaisesRegex(ValueError, "hardwareRequirements"):
            self.verify()

    def test_missing_archive_signature_is_rejected(self):
        self.enclosure.attrib.pop(f"{{{feed.SPARKLE}}}edSignature")
        with self.assertRaisesRegex(ValueError, "signature"):
            self.verify()

    def test_old_update_items_are_not_included(self):
        ET.SubElement(self.xml.find("channel"), "item")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify()

    def test_release_notes_are_taken_only_from_the_matching_version(self):
        (self.root / "CHANGELOG.md").write_text(
            "## Unreleased\n\n- Future change\n\n## 2.0.0 · 2026-10-29\n\n"
            "### Added\n\n- App updates\n\n## 1.0.0 · 2026-10-23\n\n- Old change\n"
        )
        feed.prepare(self.info_path, self.archive, self.root)
        notes = (self.root / (self.archive.stem + ".md")).read_text()
        self.assertIn("App updates", notes)
        self.assertNotIn("Future change", notes)
        self.assertNotIn("Old change", notes)

    def test_missing_release_notes_abort_publication(self):
        (self.root / "CHANGELOG.md").write_text("## Unreleased\n\n- Future change\n")
        with self.assertRaisesRegex(ValueError, "No release notes"):
            feed.prepare(self.info_path, self.archive, self.root)


if __name__ == "__main__":
    unittest.main()
