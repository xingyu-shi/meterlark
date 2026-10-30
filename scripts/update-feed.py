#!/usr/bin/env python3
"""Prepare release notes and validate metadata for one signed app update."""

import base64
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "https://github.com/xingyu-shi/meterlark"


def archive_info(info_path, archive_path):
    expected = plistlib.loads(info_path.read_bytes())
    with zipfile.ZipFile(archive_path) as archive:
        actual = plistlib.loads(archive.read("Meterlark.app/Contents/Info.plist"))
    for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
                "LSMinimumSystemVersion", "SUPublicEDKey", "SUFeedURL",
                "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
        if actual.get(key) != expected.get(key):
            raise ValueError(f"Stale update archive: {key} differs from Info.plist")
    return actual


def prepare(info_path, archive_path, staging):
    info = archive_info(info_path, archive_path)
    version = info["CFBundleShortVersionString"]
    changelog = info_path.parent.parent / "CHANGELOG.md"
    lines = changelog.read_text().splitlines()
    notes = []
    recording = False
    for line in lines:
        if line.startswith("## "):
            if recording:
                break
            recording = line.startswith(f"## {version} · ")
        elif recording:
            notes.append(line)
    if not any(line.strip() for line in notes):
        raise ValueError(f"No release notes found for version {version}")
    (staging / (archive_path.stem + ".md")).write_text("\n".join(notes).strip() + "\n")


def verify(info_path, archive_path, feed_path):
    info = archive_info(info_path, archive_path)
    version = info["CFBundleShortVersionString"]
    root = ET.parse(feed_path).getroot()
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one update item")
    item = items[0]
    for key, value in (
        ("version", info["CFBundleVersion"]),
        ("shortVersionString", version),
        ("minimumSystemVersion", info["LSMinimumSystemVersion"]),
        ("hardwareRequirements", "arm64"),
    ):
        if item.findtext(f"{{{SPARKLE}}}{key}") != value:
            raise ValueError(f"Invalid update feed metadata: {key}")
    enclosure = item.find("enclosure")
    expected_url = f"{REPOSITORY}/releases/download/v{version}/{archive_path.name}"
    if enclosure is None or enclosure.get("url") != expected_url:
        raise ValueError("Update download URL does not match the release archive")
    if enclosure.get("length") != str(archive_path.stat().st_size):
        raise ValueError("Update download length does not match the release archive")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Missing or malformed update archive signature")
    return signature


if __name__ == "__main__":
    operation, info, archive, target = sys.argv[1:]
    result = {"prepare": prepare, "verify": verify}[operation](Path(info), Path(archive), Path(target))
    if result is not None:
        print(result)
