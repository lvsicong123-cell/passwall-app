# Architecture

This document describes the implemented protocol-v3 transport and public-alpha
application architecture, including image clipboard, explicit file transfer,
and native transfer-center interfaces.

## Components

```text
Mac controller
  SwiftUI configuration and status
  Core Graphics event tap and gesture interpreter
  crossing + scroll + shortcut core
  AppKit pasteboard monitor
  encrypted input/control session and bulk connector
                 |
                 | trusted local network
                 v
Windows receiver
  session validation and sequence checks
  display metrics and DPI reporting
  Win32 SendInput injection
  interactive WinForms clipboard bridge
  fail-safe input release
  external watchdog process
    exact held-button and held-key state
    emergency SendInput release after receiver death
```

`PasswallCore` contains deterministic behavior with no UI or platform APIs. The
Mac app owns capture, layout, and connection state. The Windows receiver owns
Windows display enumeration, injection, and privilege limitations.

## Coordinate model

- Pointer movement is transmitted as relative trackpad deltas.
- Crossing carries a normalized position along an edge from `0...1`.
- Each device reports physical pixel size, logical scale, and safe insets.
- The receiver maps entry into its usable physical-pixel area.
- Absolute Windows injection normalizes against the virtual desktop only at the
  final Win32 boundary.
- Entering remote control carries the Mac edge position as a normalized
  fraction. Windows maps it to the opposite edge of its virtual desktop.
- Returning applies the same model in reverse: Windows detects continued
  outward pressure at its return edge and sends the normalized exit position so
  macOS can restore its cursor at the corresponding point.
- While remote routing is active, macOS disconnects hardware deltas from its
  local cursor position. Relative deltas continue to flow to Windows, but the
  hidden Mac cursor remains fixed until every release path restores association.
- Core Graphics cursor visibility calls normally require a foreground caller.
  Passwall configures its WindowServer connection for background cursor control
  before balancing each hide/show lifecycle. This undocumented compatibility
  hook is isolated in `CursorCaptureController`; capture fails closed if it is
  unavailable rather than leaving a second visible cursor.

This avoids assuming that a 1512-point Mac display and a 3840-pixel Windows
display share a coordinate system.

## Scrolling model

Mac precise-scroll points remain floating point on the wire. Scroll phase and
momentum phase remain separate protocol fields in the capture milestone. The
Windows adapter retains fractional pointer and wheel units instead of rounding
every event. Persistent `0.5...2.0` pointer and scroll gains are applied at the
receiver injection boundary; browser navigation uses the unscaled gesture so
scroll tuning does not change its threshold. Hardware testing determines the
recommended values rather than claiming native equivalence from automated tests.

## Keyboard model

While Windows control is active, the Mac HID event tap consumes key-down,
key-up, and modifier-change events. Mac virtual key codes map to USB HID usages;
the receiver converts those usages to Windows scan codes at the final injection
boundary. Smart mapping translates common Command shortcuts to Control,
Command-Tab to Alt-Tab, Option-Arrows to Control-Arrows, and Command-Arrows to
Windows document-navigation keys. Option-Escape remains reserved for returning control
to macOS.

Modifier presses are balanced around the corresponding key and all receiver
disconnect paths still release held scan codes through the watchdog. Text input
method composition, standalone modifier actions, modifier-plus-mouse gestures,
and non-ANSI physical layouts remain outside the current hardware acceptance.

## Clipboard model

Clipboard control reuses the authenticated, ordered input stream. Image bytes
use the separate bulk connection. The Mac watches `NSPasteboard` and the Windows receiver
watches the interactive desktop clipboard every 500 ms. Both sides baseline
their current sequence when sharing starts, so reconnecting never sends stale
pre-session content.

The wire value always includes a plain-text fallback and may include RTF bytes
and an HTML fragment. Windows converts between the fragment and CF_HTML using
UTF-8 byte offsets at the platform boundary. The receiver owns a process-wide
monotonic revision, applies Mac clipboard content before later key input on the
same stream, and reports the newest state before its heartbeat response. Each
side records remote writes as its new baseline to prevent echo loops.

Clipboard sharing is disabled by default, limited to 512 KiB of unencoded text
content, and stopped on every disconnect. One PNG/JPEG image can use the bulk
connection with a 32 MiB limit. Explicit file and folder offers use the same
bulk transport only after receiver approval, with bounded manifests, streaming
SHA-256 verification, destination-local staging, and deterministic cleanup.

## Safety model

- The legacy development receiver remains loopback-only on port `24870` and is
  not exposed in the Mac UI.
- Bonjour advertises `_passwall._tcp.local.` with protocol version, receiver
  role, pairing-required state, TLS version, and certificate fingerprint.
- The LAN listener on port `24871` accepts pairing protocol lines first. Only a
  verified first pair or trusted resume must declare an `input` or `bulk` role;
  untrusted clients never dispatch input or content.
- Independent gates allow one input session and one approved bulk session.
  UUIDv4 transfer IDs, directions, declared sizes, expirations, and sequences
  reject unknown, oversized, stale, or replayed data in either direction.
- Confirmed device identities persist as trusted peer records in the macOS
  login Keychain and Windows Credential Manager.
- Every disconnect, timeout, parse failure, and process exit releases held input.
- Sequence numbers reject stale or replayed input inside a session.
- Mac sends a heartbeat every 500 ms and Windows echoes it. Either side closes
  and releases its local state after two seconds without valid peer activity.
- Before injecting a button or key down, the Windows receiver flushes that state
  to a separate interactive watchdog process over a named pipe. A normal up is
  reported only after injection succeeds. If the receiver is force-killed, pipe
  EOF makes the watchdog release exactly the still-held buttons and keys, then
  exit. The receiver refuses to listen if the watchdog cannot start.
- UAC secure desktop is out of scope; Passwall will not ask to run elevated by
  default merely to bypass Windows UIPI.

## Discovery and macOS signing

The Windows receiver publishes one native DNS-SD service with these TXT fields:

```text
pv=3
role=receiver
pairing=required
tls=1.3
fp=<SHA-256 certificate fingerprint>
```

The Mac browser rejects services with an unknown protocol version, a non-receiver
role, a mode that does not require pairing, a non-TLS-1.3 endpoint, or a malformed
fingerprint. Selecting a receiver performs a TLS 1.3 handshake and pins the exact
DER certificate SHA-256 fingerprint. Local pairing traffic bypasses system HTTP
proxies.

The Windows receiver owns a five-year ECDSA P-256 identity in the current user's
certificate store. Its private key is non-exportable, and the same certificate
is reused across receiver restarts.

The Bonjour fingerprint is provisional because Bonjour is not authenticated.
After TLS certificate pinning, Windows commits to a random nonce before the Mac
sends its nonce, then reveals it. Both sides derive a six-digit code from the
certificate fingerprint and both nonces. The user enters the independently
displayed Windows code on the Mac; the code itself never crosses the network.
Challenges expire after two minutes, Mac code entry is limited to three
attempts, cancellation is explicit, and each commitment can be confirmed only
once.

Successful confirmation creates a random controller ID and 32-byte shared
secret. The Mac stores them under the pinned certificate fingerprint in
Keychain, and Windows stores the same secret under the controller ID in
Credential Manager. After both processes restart, a fresh nonce transcript and
HMAC proof resume trust without displaying another code. The verified TLS
connection then binds either the framed input protocol or one registered binary
bulk transfer.

Selecting a discovered receiver establishes the authenticated input connection;
the Mac UI no longer exposes manual host and port fields.

The Windows receiver is a native WinForms notification-area process that
provides running state, restart, logs, and explicit exit. A per-user scheduled
task starts it in the interactive desktop at logon, preserving the `SendInput`
and clipboard session requirements. macOS uses `SMAppService.mainApp` for its
native login-item toggle; it is never enabled without the user's explicit
action.

The packaged Mac app declares `NSLocalNetworkUsageDescription` and
`NSBonjourServices`. The local development build retains the stable ad-hoc
identifier requirement used by existing Accessibility authorization. Production
builds must instead set `PASSWALL_SIGNING_IDENTITY` to an Apple-issued identity
so the application has a stable, attributable signing identity.

## Production transport

Passwall uses platform TLS 1.3 implementations: Network.framework on macOS and
`SslStream`/Schannel on Windows. It does not select cipher suites manually or
implement custom cryptography. Latency-sensitive TCP frames set `TCP_NODELAY` on
both platforms so small pointer messages are not held for packet coalescing.
