# Passwall Product Spec

## Product promise

A MacBook user can move the pointer through the physical edge of the Mac display
and continue controlling a nearby Windows PC with the built-in trackpad and
keyboard. Motion, scrolling, and shortcuts should feel intentional rather than
like a generic mouse forwarded over a network.

## Target setup

- macOS 14 or newer on a MacBook with a Force Touch trackpad
- Windows 11 on the nearby PC
- Both devices on the same trusted local network
- One Windows display initially; multi-display Windows setups follow

## Experience requirements

1. Pairing is device-to-device: discover, confirm a six-digit code, connect.
2. Screen layout matches the physical desk and supports every edge.
3. Crossing requires outward intent, keeps corners sticky, and never traps input.
4. Pointer motion uses relative deltas while entry points use normalized geometry.
5. Precise scrolling preserves fractional deltas, phases, direction, and momentum.
6. Gesture mappings are explicit, reversible, and configurable per gesture.
7. Common macOS shortcuts translate semantically on Windows.
8. Disconnects release every held key and pointer button immediately.
9. Both apps run quietly after setup and expose clear connection state.
10. Clipboard sharing is explicit, bounded, and preserves a plain-text fallback.
11. A public-alpha user can copy one common image between devices without making
    bulk content block input recovery.
12. Either trusted endpoint can explicitly offer files or folders; the receiver
    confirms every batch before content transfer begins.

## Foundation milestone

### Goal

Create a real Mac-to-Windows transport bench with tested shared behavior and a
truthful UI, ready for hardware iteration.

### Non-goals

- No claim of native-feeling trackpad capture before hardware measurements
- No file or attachment transfer
- No internet relay
- No LAN input listener without authenticated encryption
- No UAC secure-desktop control

### Done criteria

- Core tests cover crossing, display scaling, scrolling, shortcuts, and framing.
- The Mac app builds and runs as an app bundle.
- The Windows receiver builds on Windows with .NET 8 and injects bench input.
- Development traffic runs through an SSH tunnel.
- Hardware observations are recorded before global input capture is enabled.

## MVP exit criteria

- Automatic discovery and authenticated encrypted pairing
- Stable pointer crossing in both directions for 30 minutes
- No stuck inputs across cable/Wi-Fi loss, sleep, quit, or receiver crash
- P50 pointer event delivery below 4 ms and P99 below 12 ms on the test LAN
- Smooth vertical and horizontal scrolling in Explorer, Edge, Chrome, and VS Code
- Click, drag, right click, keyboard, and the agreed shortcut map verified
- 100%, 125%, 150%, 175%, and 200% Windows scaling fixtures verified
- Accessibility and Input Monitoring permission flows verified on macOS

## Later releases

- Gesture translation: desktop switching, Task View, browser navigation, zoom
- Multiple remote devices and multi-display Windows geometry
- Per-app shortcut and gesture profiles
- Signed installers, auto-update, and crash-safe launch-at-login

## Public alpha milestone

### Goal

Prepare Passwall for an Apache-2.0 GitHub public alpha with single-image
clipboard sharing, explicit bidirectional file transfer, native transfer-center
UI on both platforms, repeatable checks, and honest compatibility evidence.

### Non-goals

- No file clipboard, directory sync, automatic receipt, or resumable transfer
- No multi-image clipboard or embedded rich-document attachment transfer
- No internet relay, UAC secure-desktop control, signing, notarization,
  Authenticode, automatic update, or rollback
- No public release of the private development Git history

### Done criteria

- Protocol v3 separates latency-sensitive input/control from authenticated bulk
  bytes and rejects role, replay, direction, size, and transfer-ID violations.
- Single PNG/JPEG clipboard and explicit files/folders pass bidirectional real-app
  acceptance without regressing text, rich clipboard, input, or safety release.
- Mac and Windows transfer centers cover confirmation, progress, cancel, retry,
  destination, history, localization, and failure states.
- Independent test-agent verification, physical-device gates, public CI,
  Apache-2.0 project files, clean-history export, and reproducible unsigned
  archives are complete.

The authoritative approved scope and staged implementation plan live under
`.codex-workflow/features/T-600-public-alpha/`.

## Clipboard alpha milestone

### Goal

Share newly copied text between the trusted Mac and Windows session without
changing pointer, keyboard, or recovery behavior.

### Non-goals

- No images, files, attachments, or clipboard history
- No clipboard transfer before opt-in or across unauthenticated connections
- No items above 512 KiB of unencoded plain text, RTF, and HTML
- No claim of application-specific rich-format fidelity without physical checks

### Done criteria

- Protocol v2 validates direction, ordering, revision, Base64, and size limits.
- Both platform adapters baseline existing content and suppress remote echoes.
- Plain text, RTF/HTML, fallback, toggle, reconnect, and input regressions pass
  on the accepted physical Mac and Windows fixture.
