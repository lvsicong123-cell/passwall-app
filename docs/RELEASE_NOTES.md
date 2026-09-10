# Passwall v0.1.0 Public Alpha

## 中文

用 MacBook 的触控板和键盘控制旁边的 Windows，减少双机之间换键鼠的打断。
这是首个公开 Alpha 的发布说明；是否已发布，请以本仓库 Releases 为准。

### 这版包含什么

- 跨屏输入控制、双轴滚动、手势和 Mac 到 Windows 快捷键映射。
- 默认关闭、按需开启的双向文字、富文本和单张图片剪贴板。
- 需要接收确认的双向文件/文件夹传输，包含进度、取消、重试及哈希校验。
- 局域网 TLS 1.3 配对、可信设备重连及断线按键释放保护。
- 原生 Mac/Windows 界面、托盘/菜单栏和可选登录启动。

候选版本还修复了 Command-L 等字母快捷键的映射、Windows 输入暂时受阻后的
按键释放与边缘返回恢复，以及 Windows 卸载无法移除登录任务时的错误处理。

### 下载与安装

Mac 下载 `Passwall.zip`（Apple Silicon，macOS 14+）；Windows 下载
`Passwall-Windows-win-x64.zip`（Windows 11 x64，内含 .NET 运行时）。
两者各有同名 `.sha256` 校验文件。请使用同一版本的两端，按
[中文安装说明](../README.zh-CN.md)配对。源码 ZIP 不是安装包。

### 试用前须知

- Mac 没有 Developer ID 签名/公证，Windows 没有 Authenticode 签名；系统可能
  拦截首次打开。当前 Mac 包仅为 arm64，没有已验证的 Intel 包。
- 只在可信局域网和自己有权操作的设备上使用；不支持互联网中继或屏幕视频。
- `Option-Escape` 返回 Mac。Windows UAC 安全桌面必须在 Windows 本机处理。
- 图片每张最多 32 MiB；文件批次最多 10,000 项、100 GiB。取消/中断后从头重试，
  不支持断点续传、目录同步或剪贴板文件语义。
- 最低系统版本、混合多显示器等环境未完整验证；详见
  [兼容性矩阵](COMPATIBILITY_MATRIX.md)。没有自动更新，请手动同时更新两端。
- 已有开发者真机验收不等于陌生用户设备的首次下载/安装验证。欢迎报告安装阻碍，
  不要为试用而关闭系统安全保护。

### 反馈

请通过本仓库 Issues 的 Bug 模板提供系统版本、操作步骤和实际结果。截图和日志
请先去除个人信息；安全问题按 [SECURITY.md](../SECURITY.md)私下报告。
本 Alpha 完整免费，采用 Apache-2.0，无激活码、订阅或云账户。

## English

Use your MacBook trackpad and keyboard on a nearby Windows PC. This document
describes the first Public Alpha; check this repository's Releases for actual
publication status.

### Included

- Edge-based input control, two-axis scrolling, gestures, and shortcut mapping.
- Opt-in bidirectional text, rich-text, and single-image clipboard sharing.
- Approved file/folder transfers with progress, cancel, retry, and SHA-256 checks.
- Local TLS 1.3 pairing, trusted resume, and fail-safe held-input release.
- Native interfaces, tray/menu-bar controls, and optional login startup.

Candidate fixes cover Command-letter mapping (including Command-L), held-input
and edge-return recovery after temporary Windows input blocking, and uninstall
failure handling when the Windows login task cannot be removed.

### Downloads And Limits

Use `Passwall.zip` for Apple Silicon macOS 14+ and
`Passwall-Windows-win-x64.zip` for Windows 11 x64 (runtime included), with their
matching `.sha256` files. Install both endpoints at the same version using the
[setup guide](../README.md). GitHub's source archives are not app packages.

Mac has no Developer ID signing/notarization; Windows has no Authenticode
signature. First launch may be blocked. The current Mac candidate is arm64 only.
Do not disable security protections or bypass managed-device policies.

Use trusted LANs and authorized devices. `Option-Escape` returns to Mac; handle
Windows UAC locally. No screen video, internet relay, resumable transfers,
directory sync, clipboard files, or automatic updates. Images are limited to
32 MiB; file batches to 10,000 entries / 100 GiB. Update both apps together.

Minimum OS and mixed-display coverage remain unverified. See the
[compatibility matrix](COMPATIBILITY_MATRIX.md); accepted developer-device
tests do not establish first-download installation on other users' machines.

Report bugs through Issues after removing private information. Report security
issues privately via [Security](../SECURITY.md). Fully free under Apache-2.0;
no activation key, subscription, or cloud account.
