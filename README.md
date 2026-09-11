# Passwall

[简体中文](README.zh-CN.md)

## Download And Install

### [Download Windows Receiver · Setup EXE](https://github.com/lvsicong123-cell/passwall-app/releases/download/v0.1.1/Passwall-Setup.exe)
Windows 11 x64, runtime included. Open the installer; no extraction or commands.

### [Download Mac Client · Installer PKG](https://github.com/lvsicong123-cell/passwall-app/releases/download/v0.1.1/Passwall.pkg)
Apple Silicon, macOS 14+. Follow the system installer to install in Applications.

[Release notes and checksums](https://github.com/lvsicong123-cell/passwall-app/releases/tag/v0.1.1).
Install the matching client on each computer, then pair them below.

**Use your MacBook trackpad and keyboard on the Windows PC beside it.**

Keep your familiar Mac input workflow instead of swapping keyboards and mice.
Passwall connects two computers on a trusted LAN for input control, opt-in
clipboard sharing, and approved file/folder transfers in both directions.
It is not a remote desktop: Windows keeps its own display; no screen video is sent.

<img src="Assets/PasswallIcon.png" alt="Passwall app icon" width="96" height="96">

> [!WARNING]
> `v0.1.1` is a free, open-source Public Alpha, not a broadly validated stable release.
> The Mac package is locally ad-hoc signed, without Apple Developer ID signing or
> notarization. Windows executables have no Authenticode signature. Your system
> may block first launch. Use only trusted devices and networks; do not disable
> system security protections to install Passwall.

GitHub's `Source code (zip)` / `Source code (tar.gz)` downloads are source,
not app packages. The current Mac candidate is not Universal; there is no
verified Intel Mac download.
CI installation checks are not first-download security-prompt or physical
input/restart acceptance. These checks on the new installers remain **NOT RUN**.

## First Use

1. **Windows:** open `Passwall-Setup.exe` and follow the wizard. Desktop shortcut
   is selected by default; login startup is optional. Open Passwall Receiver
   after setup; it stays in the notification area. Finish transfers and quit
   from the tray before upgrading or uninstalling; setup never force-kills it.
2. **Mac:** open `Passwall.pkg` and follow the installer, which may ask for
   administrator approval. Open Passwall from Applications. Quit the old version
   before upgrading; if it lives elsewhere, use the new Applications copy afterward.
   Allow Passwall under System Settings > Privacy & Security > Accessibility.
   If asked for Local Network access, allow only if you trust the app and network.
3. **Pair:** connect both devices to the same trusted LAN, select the discovered
   Windows PC on the Mac, and compare and confirm the six-digit code on both devices.
4. **Control:** arrange the screen layout, start input sharing, and move the
   pointer across the configured edge. Move back across the adjoining edge or
   press `Option-Escape` to return to the Mac.
5. **Clipboard:** enable sharing separately when needed, then copy new content.
   It is off by default and supports text, rich text, and one PNG/JPEG image.
6. **Files:** choose or drop files/folders into the transfer page, then approve
   the destination and receipt on the other device. Copying a Finder file to the
   clipboard and pasting it in Windows is not supported.

### Security Prompts And Connection Problems

- **Unverified Mac developer:** verify the source and checksum first. For a
  trusted app, follow [Apple's instructions](https://support.apple.com/en-us/102445)
  for an individual exception. If there is no Open Anyway option, a malware
  warning appears, or your device is managed, stop and report it. Do not disable
  Gatekeeper or apply a system-wide exception.
- **Windows warning:** unsigned or low-reputation apps may trigger SmartScreen.
  Verify the source and checksum. If organization policy blocks installation,
  stop rather than disabling Defender or bypassing that policy.
- **No device found:** check that the receiver is running and the devices are
  not on isolated guest networks. If the firewall prompts, authorize only your
  trusted private network; do not disable the firewall.
- **Connected but no input:** check Mac Accessibility and input-sharing state.
  Handle Windows UAC prompts locally; secure-desktop control is unsupported.

### Verify Downloads

Optional advanced check, not an installation command: put the installer and its
checksum in the same directory. On the Mac:

```bash
shasum -a 256 -c Passwall.pkg.sha256
```

In Windows PowerShell:

```powershell
$archive = "Passwall-Setup.exe"
$expected = (Get-Content "$archive.sha256" -Raw).Trim().Split()[0]
$actual = (Get-FileHash $archive -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw "SHA-256 mismatch. Do not install." }
Write-Host "SHA-256 OK"
```

A matching hash only confirms agreement with the publisher's checksum; it does
not replace a trusted source, signing, or a security review.

### Startup And Uninstall

On the Mac, login startup is optional in Settings. Disable it and quit the app
before moving `Passwall.app` to the Trash.

Windows installs to `%LOCALAPPDATA%\Passwall\App` for the current user, without
admin rights. Re-run setup to change login startup. Uninstall from Settings >
Apps > Installed apps > Passwall Receiver, or its Start menu uninstall shortcut.
No manual PowerShell commands are needed. Internal helper checks use a
process-only execution policy, never change global settings, and cannot override
organization Group Policy. Policy failures stop installation.
Settings, trust records, received files and unknown files are preserved;
see [Privacy](PRIVACY.md).

## Features

- Edge crossing with relative pointer movement and scale-aware entry mapping
- Precise two-axis scrolling, configurable gestures, and Mac-to-Windows shortcuts
- Keyboard forwarding with `Option-Escape` reserved for returning to macOS
- TLS 1.3 pairing, certificate pinning, and trusted-device resume
- Fail-safe release of held keys and buttons after disconnects or receiver failure
- Opt-in plain-text, RTF, HTML, and single PNG/JPEG clipboard transfer
- Explicit file/folder offers with approval, progress, cancel, retry, and SHA-256 verification
- Native SwiftUI macOS app and WinForms Windows receiver

## Requirements

- Apple Silicon Mac with macOS 14 or newer for the downloadable controller
- Windows 11 x64 on the receiver PC
- .NET 8 SDK for Windows source builds
- Both devices on the same trusted local network

See the [compatibility matrix](docs/COMPATIBILITY_MATRIX.md) for the tested
fixture and known public-alpha limitations.

No internet relay, screen streaming, UAC secure-desktop control, resumable
transfers, directory sync, or clipboard-file semantics. No automatic updater;
update both endpoints together.

## Feedback

Use this repository's **Issues** bug template with app/OS version, reproduction
steps, and actual results. Remove device/user names, network addresses, pairing
codes, and personal file information from screenshots/logs. Report vulnerabilities
privately via [Security](SECURITY.md), not a public issue.

## Build And Test

Mac source builds require Swift 6 and the macOS SDK; packages use the build
machine's architecture. Windows download users need no separate .NET runtime.

On macOS:

```bash
swift test
swift build
./script/build_and_run.sh --package
bash script/package-macos-installer.sh
(cd dist && shasum -a 256 -c Passwall.zip.sha256)
```

`./script/build_and_run.sh --verify` additionally installs and launches the
development app in `~/Applications`.

On the logged-in Windows interactive desktop, in PowerShell:

```powershell
dotnet run --project Windows\PasswallReceiver.Checks\PasswallReceiver.Checks.csproj -c Release
dotnet build Windows\PasswallReceiver\PasswallReceiver.csproj -c Release
powershell -ExecutionPolicy Bypass -File .\Windows\package-release.ps1
```

Install NSIS 3 before running Windows packaging (CI pins 3.12).
The Windows package is self-contained by default. Use `-FrameworkDependent`
only to create a smaller development package that requires the .NET 8 Runtime.

## Security And Privacy

Passwall has no internet relay, cloud account, analytics, or automatic update
service. Input and content stay on the local network over an authenticated TLS
connection. Clipboard sharing is off by default, and every incoming file batch
requires approval. See [SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md)
before testing the alpha.

Passwall cannot control the Windows UAC secure desktop and does not request
elevation to bypass that boundary.

## Project Documentation

- [Release notes](docs/RELEASE_NOTES.md)
- [Product specification](docs/PRODUCT_SPEC.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Protocol](docs/PROTOCOL.md)
- [Compatibility matrix](docs/COMPATIBILITY_MATRIX.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

Licensed under [Apache License 2.0](LICENSE). The current alpha is fully free,
with no activation key or subscription.
