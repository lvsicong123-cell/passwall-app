# Public Snapshot Audit

## Export Boundary

`script/export-public-repository.sh` creates a separate Git repository from an
explicit public allowlist. It excludes private development history and state:

- `AGENTS.md`, `TASKS.md`, `DEV_LOG.md`, and `design-qa.md`
- `.codex-workflow` specifications, plans, and run traces
- private acceptance plans under `docs/superpowers`
- the device-specific legacy SSH tunnel helper and all ignored credentials
- build output, release archives, editor state, and operating-system metadata

The generated repository is initialized on `main` and staged but intentionally
has no commit, remote, tag, or release. Publication remains a separate,
confirmation-gated action.

## Checks

The exporter scans staged text for common private-key and access-token formats.
Set `PASSWALL_PRIVATE_PATTERN` to an extended regular expression containing
local device names, usernames, addresses, or path fragments before exporting:

```bash
PASSWALL_PRIVATE_PATTERN='term-one|term-two' \
  ./script/export-public-repository.sh
```

Before publication, inspect the staged file list and diff from inside the export:

```bash
git status --short
git diff --cached --stat
git grep -n -I -E 'private-term-pattern'
```

Binary assets require manual provenance and visual inspection; text scanning
cannot prove that an image contains no private information.

## 2026-09-04 Result

This is historical source-export evidence, not authorization to publish later
local binaries or a replacement for a final release artifact audit.

- PASS: the generated repository contains 142 staged files, zero commits, and
  no remotes.
- PASS: internal state files and private run records are absent.
- PASS: common secret formats and the operator-supplied private identity/path
  pattern are absent; positive-match and invalid-pattern checks fail closed
  without printing matched content.
- PASS: tracked image/icon assets contain no matching private text; the primary
  icon was visually inspected and contains no private information.
- PASS: the exported macOS source passed 90 tests, packaging, signature checks,
  embedded version `0.1.0`, and archive SHA-256 verification.
- PASS: hosted GitHub Actions run `33834053548` completed both jobs, including
  Windows receiver checks/build/package/checksum and macOS tests/package/checksum.
- NOT RUN: the physical Windows fixture remained unreachable; T-660 requires
  hosted build evidence rather than a new physical product-acceptance pass.

## 2026-09-10 Release Preparation

- The fresh 143-file source snapshot includes the accepted candidate fixes,
  download-first bilingual documentation, and release notes. It is staged with
  no commit, remote, tag, or release; internal records and private Git history
  are excluded. The operator-supplied private-text and secret scans pass.
- Original phone footage is excluded. A separate local review copy removes
  location/device metadata, audio and data tracks. No demo is uploaded or
  included in this source snapshot; visual disclosure still needs approval.
- Independent local testing passes 91 Mac tests across 22 suites. Windows is
  offline, so no new Windows execution or physical test is claimed here.
- Local candidate archive checksums pass, but a binary-content audit found
  publisher-specific development paths. Those local archives are NOT approved
  for public upload. Hash integrity does not prove artifact privacy.
- Before publishing download assets, rebuild from the approved clean source in
  a non-personal build workspace, run both platform CI jobs, and inspect the
  resulting binaries for private paths and metadata. Record the actual commit,
  CI run, package architecture, and new archive checksums at release time.
- First-download installation on a non-development machine remains NOT RUN;
  do not describe developer-fixture acceptance as that independent user pass.
