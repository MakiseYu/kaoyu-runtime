#!/usr/bin/env python3
"""Reproducibly split an exact pinned image without extracting payloads.

Usage: python3 tools/split-runtime.py --output-dir /path/to/release-artifacts
The resulting files are NOT bundled into the APK. Their SHA-256 and size pins
are written only to OUTPUT_DIR/packages.properties for release review. Every payload,
owner, mode, timestamp, and link target is verified against the original image.
No downloads, package updates, or payload modifications are performed.
"""
from pathlib import Path
import argparse
import contextlib
import copy
import gzip
import importlib.util
import sys
import json
import os
import shutil
import tarfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("verify_runtime", Path(__file__).with_name("verify-runtime.py"))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--source-image", type=Path, default=verify.ASSETS / "debian-arm64.tar.gz")
    parser.add_argument("--source-manifest", type=Path, help="Explicit image.properties for a newly built image")
    parser.add_argument("--inventory", type=Path, help="Explicit image-packages.tsv for a newly built image")
    parser.add_argument("--runtime-revision", type=int, choices=(1, 2), default=2)
    parser.add_argument("--release-tag", default="runtime-arm64-v2")
    parser.add_argument("--min-client", type=int, default=300)
    parser.add_argument("--reuse-codex", type=Path, help="Reuse exact Codex v1 gzip bytes; its full inventory must still match the source image")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    verify.require(not output.is_relative_to(verify.ASSETS.resolve()), "Release packages must stay outside APK assets")
    source_info = verify.source_manifest(args.source_image, args.source_manifest)
    print(f"Source image checksum verified: {source_info['sha256']}", flush=True)
    # Validate before opening any output, including unsupported records and
    # link topology. No archive entry is ever written into the host filesystem.
    original = verify.scan_archive(args.source_image)
    output.mkdir(parents=True, exist_ok=True)
    fixed = verify.release_fields(args.runtime_revision, args.release_tag, args.min_client)
    paths = {package: output / fixed[f"{package}.archive"] for package in ("debian", "codex")}
    temporary = {package: path.with_suffix(path.suffix + ".part") for package, path in paths.items()}
    counts = {package: 0 for package in paths}
    try:
        with contextlib.ExitStack() as stack:
            archives = {}
            for package, path in temporary.items():
                if package == "codex" and args.reuse_codex:
                    continue
                raw = stack.enter_context(path.open("wb"))
                compressed = stack.enter_context(gzip.GzipFile(filename="", mode="wb", compresslevel=9, mtime=0, fileobj=raw))
                archives[package] = stack.enter_context(tarfile.open(fileobj=compressed, mode="w|", format=tarfile.GNU_FORMAT))
            with tarfile.open(args.source_image, "r|gz") as source:
                for member in source:
                    name = verify.canonical_name(member.name)
                    package = verify.package_for(name)
                    counts[package] += 1
                    if package == "codex" and args.reuse_codex:
                        continue
                    preserved = copy.copy(member)
                    preserved.name = name
                    payload = source.extractfile(member) if member.isfile() else None
                    archives[package].addfile(preserved, payload)
        if args.reuse_codex:
            verify.require(verify.sha256(args.reuse_codex) == verify.CODEX_V1_SHA256, "Reused Codex archive differs from the pinned v1 release")
            shutil.copyfile(args.reuse_codex, temporary["codex"])
        manifest = dict(fixed)
        scans = {}
        for package, path in temporary.items():
            scan = verify.scan_archive(path, package)
            scans[package] = scan
            manifest[f"{package}.bytes"] = str(path.stat().st_size)
            manifest[f"{package}.sha256"] = verify.sha256(path)
            manifest[f"{package}.tar.bytes"] = str(scan["tar_bytes"])
            manifest[f"{package}.unpacked.bytes"] = str(scan["unpacked_bytes"])
            verify.verify_package(path, package, manifest, args.inventory)
        combined = {name: value for scan in scans.values() for name, value in scan["entries"].items()}
        verify.require(sum(len(scan["entries"]) for scan in scans.values()) == len(combined), "Overlapping package paths")
        verify.require(combined == original["entries"], "Split changed the source inventory, payloads, metadata, or links")
        manifest_text = "\n".join(f"{key}={value}" for key, value in manifest.items()) + "\n"
        manifest_temp = output / "packages.properties.part"
        manifest_temp.write_bytes(manifest_text.encode("ascii"))
        verify.load_manifest(manifest_temp)
        for package, path in paths.items():
            os.replace(temporary[package], path)
        os.replace(manifest_temp, output / "packages.properties")
        if args.runtime_revision == 2:
            (output / "runtime.properties").write_bytes(manifest_text.encode("ascii"))
        report = {
            "format": 1, "source_archive": args.source_image.name,
            "source_sha256": source_info["sha256"],
            "source_bytes": int(source_info["bytes"]),
            "source_entries": len(original["entries"]),
            "source_regular_payload_bytes": original["unpacked_bytes"],
            "payload_metadata_link_equivalence": True,
            "disjoint_archives": True,
            "canonical_root_relative_paths": True,
            "gzip_timestamp": 0, "gzip_original_filename": None,
            "tar_format": "GNU", "compression_level": 9,
            "packages": {package: {"archive": paths[package].name, "entries": counts[package], **{field: manifest[f"{package}.{field}"] for field in verify.PIN_FIELDS}} for package in paths},
        }
        (output / "split-verification.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(manifest_text, end="", flush=True)
        print(f"Verified lossless disjoint union: {len(combined):,} entries, {original['unpacked_bytes']:,} regular payload bytes.", flush=True)
        print(f"Release artifacts: {output}", flush=True)
    finally:
        for path in temporary.values():
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, EOFError) as error:
        raise SystemExit(f"Runtime split failed: {error}")
