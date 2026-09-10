# Security Policy

## Supported Versions

Passwall is currently a public alpha. Security fixes target the latest source
and the latest `0.1.x` release only.

## Reporting A Vulnerability

Use the repository's private **Report a vulnerability** form under the Security
tab. If private vulnerability reporting is unavailable, contact the repository
owner privately through their GitHub profile and request a secure channel.

Do not open a public issue containing exploit details, credentials, pairing
data, private network addresses, clipboard contents, filenames, or logs with
personal information.

Include the affected version, platform, impact, reproduction steps, and any
suggested mitigation. Maintainers will acknowledge a complete report within
seven days and coordinate disclosure after a fix or mitigation is available.

## Security Boundaries

- Passwall is for trusted devices on a trusted local network; it has no relay.
- TLS 1.3, certificate pinning, and explicit first-pair confirmation are required.
- Incoming file batches require explicit approval.
- Clipboard sharing is disabled by default.
- Windows UAC secure-desktop control is not supported.
- Public-alpha binaries are unsigned and do not auto-update.

Deleting or replacing trust records, changing startup tasks, or weakening any
of these boundaries is not an acceptable workaround for a security issue.
