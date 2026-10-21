# 烤鱼运行环境

独立存放 [烤鱼 Android 客户端](https://github.com/MakiseYu/kaoyu) 使用的 Debian ARM64 开发环境和官方 Codex 引擎包。

二进制安装包保存在本仓库的 [Releases](https://github.com/MakiseYu/kaoyu-runtime/releases)，不提交到 Git 历史。两个包分别版本化：补充 Debian 工具链不要求重新制作 Codex 引擎。

客户端 0.3.0 起可在“设置 → 环境 → 检测环境更新”中读取正式发布版本，验证 APK 内置公钥签名，再下载并验证包大小、SHA-256 与归档结构。`runtime.properties` 是签名清单，`runtime.properties.sig` 是对其原始字节的 SHA256withRSA 签名。发布私钥不存放于本仓库。

环境包含 C/C++、Rust、Python、Node.js、Git、常用构建工具与文件处理工具。详细版本以各次 Release 的工具链清单及 Debian 包清单为准。离线运行已安装编译器不代表离线拥有所有第三方依赖。

源码和构建入口在 `tools/`。构建需要 Linux root、ARM64 主机或 QEMU/binfmt、足够临时磁盘空间。第三方组件使用各自许可证；基础输入、组件摘要与构建说明随发布记录提供。

升级保留 `/workspace`、`/home/codex` 和客户端会话记录；用户自行修改的系统目录不属于持久化数据，应将自定义项目依赖放在项目目录或用户目录。
