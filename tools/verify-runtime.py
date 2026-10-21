#!/usr/bin/env python3
"""Verify the APK's pinned two-package manifest and optional release archives.

A normal app build needs only packages.properties and the small runtime assets.
Use --packages-dir DIR to verify downloaded/built packages. Add --source-image
PATH to prove their complete, disjoint union equals the pinned source runtime.
No manifest from a chosen package directory is ever read or trusted.
"""
from pathlib import Path
import argparse
import gzip
import hashlib
import json
import posixpath
import re
import struct
import tarfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "app/src/main/assets/runtime"
MANIFEST = ASSETS / "packages.properties"
FIXED = {
    "format": "2",
    "architecture": "arm64-v8a",
    "runtime.compatibility": "1",
    "debian.version": "12-bookworm",
    "codex.version": "0.163.0",
    "debian.archive": "kaoyu-debian-12-bookworm-arm64-v1.tar.gz",
    "codex.archive": "kaoyu-codex-0.163.0-arm64-v1.tar.gz",
}
PIN_FIELDS = ("bytes", "sha256", "tar.bytes", "unpacked.bytes")
CHUNK = 1024 * 1024
CODEX_V1_SHA256 = "c2b0e7f1396928aaab45f10a4fe42da54a75dd4fa3b1f79543dcd5cffa5dcd21"
REVISION_FIELDS = {"runtime.revision", "client.min.version", "debian.revision", "codex.revision", "debian.url", "codex.url"}


def release_fields(revision=2, release_tag="runtime-arm64-v2", min_client=300):
    fields = dict(FIXED)
    if revision == 1:
        return fields
    require(revision == 2, "Unsupported runtime build revision")
    require(re.fullmatch(r"[A-Za-z0-9._-]+", release_tag), "Invalid release tag")
    fields.update({"runtime.revision": str(revision), "client.min.version": str(min_client),
                   "debian.revision": "2", "codex.revision": "1",
                   "debian.archive": "kaoyu-debian-12-bookworm-arm64-v2.tar.gz"})
    for package in ("debian", "codex"):
        fields[f"{package}.url"] = f"https://github.com/MakiseYu/kaoyu-runtime/releases/download/{release_tag}/{fields[f'{package}.archive']}"
    return fields


def require(condition, message):
    if not condition:
        raise ValueError(message)


def properties(path):
    result = {}
    for number, raw in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        require("=" in line, f"{path}:{number}: expected key=value")
        key, value = line.split("=", 1)
        require(key and key == key.strip() and value == value.strip(), f"{path}:{number}: invalid whitespace")
        require(key not in result, f"{path}:{number}: duplicate property {key}")
        result[key] = value
    return result


def load_manifest(path=MANIFEST):
    result = properties(path)
    expected = set(FIXED) | {f"{package}.{field}" for package in ("debian", "codex") for field in PIN_FIELDS}
    revised = "runtime.revision" in result
    if revised:
        expected |= REVISION_FIELDS
    require(set(result) == expected, f"Invalid manifest keys: missing={sorted(expected - set(result))}, unexpected={sorted(set(result) - expected)}")
    for key, value in FIXED.items():
        if revised and key == "debian.archive":
            value = "kaoyu-debian-12-bookworm-arm64-v2.tar.gz"
        require(result[key] == value, f"Unsupported manifest {key}: {result[key]}")
    if revised:
        require(result["runtime.revision"] == "2" and result["debian.revision"] == "2" and result["codex.revision"] == "1", "Unsupported component revision")
        require(re.fullmatch(r"[1-9][0-9]*", result["client.min.version"]), "Invalid minimum client version")
        require(result["codex.sha256"] == CODEX_V1_SHA256, "Codex v1 bytes must remain unchanged")
        for package in ("debian", "codex"):
            url = urlsplit(result[f"{package}.url"])
            require(url.scheme == "https" and url.netloc == "github.com" and not url.query and not url.fragment
                    and re.fullmatch(r"/MakiseYu/kaoyu-runtime/releases/download/[A-Za-z0-9._-]+/" + re.escape(result[f"{package}.archive"]), url.path), "Invalid runtime release URL")
    for package in ("debian", "codex"):
        require(re.fullmatch(r"[0-9a-f]{64}", result[f"{package}.sha256"]), f"Invalid {package} checksum")
        for field in ("bytes", "tar.bytes", "unpacked.bytes"):
            value = result[f"{package}.{field}"]
            require(re.fullmatch(r"[1-9][0-9]*", value), f"Invalid {package}.{field}")
            require(int(value) < 4 * 1024**3, f"Unreasonable {package}.{field}")
        require(int(result[f"{package}.tar.bytes"]) % 10240 == 0, f"{package} tar must use GNU 10 KiB records")
        require(int(result[f"{package}.unpacked.bytes"]) < int(result[f"{package}.tar.bytes"]), f"Invalid {package} unpacked bound")
    return result


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_manifest(source, manifest_path=None):
    result = properties(manifest_path or ASSETS / "image.properties")
    require(result.get("format") == "1", "Unsupported source image manifest")
    require(result.get("archive") == "debian-arm64.tar.gz", "Unexpected source image name")
    for package in ("debian", "codex"):
        require(result.get(f"{package}.version") == FIXED[f"{package}.version"], f"Source {package} version mismatch")
    require(source.is_file(), f"Missing pinned source image: {source}")
    require(source.stat().st_size == int(result["bytes"]), "Source image size mismatch")
    require(sha256(source) == result["sha256"], "Source image SHA-256 mismatch")
    return result


def canonical_name(name):
    require("\0" not in name and "\\" not in name and not name.startswith("/"), f"Unsafe archive path: {name!r}")
    while name.startswith("./"):
        name = name[2:]
    name = name.rstrip("/")
    if name in ("", "."):
        return "."
    require(all(part not in ("", ".", "..") for part in name.split("/")), f"Unsafe archive path: {name!r}")
    require(not any(ord(c) < 32 or ord(c) == 127 for c in name), f"Control character in archive path: {name!r}")
    return name


def package_for(name):
    return "codex" if name == "opt/codex" or name.startswith("opt/codex/") else "debian"


def _read_exact(stream, length):
    data = stream.read(length)
    require(len(data) == length, "Truncated tar record")
    return data


def scan_archive(path, package=None, expected_tar_bytes=None):
    """Validate raw GNU records, hashing payloads without extracting to disk.

    Unlike tarfile iteration this also rejects PAX/device/FIFO records, archives
    concatenated after the terminator, and nonzero trailing data. GNU long-name
    and long-link records are the only extension records accepted.
    """
    entries = {}
    unpacked = 0
    total = 0
    long_name = long_link = None
    with gzip.open(path, "rb") as stream:
        while True:
            header = _read_exact(stream, 512)
            total += 512
            if header == bytes(512):
                require(long_name is None and long_link is None, "Dangling GNU extension record")
                require(_read_exact(stream, 512) == bytes(512), "Missing second tar end record")
                total += 512
                while True:
                    chunk = stream.read(CHUNK)
                    if not chunk:
                        break
                    require(not any(chunk), "Nonzero data after tar terminator")
                    total += len(chunk)
                break
            require(header[257:265] == b"ustar  \x00", "Only GNU-format tar headers are supported")
            member = tarfile.TarInfo.frombuf(header, "utf-8", "surrogateescape")
            require(member.size >= 0, "Negative archive entry size")
            if member.type in (tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
                require(0 < member.size <= 65536, "Invalid GNU extension size")
                payload = _read_exact(stream, member.size)
                padding = (512 - member.size % 512) % 512
                require(not any(_read_exact(stream, padding)), "Nonzero GNU extension padding")
                total += member.size + padding
                require(payload.endswith(b"\0") and b"\0" not in payload[:-1], "Invalid GNU extended name")
                value = payload[:-1].decode("utf-8", "surrogateescape")
                if member.type == tarfile.GNUTYPE_LONGNAME:
                    require(long_name is None, "Duplicate GNU long-name record")
                    long_name = value
                else:
                    require(long_link is None, "Duplicate GNU long-link record")
                    long_link = value
                continue
            require(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE, tarfile.SYMTYPE, tarfile.LNKTYPE), f"Unsupported archive entry type {member.type!r}")
            if long_name is not None:
                member.name = long_name
            if long_link is not None:
                member.linkname = long_link
            long_name = long_link = None
            name = canonical_name(member.name)
            require(name not in entries, f"Duplicate archive path: {name}")
            require(name != "." or member.isdir(), "Root archive entry is not a directory")
            if package:
                require(package_for(name) == package, f"{package} package contains out-of-scope path: {name}")
                require(member.name.rstrip("/") == name, f"Noncanonical package path: {member.name}")
            require(member.uid == 0 and member.gid == 0, f"Unexpected owner for {name}")
            require(member.mode >= 0 and member.mode <= 0o7777, f"Invalid mode for {name}")
            if not member.isfile():
                require(member.size == 0, f"Payload on nonregular archive entry: {name}")
            if member.issym():
                target = member.linkname
                require(target and "\0" not in target and "\\" not in target, f"Unsafe symlink: {name}")
                # Absolute links are guest-root links, necessary for Debian.
                resolved = posixpath.normpath(target if target.startswith("/") else posixpath.join(posixpath.dirname(name), target))
                require(resolved != ".." and not resolved.startswith("../"), f"Escaping symlink: {name}")
            if member.islnk():
                target = canonical_name(member.linkname)
                require(target in entries and entries[target]["type"] == "file", f"Hardlink target must be an earlier regular file: {name}")
                if package:
                    require(package_for(target) == package, f"Cross-package hardlink: {name}")
            digest = hashlib.sha256()
            prefix = b""
            metadata_payload = bytearray() if name in ("opt/codex/codex-package.json", "usr/lib/os-release") else None
            if metadata_payload is not None:
                require(member.isfile() and member.size <= 16384, f"Invalid embedded version manifest: {name}")
            remaining = member.size
            while remaining:
                data = _read_exact(stream, min(remaining, CHUNK))
                if len(prefix) < 64:
                    prefix += data[:64 - len(prefix)]
                digest.update(data)
                if metadata_payload is not None:
                    metadata_payload.extend(data)
                remaining -= len(data)
            if name == "opt/codex/codex-package.json":
                metadata = json.loads(metadata_payload)
                require(metadata.get("version") == FIXED["codex.version"] and metadata.get("layoutVersion") == 1 and metadata.get("target") == "aarch64-unknown-linux-musl", "Embedded Codex version, layout, or architecture mismatch")
            if name == "usr/lib/os-release":
                metadata = dict(line.split("=", 1) for line in metadata_payload.decode("utf-8").splitlines() if "=" in line)
                require(metadata.get("ID", "").strip(chr(34)) == "debian" and metadata.get("VERSION_ID", "").strip(chr(34)) == "12" and metadata.get("VERSION_CODENAME", "").strip(chr(34)) == "bookworm", "Embedded Debian version mismatch")
            padding = (512 - member.size % 512) % 512
            require(not any(_read_exact(stream, padding)), f"Nonzero tar padding: {name}")
            total += member.size + padding
            kind = "file" if member.isfile() else "directory" if member.isdir() else "symlink" if member.issym() else "hardlink"
            entries[name] = {
                "type": kind, "size": member.size, "mode": member.mode,
                "uid": member.uid, "gid": member.gid, "uname": member.uname,
                "gname": member.gname, "mtime": member.mtime,
                "linkname": member.linkname, "devmajor": member.devmajor,
                "devminor": member.devminor,
                "sha256": digest.hexdigest() if member.isfile() else None,
            }
            if member.isfile():
                unpacked += member.size
                if name in ("opt/codex/bin/codex", "opt/codex/bin/codex-code-mode-host", "opt/codex/codex-path/rg", "opt/codex/codex-resources/bwrap", "usr/bin/bash", "usr/bin/git", "usr/bin/node", "usr/bin/python3.11", "opt/rust/bin/rustc", "opt/rust/bin/cargo", "opt/rust/bin/rustfmt", "opt/rust/bin/clippy-driver", "usr/bin/aarch64-linux-gnu-gcc-12", "usr/bin/aarch64-linux-gnu-g++-12", "usr/bin/cmake", "usr/bin/ninja"):
                    require(prefix[:6] == b"\x7fELF\x02\x01" and len(prefix) >= 20 and struct.unpack_from("<H", prefix, 18)[0] == 183, f"Expected ARM64 ELF executable: {name}")
                    require(member.mode & 0o111, f"Missing executable mode: {name}")
    require(total % 10240 == 0, "Tar does not end on a GNU 10 KiB record boundary")
    if expected_tar_bytes is not None:
        require(total == expected_tar_bytes, f"Tar length mismatch: {path.name}")
    for name in entries:
        ancestor = posixpath.dirname(name)
        while ancestor:
            if ancestor in entries:
                require(entries[ancestor]["type"] == "directory", f"Archive writes through nondirectory ancestor: {name}")
            ancestor = posixpath.dirname(ancestor)
    return {"entries": entries, "tar_bytes": total, "unpacked_bytes": unpacked}


def verify_package(path, package, manifest, inventory=None):
    require(path.is_file(), f"Missing {package} package: {path}")
    require(path.stat().st_size == int(manifest[f"{package}.bytes"]), f"{package} gzip size mismatch")
    checksum = sha256(path)
    require(checksum == manifest[f"{package}.sha256"], f"{package} SHA-256 mismatch")
    with path.open("rb") as stream:
        header = stream.read(10)
    require(header[:8] == b"\x1f\x8b\x08\x00\x00\x00\x00\x00", f"{package} gzip must omit filename and timestamp")
    scan = scan_archive(path, package, int(manifest[f"{package}.tar.bytes"]))
    require(scan["unpacked_bytes"] == int(manifest[f"{package}.unpacked.bytes"]), f"{package} unpacked payload size mismatch")
    required = ("opt/codex/bin/codex", "opt/codex/bin/codex-code-mode-host", "opt/codex/codex-path/rg", "opt/codex/codex-resources/bwrap", "opt/codex/codex-package.json") if package == "codex" else ("usr/bin/bash", "usr/bin/git", "usr/bin/node", "usr/bin/python3.11", "usr/local/share/kaoyu/packages.tsv", "usr/lib/os-release", "opt")
    require(all(name in scan["entries"] for name in required), f"{package} lacks required runtime paths")
    if package == "debian":
        package_list = inventory or ASSETS / "image-packages.tsv"
        require(scan["entries"]["usr/local/share/kaoyu/packages.tsv"]["sha256"] == sha256(package_list), "Debian installed-package inventory differs from image-packages.tsv")
        if manifest.get("debian.revision") == "2":
            require(sha256(package_list) == sha256(ROOT / "tools/runtime/debian-packages-v2.tsv"), "Debian v2 inventory differs from the fixed build dependency lock")
            tools = ("usr/bin/aarch64-linux-gnu-gcc-12", "usr/bin/aarch64-linux-gnu-g++-12", "usr/bin/make", "usr/bin/cmake", "usr/bin/ninja", "usr/bin/pkg-config", "usr/bin/zip", "usr/bin/unzip", "usr/bin/xz", "usr/bin/file", "usr/bin/patch", "usr/bin/sqlite3", "usr/include/python3.11/Python.h", "opt/rust/bin/rustc", "opt/rust/bin/cargo", "opt/rust/bin/rustfmt", "opt/rust/bin/cargo-clippy", "opt/rust/bin/clippy-driver", "usr/local/share/kaoyu/rust-toolchain.json", "usr/local/share/kaoyu/test-development.sh")
            require(all(name in scan["entries"] for name in tools), "Debian v2 lacks a required default development tool")
            require(scan["entries"]["usr/local/share/kaoyu/rust-toolchain.json"]["sha256"] == sha256(ROOT / "tools/runtime/rust-toolchain.json"), "Rust toolchain source pins differ from the supported toolchain")
            require(scan["entries"]["usr/local/share/kaoyu/test-development.sh"]["sha256"] == sha256(ROOT / "tools/runtime/test-development.sh"), "Development smoke test differs from the checked-in test")
    return scan


def verify_union(source, scans, source_properties=None):
    source_info = source_manifest(source, source_properties)
    original = scan_archive(source)
    combined = {}
    for package, scan in scans.items():
        require(not (combined.keys() & scan["entries"].keys()), "Packages have overlapping paths")
        combined.update(scan["entries"])
    require(combined.keys() == original["entries"].keys(), "Split union differs from source path inventory")
    for name, expected in original["entries"].items():
        require(combined[name] == expected, f"Split union changes bytes, metadata, or link target: {name}")
    return {"source_sha256": source_info["sha256"], "entries": len(combined), "unpacked_bytes": original["unpacked_bytes"], "payload_metadata_link_equivalence": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages-dir", type=Path, help="Directory containing the two separately distributed packages")
    parser.add_argument("--source-image", type=Path, help="Additionally prove complete union equivalence to this pinned source image")
    parser.add_argument("--manifest", type=Path, default=MANIFEST, help="Explicit trusted local release manifest (never discovered in a package directory)")
    parser.add_argument("--source-manifest", type=Path, help="Explicit source image.properties for a newly built image")
    parser.add_argument("--inventory", type=Path, help="Explicit installed-package inventory for a newly built image")
    args = parser.parse_args()
    require(not args.source_image or args.packages_dir, "--source-image requires --packages-dir")
    manifest = load_manifest(args.manifest)
    for path in ASSETS.glob("*.sh"):
        require(b"\r" not in path.read_bytes(), f"Runtime shell script must use LF line endings: {path.name}")
    print("Pinned runtime manifest verified: format 2, ARM64, compatibility 1; no bulk package required for app builds.")
    if args.packages_dir:
        scans = {}
        for package in ("debian", "codex"):
            path = args.packages_dir / manifest[f"{package}.archive"]
            scans[package] = verify_package(path, package, manifest, args.inventory)
            print(f"{package}: {path.stat().st_size:,} gzip bytes, {len(scans[package]['entries']):,} entries, SHA-256 {manifest[f'{package}.sha256']}")
        if args.source_image:
            print("Split equivalence verified: " + json.dumps(verify_union(args.source_image, scans, args.source_manifest), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, EOFError) as error:
        raise SystemExit(f"Runtime verification failed: {error}")
