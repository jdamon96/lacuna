#!/usr/bin/env python3
"""Add an immutable, signed ZIP release to Lacuna's static Sparkle appcast.

Sparkle recommends generate_appcast for general publishing. This small generator
deliberately supports one universal ZIP per release, integer build numbers, and
plain-text release notes, with validation and regression tests for that format.
See https://sparkle-project.org/documentation/publishing/ for the XML elements.

This script does not sign or publish anything. Sign the resulting feed with
Sparkle's sign_update after this script finishes. Rewriting a feed removes its
old signature comment, because any metadata change invalidates that signature.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PROJECT_URL = "https://github.com/jdamon96/lacuna"
MAX_FEED_BYTES = 2_000_000
MAX_INTEGER = 2**63 - 1
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
INVALID_XML = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff\ufffe\uffff]")
ET.register_namespace("sparkle", SPARKLE)


def sparkle(name: str) -> str:
    return "{" + SPARKLE + "}" + name


def positive_integer(value: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]{0,18}", value):
        raise ValueError("must be a positive integer without leading zeros")
    number = int(value)
    if number > MAX_INTEGER:
        raise ValueError("must fit in a signed 64-bit integer")
    return number


def validate_url(value: str, *, archive: bool = False) -> str:
    if not value or any(character.isspace() or ord(character) < 32 for character in value):
        raise ValueError("URLs must be nonempty HTTPS URLs without whitespace")
    try:
        url = urlsplit(value)
        valid = (
            url.scheme == "https" and url.hostname and url.username is None
            and url.password is None and not url.fragment and url.port != 0
        )
    except ValueError as error:
        raise ValueError("URLs must be valid HTTPS URLs") from error
    if not valid or "\\" in value or INVALID_XML.search(value):
        raise ValueError("URLs must use HTTPS without credentials or fragments")
    if archive and not url.path.lower().endswith(".zip"):
        raise ValueError("the download URL must name a ZIP archive")
    return value


def validate_signature(value: str) -> str:
    try:
        signature = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("signature must be a base64-encoded 64-byte Ed25519 signature") from error
    if len(signature) != 64 or base64.b64encode(signature).decode("ascii") != value:
        raise ValueError("signature must be a base64-encoded 64-byte Ed25519 signature")
    return value


def validate_version(value: str, *, minimum: bool = False) -> str:
    if minimum and re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        value += ".0"
    if len(value) > 64 or not VERSION.fullmatch(value):
        raise ValueError("versions must use numeric major.minor.patch, for example 0.3.0")
    return value


def load_feed(path: Path) -> tuple[ET.Element, ET.Element]:
    if not path.exists():
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Lacuna updates"
        ET.SubElement(channel, "link").text = PROJECT_URL
        ET.SubElement(channel, "description").text = "Updates for Lacuna for macOS."
        ET.SubElement(channel, "language").text = "en"
        return root, channel
    if path.stat().st_size > MAX_FEED_BYTES:
        raise ValueError("existing appcast exceeds the size limit")
    data = path.read_bytes()
    if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("appcasts must not contain a DTD or entity declarations")
    try:
        # The default parser discards comments, including a stale feed signature.
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise ValueError("existing appcast is not valid XML") from error
    channels = root.findall("channel")
    if root.tag != "rss" or root.get("version") != "2.0" or len(channels) != 1:
        raise ValueError("existing appcast must be RSS 2.0 with exactly one channel")
    return root, channels[0]


def item_build(item: ET.Element) -> int:
    versions = item.findall(sparkle("version"))
    enclosure = item.find("enclosure")
    if len(versions) > 1:
        raise ValueError("existing release has multiple build numbers")
    value = versions[0].text if versions else None
    # Preserve feeds using Sparkle's formerly recommended enclosure attributes.
    legacy = enclosure.get(sparkle("version")) if enclosure is not None else None
    if value is not None and legacy is not None and value != legacy:
        raise ValueError("existing release has conflicting build numbers")
    try:
        return positive_integer(value if value is not None else legacy or "")
    except ValueError as error:
        raise ValueError("existing releases must have positive integer build numbers") from error


def update_feed(
    path: Path, *, version: str, build: int, url: str, length: int, signature: str,
    minimum_system_version: str = "13.0.0", release_notes: str | None = None,
    keep: int = 20, published_at: datetime | None = None,
) -> None:
    """Validate the complete update before atomically replacing the public feed."""
    version = validate_version(version)
    minimum_system_version = validate_version(minimum_system_version, minimum=True)
    build = positive_integer(str(build))
    length = positive_integer(str(length))
    keep = positive_integer(str(keep))
    if keep > 100:
        raise ValueError("keep must be between 1 and 100 releases")
    url = validate_url(url, archive=True)
    signature = validate_signature(signature)
    if release_notes is not None:
        if not release_notes.strip() or len(release_notes) > 32_768 or INVALID_XML.search(release_notes):
            raise ValueError("release notes must contain 1–32768 characters of valid XML text")
    date = published_at or datetime.now(timezone.utc)
    if date.tzinfo is None or date.utcoffset() is None:
        raise ValueError("publication date must include a time zone")

    root, channel = load_feed(path)
    history = channel.findall("item")
    builds = [item_build(item) for item in history]
    if len(builds) != len(set(builds)):
        raise ValueError("existing appcast contains duplicate build numbers")
    if build in builds:
        raise ValueError("that build already exists; published releases are immutable")
    if builds and build <= max(builds):
        raise ValueError("new build must be greater than every existing build")
    if any(enclosure.get("url") == url for item in history for enclosure in item.findall("enclosure")):
        raise ValueError("that download URL already exists; use a new immutable release archive")

    item = ET.Element("item")
    ET.SubElement(item, "title").text = "Lacuna " + version
    ET.SubElement(item, "link").text = PROJECT_URL + "/releases/tag/v" + version
    ET.SubElement(item, sparkle("version")).text = str(build)
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = minimum_system_version
    ET.SubElement(item, "pubDate").text = format_datetime(date.astimezone(timezone.utc))
    if release_notes is not None:
        ET.SubElement(item, "description", {sparkle("format"): "plain-text"}).text = release_notes
    ET.SubElement(item, "enclosure", {
        "url": url, sparkle("edSignature"): signature,
        "length": str(length), "type": "application/octet-stream",
    })

    for previous in history:
        channel.remove(previous)
    channel.append(item)
    for _, previous in sorted(zip(builds, history), key=lambda pair: pair[0], reverse=True)[:keep - 1]:
        channel.append(previous)
    ET.indent(root, space="  ")
    output = ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"
    if len(output) > MAX_FEED_BYTES:
        raise ValueError("updated appcast exceeds the size limit")

    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix="." + path.name + ".", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            os.fchmod(handle.fileno(), 0o644)
            handle.write(output)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--feed", type=Path, default=Path("appcast.xml"))
    parser.add_argument("--version", required=True, help="numeric marketing version, for example 0.3.0")
    parser.add_argument("--build", required=True, help="strictly increasing integer CFBundleVersion")
    parser.add_argument("--url", required=True, help="immutable HTTPS URL of the signed ZIP")
    parser.add_argument("--length", required=True, help="ZIP byte length from Sparkle sign_update")
    parser.add_argument("--signature", required=True, help="ZIP EdDSA signature from Sparkle sign_update")
    parser.add_argument("--minimum-system-version", default="13.0.0")
    parser.add_argument("--release-notes", help="inline plain text, escaped in XML and covered by the feed signature")
    parser.add_argument("--keep", default="20", help="retain this many recent releases (1–100; default 20)")
    args = parser.parse_args()
    try:
        update_feed(
            args.feed, version=args.version, build=args.build, url=args.url, length=args.length,
            signature=args.signature, minimum_system_version=args.minimum_system_version,
            release_notes=args.release_notes, keep=args.keep,
        )
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(f"Updated {args.feed} with Lacuna {args.version} (build {args.build}). Sign the feed before publishing.")


if __name__ == "__main__":
    main()
