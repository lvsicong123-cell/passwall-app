# Changelog

Notable changes to Passwall are documented here. The project follows Semantic
Versioning; while the major version is zero, public APIs and protocols may
change between minor releases.

## [Unreleased]

## [0.1.0] - Unreleased

### Added

- Native macOS controller and Windows 11 receiver
- TLS 1.3 discovery, pairing, certificate pinning, and trusted resume
- Pointer, keyboard, scrolling, gesture, shortcut, and fail-safe release flows
- Opt-in text, rich-text, HTML, and single-image clipboard sharing
- Explicit bidirectional file/folder transfer with approval and SHA-256 checks
- Native transfer-center interfaces, bounded history, cancel, and retry

### Fixed

- Map Command-letter shortcuts, including Command-L, to Windows Control shortcuts
- Preserve held-input release retries and edge return after temporary Windows input blocking
- Stop Windows uninstall before removing program files when login-task removal fails

### Security

- Separate authenticated input and bulk sessions
- Bounded clipboard, image, manifest, chunk, and batch sizes
- Watchdog release after receiver failure and deterministic partial cleanup
