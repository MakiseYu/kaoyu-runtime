# Third-party runtime components

The Debian image derives from the Debian Docker team's debuerreotype artifact. The complete installed package inventory and fixed versions are recorded in `tools/runtime/debian-packages-v2.tsv` and distributed as `image-packages.tsv`. Package-specific copyright and license texts remain under `/usr/share/doc/*/copyright` inside the image. Source packages are available from the corresponding Debian source repositories; these components retain their respective licenses.

The Rust toolchain is the unmodified official Rust 1.99.1 ARM64 GNU/Linux distribution, including rustc, Cargo, the standard library, rustfmt and Clippy. Its dated manifest and per-component SHA-256 values are pinned in `tools/runtime/rust-toolchain.json`. License and third-party notices remain under `/opt/rust` in the image. Rust is primarily dual-licensed under MIT and Apache-2.0; component-specific terms continue to apply.

The Codex package is the complete, unmodified official ARM64 Linux musl release from [openai/codex rust-v0.163.0](https://github.com/openai/codex/releases/tag/rust-v0.163.0). It is licensed under Apache-2.0; its license is retained in `app/src/main/assets/licenses/Codex-LICENSE.txt`. This repository and the Android client are independent projects, not official OpenAI products.

Package versions and downloaded source inputs are fixed for this release. Build commands and input hashes are described in [BUILDING.md](BUILDING.md). No license in this repository overrides upstream component licenses.
