#!/usr/bin/env python3
"""Fetch or check the five exact official Rust ARM64 development components."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import tomllib
import urllib.request

PINS = Path(__file__).with_name("rust-toolchain.json")


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def ensure_file(destination, url, expected, check):
    if destination.is_file() and digest(destination) == expected:
        return f"Verified {destination.name} ({destination.stat().st_size:,} bytes)"
    if check:
        raise ValueError(f"Missing or invalid pinned Rust input: {destination}")
    temporary = destination.with_suffix(destination.suffix + ".part")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "kaoyu-runtime-builder/2"})
        with urllib.request.urlopen(request, timeout=120) as source, temporary.open("wb") as output:
            while data := source.read(1024 * 1024):
                output.write(data)
        if digest(temporary) != expected:
            raise ValueError(f"Official Rust checksum mismatch: {destination.name}")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return f"Downloaded and verified {destination.name} ({destination.stat().st_size:,} bytes)"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", type=Path)
    parser.add_argument("--check", action="store_true", help="Verify existing files without network access")
    args = parser.parse_args()
    pins = json.loads(PINS.read_text(encoding="utf-8"))
    args.cache.mkdir(parents=True, exist_ok=True)
    base = pins["manifest"].rsplit("/", 1)[0]
    print(ensure_file(args.cache / "channel-rust-stable.toml", pins["manifest"], pins["manifest_sha256"], args.check), flush=True)
    manifest = tomllib.loads((args.cache / "channel-rust-stable.toml").read_text(encoding="utf-8"))
    if manifest["pkg"]["rust"]["version"].split()[0] != pins["version"]:
        raise ValueError("Pinned Rust version differs from the official release manifest")

    def prepare(component):
        name = f"{component['name']}-{pins['version']}-{pins['target']}.tar.xz"
        manifest_name = component['name'] + '-preview' if component['name'] in ('rustfmt', 'clippy') else component['name']
        target = manifest["pkg"][manifest_name]["target"][pins["target"]]
        if not target["available"] or target["xz_url"] != f"{base}/{name}" or target["xz_hash"] != component["sha256"]:
            raise ValueError(f"Rust component pins differ from the official target manifest: {name}")
        destination = args.cache / name
        return ensure_file(destination, f"{base}/{name}", component["sha256"], args.check)

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for result in pool.map(prepare, pins["components"]):
            print(result, flush=True)


if __name__ == "__main__":
    main()
