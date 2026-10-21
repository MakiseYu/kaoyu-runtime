# 制作与发布运行包

需要 Linux root、Python 3、curl、tar/xz/gzip、支持 ARM64 的 QEMU/binfmt（非 ARM64 主机）和充足磁盘空间。构建在私有 mount namespace 中完成，临时树位于 `/var/tmp/kaoyu-image.*`；脚本退出时卸载临时挂载，保留临时树供检查。

构建输入固定为：

- Debian 基础 rootfs：`debuerreotype/docker-debian-artifacts` 提交 `cf1f4a45447842b45e9952e0f018ae734a7341c7` 的 `bookworm/oci/blobs/rootfs.tar.gz`，SHA-256 `2a02c40189e361a19e7cb07374fe9925f5c4f7db254ae2b9196348c27c286b03`。
- Codex：官方 `openai/codex` 的 `rust-v0.163.0` Release，资产 `codex-package-aarch64-unknown-linux-musl.tar.gz`，SHA-256 `9d8ecf2d19d3e184877983902d6c85de48b3888dcb72c382a8a0c975845927fb`。
- Rust：`tools/runtime/rust-toolchain.json` 中的官方日期清单、版本、目标架构与每组件摘要。
- Debian 包：`tools/runtime/debian-packages-v2.tsv` 固定全部已解析版本；源不再提供这些版本时构建失败，不能静默替换版本。发行版源的长期可用性与归档快照另行维护。

```sh
python3 tools/runtime/prepare-rust.py cache/rust-1.99.1
sudo bash tools/runtime/build-image.sh cache/base-rootfs.tar.gz cache/codex-package.tar.gz dist/source cache/rust-1.99.1
python3 tools/split-runtime.py --source-image dist/source/debian-arm64.tar.gz --source-manifest dist/source/image.properties --inventory dist/source/image-packages.tsv --output-dir dist/runtime-arm64-v2 --reuse-codex cache/kaoyu-codex-0.163.0-arm64-v1.tar.gz
python3 tools/verify-runtime.py --packages-dir dist/runtime-arm64-v2 --manifest dist/runtime-arm64-v2/packages.properties --inventory dist/source/image-packages.tsv --source-image dist/source/debian-arm64.tar.gz --source-manifest dist/source/image.properties
```

`--reuse-codex` 需要已校验的旧 v1 分体包。新 Debian 内的 `/opt/codex` 原始记录必须与该包完全相同，才能复用其压缩字节。拆分工具不会自动覆盖客户端内置 pins。

默认工具链烟测以非 Root 用户执行真实 C/C++、CMake/Ninja、Python 原生扩展/venv、Node/npm、Rust 构建与单测、rustfmt 和 Clippy；这不替代 Android 保护环境下的真机测试。

发布前复制审核过的清单和包清单到客户端，使用独立私钥对 `runtime.properties` 原始字节做 SHA256withRSA 签名。签名文件同时放入客户端 `packages.properties.sig`，客户端 `packages.properties` 必须与签名原文逐字节一致。公钥 DER 保存在仓库，私钥由发布者离线保管。

`sign-update.ps1` 在 PowerShell 7 中签名；`publish-runtime.ps1` 使用 Git 已配置的 GitHub 登录，将资产上传为草稿并与 GitHub 返回的 SHA-256 核对，只有显式 `-Publish` 才发布。不要替换已经公开的版本资产；内容改变应新增版本。
