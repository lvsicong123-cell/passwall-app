# Contributing To Passwall

Thank you for helping improve Passwall. Keep changes focused, testable, and
compatible with its local-network security model.

## Before Opening A Change

- Search existing issues before filing a new one.
- Use the bug or feature template and remove private paths, device names,
  addresses, pairing data, clipboard contents, and transferred filenames.
- Report security vulnerabilities through the private process in
  [SECURITY.md](SECURITY.md), never through a public issue.
- Discuss protocol, trust, permission, persistence, or cross-platform changes
  before implementing them.

## Development

Requirements and build commands are in [README.md](README.md). Keep portable,
deterministic behavior in `Sources/PasswallCore`, macOS integration in
`Sources/PasswallMac`, and Windows integration in `Windows`.

Run the checks affected by your change. Before a pull request, run:

```bash
swift test
swift build
```

On Windows PowerShell, also run:

```powershell
dotnet run --project Windows\PasswallReceiver.Checks\PasswallReceiver.Checks.csproj -c Release
dotnet build Windows\PasswallReceiver\PasswallReceiver.csproj -c Release
```

Hardware behavior must be described as `NOT RUN` unless it was observed on the
stated device. A successful build or connected status does not prove pointer,
keyboard, clipboard, file-transfer, startup, or failure-recovery behavior.

## Pull Requests

- Keep one independently verifiable result per pull request.
- Add the smallest regression check for behavior changes and bug fixes.
- Update both endpoints and `docs/PROTOCOL.md` for protocol changes.
- Do not weaken TLS, certificate pinning, explicit file approval, size limits,
  input release, or `Option-Escape` recovery.
- Do not commit generated archives, credentials, private keys, device-specific
  traces, or local development configuration.

Contributions are licensed under Apache-2.0 as described in [LICENSE](LICENSE).
