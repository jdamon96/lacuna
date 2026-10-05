#!/usr/bin/env python3
"""Run with: python3 scripts/tests/test_update_appcast.py"""

import base64
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "update-appcast.py"
SPEC = importlib.util.spec_from_file_location("update_appcast", SCRIPT)
appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcast)
SIGNATURE = base64.b64encode(bytes(range(64))).decode("ascii")
NS = {"sparkle": appcast.SPARKLE}


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.feed = Path(self.directory.name) / "appcast.xml"

    def update(self, **changes):
        options = dict(
            version="0.3.0", build=5, url="https://github.com/jdamon96/lacuna/releases/download/v0.3.0/Lacuna-0.3.0-universal.zip",
            length=12345, signature=SIGNATURE, published_at=datetime(2026, 10, 5, 19, 0, tzinfo=timezone.utc),
        )
        options.update(changes)
        appcast.update_feed(self.feed, **options)

    def testCreatesSparkleRSSWithSignedZIPAndMachineBuild(self):
        self.update(release_notes="Keyboard fixes and automatic updates.")
        root = ET.parse(self.feed).getroot()
        self.assertEqual(root.tag, "rss")
        self.assertEqual(root.get("version"), "2.0")
        channel = root.find("channel")
        self.assertEqual(channel.findtext("title"), "Lacuna updates")
        item = channel.find("item")
        self.assertEqual(item.findtext("sparkle:version", namespaces=NS), "5")
        self.assertEqual(item.findtext("sparkle:shortVersionString", namespaces=NS), "0.3.0")
        self.assertEqual(item.findtext("sparkle:minimumSystemVersion", namespaces=NS), "13.0.0")
        self.assertEqual(item.findtext("pubDate"), "Mon, 05 Oct 2026 19:00:00 +0000")
        self.assertEqual(item.findtext("link"), "https://github.com/jdamon96/lacuna/releases/tag/v0.3.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get(appcast.sparkle("edSignature")), SIGNATURE)
        self.assertEqual(enclosure.get("length"), "12345")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertTrue(enclosure.get("url").endswith("Lacuna-0.3.0-universal.zip"))
        self.assertEqual(item.find("description").get(appcast.sparkle("format")), "plain-text")
        self.assertEqual(self.feed.stat().st_mode & 0o777, 0o644)

    def testEscapesPlainNotesAndURLsWithoutAllowingHTMLInjection(self):
        notes = 'Fix {braces} & <templates> "inline".\n<script>alert("no")</script> 🦉'
        url = "https://example.com/Lacuna.zip?one=1&two=2"
        self.update(url=url, release_notes=notes, minimum_system_version="13.0")
        raw = self.feed.read_text()
        item = ET.parse(self.feed).find("channel/item")
        self.assertIn("&lt;script&gt;", raw)
        self.assertNotIn("<script>", raw)
        self.assertIn("one=1&amp;two=2", raw)
        self.assertEqual(item.findtext("description"), notes)
        self.assertEqual(item.find("enclosure").get("url"), url)
        self.assertEqual(item.findtext("sparkle:minimumSystemVersion", namespaces=NS), "13.0.0")

    def testPreservesHistoricalItemsAndMetadataButBoundsAndSortsHistory(self):
        self.update(build=5, release_notes="First release")
        root = ET.parse(self.feed).getroot()
        old = root.find("channel/item")
        ET.SubElement(old, appcast.sparkle("criticalUpdate"), {appcast.sparkle("version"): "4"})
        root.find("channel").set("custom", "preserved")
        self.feed.write_bytes(ET.tostring(root))
        self.update(version="0.3.1", build=6, url="https://example.com/Lacuna-0.3.1.zip")
        items = ET.parse(self.feed).findall("channel/item")
        self.assertEqual([appcast.item_build(item) for item in items], [6, 5])
        self.assertEqual(items[1].findtext("description"), "First release")
        self.assertEqual(items[1].find("enclosure").get(appcast.sparkle("edSignature")), SIGNATURE)
        self.assertEqual(items[1].find("sparkle:criticalUpdate", NS).get(appcast.sparkle("version")), "4")
        self.assertEqual(ET.parse(self.feed).find("channel").get("custom"), "preserved")
        self.update(version="0.3.2", build=7, url="https://example.com/Lacuna-0.3.2.zip", keep=2)
        self.assertEqual([appcast.item_build(item) for item in ET.parse(self.feed).findall("channel/item")], [7, 6])
        self.update(version="0.3.3", build=8, url="https://example.com/Lacuna-0.3.3.zip", keep=1)
        self.assertEqual([appcast.item_build(item) for item in ET.parse(self.feed).findall("channel/item")], [8])

    def testRefusesBuildReuseDowngradeAndArchiveReuseWithoutChangingFeed(self):
        self.update()
        original = self.feed.read_bytes()
        for change in [dict(build=5), dict(build=4), dict(build=6), dict(build=6, version="0.3.1")]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.update(**change)
            self.assertEqual(self.feed.read_bytes(), original)

    def testRejectsInvalidInputsBeforeCreatingFeed(self):
        invalid = [
            dict(signature="not base64"), dict(signature=base64.b64encode(b"short").decode()),
            dict(signature=SIGNATURE + "\n"), dict(signature=base64.b64encode(bytes(65)).decode()),
            dict(url="http://example.com/Lacuna.zip"), dict(url="https://user:pass@example.com/Lacuna.zip"),
            dict(url="https://example.com/Lacuna.zip#fragment"), dict(url="https://example.com:wrong/Lacuna.zip"),
            dict(url="https://example.com/Lacuna.dmg"), dict(url="https://example.com/Bad File.zip"),
            dict(url="file:///tmp/Lacuna.zip"), dict(url="https://example.com\\evil/Lacuna.zip"),
            dict(version="v0.3.0"), dict(version="0.3"), dict(version="0.3.0<script>"), dict(version="00.3.0"),
            dict(build=0), dict(build=-1), dict(build="1.5"), dict(build="05"), dict(build=2**63),
            dict(length=0), dict(length=-50), dict(length="invalid"), dict(length=2**63),
            dict(minimum_system_version="13"), dict(minimum_system_version="thirteen"),
            dict(release_notes="\x00 invalid XML"), dict(release_notes=" "), dict(release_notes="x" * 32769),
            dict(keep=0), dict(keep=101), dict(published_at=datetime(2026, 10, 5)),
        ]
        for change in invalid:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.update(**change)
            self.assertFalse(self.feed.exists())

    def testRejectsMalformedExistingFeedsAndNeverOverwritesThem(self):
        bad_feeds = [
            b"not XML", b"<rss version='2.0' />", b"<rss version='1.0'><channel /></rss>",
            b"<rss version='2.0'><channel /><channel /></rss>",
            b"<!DOCTYPE rss [<!ENTITY name 'bad'>]><rss version='2.0'><channel /></rss>",
            b"<rss version='2.0'><channel><item /></channel></rss>",
        ]
        for data in bad_feeds:
            self.feed.write_bytes(data)
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.update()
            self.assertEqual(self.feed.read_bytes(), data)

    def testRemovesStaleFeedSignatureAndRetainsLegacyVersionMetadata(self):
        self.update()
        root = ET.parse(self.feed).getroot()
        item = root.find("channel/item")
        item.remove(item.find("sparkle:version", NS))
        item.find("enclosure").set(appcast.sparkle("version"), "5")
        self.feed.write_bytes(b'<!-- sparkle:edSignature="stale-signature" -->\n' + ET.tostring(root))
        self.update(version="0.3.1", build=6, url="https://example.com/Lacuna-0.3.1.zip")
        self.assertNotIn("stale-signature", self.feed.read_text())
        self.assertEqual([appcast.item_build(item) for item in ET.parse(self.feed).findall("channel/item")], [6, 5])

    def testRejectsDuplicateOrConflictingExistingBuildNumbers(self):
        self.update()
        root = ET.parse(self.feed).getroot()
        channel = root.find("channel")
        channel.append(ET.fromstring(ET.tostring(channel.find("item"))))
        self.feed.write_bytes(ET.tostring(root))
        original = self.feed.read_bytes()
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.update(build=6, url="https://example.com/new.zip")
        self.assertEqual(self.feed.read_bytes(), original)
        channel.remove(channel.findall("item")[1])
        channel.find("item/enclosure").set(appcast.sparkle("version"), "4")
        self.feed.write_bytes(ET.tostring(root))
        with self.assertRaisesRegex(ValueError, "conflicting"):
            self.update(build=6, url="https://example.com/new.zip")

    def testCLIProducesFeedAndRejectsBadArgumentsWithoutTraceback(self):
        command = [
            sys.executable, str(SCRIPT), "--feed", str(self.feed), "--version", "0.3.0", "--build", "5",
            "--url", "https://example.com/Lacuna.zip", "--length", "12345", "--signature", SIGNATURE,
            "--release-notes", "Fixes & improvements.",
        ]
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(ET.parse(self.feed).findtext("channel/item/description"), "Fixes & improvements.")
        original = self.feed.read_bytes()
        duplicate = subprocess.run(command, text=True, capture_output=True)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn("immutable", duplicate.stderr)
        self.assertNotIn("Traceback", duplicate.stderr)
        self.assertEqual(self.feed.read_bytes(), original)
        unsupported_notes = subprocess.run(command + ["--release-notes-url", "https://example.com/notes"], text=True, capture_output=True)
        self.assertNotEqual(unsupported_notes.returncode, 0)
        self.assertIn("unrecognized arguments", unsupported_notes.stderr)
        self.assertEqual(self.feed.read_bytes(), original)
        self.assertEqual(list(self.feed.parent.glob(".appcast.xml.*")), [])


if __name__ == "__main__":
    unittest.main()
