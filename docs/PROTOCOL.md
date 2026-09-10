# Wire Protocol v3

After pairing or trusted resume, the certificate-pinned TLS 1.3 connection
declares an `input` or `bulk` role. The single active input connection carries
latency-sensitive input, heartbeat, release, clipboard control, and transfer
control. At most one separately authenticated bulk connection carries binary
content. Input JSON frames remain limited to 1 MiB.

```json
{
  "version": 3,
  "sessionID": "uuid",
  "sequence": 42,
  "sentAtMicros": 1784512345678,
  "payload": {
    "type": "pointer_move",
    "data": { "dx": 4.5, "dy": -2.25, "gain": 1.25 }
  }
}
```

Mac input and entry control travel to Windows; Windows sends return-control
signals and heartbeat responses on the same stream.

## Payloads

| Type | Data |
| --- | --- |
| `pointer_move` | `dx`, `dy` relative points, optional `gain` |
| `pointer_warp` | `x`, `y` receiver physical pixels |
| `scroll` | `horizontal`, `vertical`, `phase`, optional `navigationEnabled`, optional `gain` |
| `button` | `button`, `isDown` |
| `key` | `usbHIDUsage`, `isDown` |
| `remote_enter` | `remotePosition`, `entryFraction`, `activationDistance` |
| `remote_exit` | `entryFraction` |
| `clipboard_control` | `enabled` |
| `clipboard_set` | `content` |
| `clipboard_state` | `revision`, `content` |
| `transfer_offer` | `transferID`, `kind`, `direction`, `totalBytes` |
| `transfer_accept` | `transferID` |
| `transfer_reject` | `transferID`, `code` |
| `transfer_progress` | `transferID`, `transferredBytes` |
| `transfer_cancel` | `transferID` |
| `transfer_complete` | `transferID` |
| `transfer_error` | `transferID`, `code` |
| `release_all` | none |
| `heartbeat` | none |

Transfer IDs are lowercase UUIDv4 values. `direction` is relative to the Mac:
`upload` means Mac to Windows and `download` means Windows to Mac. An offer on
the authenticated input session registers the ID before any bulk connection may
bind it. Unknown, direction-mismatched, duplicate, active, and previously used
IDs are rejected. Registration alone is not approval: the receiver must accept
the offer before the registry permits a bulk claim. Unclaimed offers and
approvals expire after two minutes. Used IDs are retained for ten minutes in a
process-local replay window capped at 10,000 entries.
`transfer_cancel` on the input session also cancels the matching active bulk
operation; an uploading bulk peer may instead end normally with a cancel frame.

## File transfer messages

A `kind: "files"` offer carries a `manifest` in its input-session payload. The
manifest contains one to 10,000 entries, each with a slash-separated relative
`path`, `kind` (`file` or `directory`), and `byteCount`; file entries additionally
carry a lowercase SHA-256 `sha256`. Directory entries have zero bytes and no
digest. Paths may not be absolute, empty, contain `.` or `..` components,
backslashes, NULs, or duplicates. The sum of all file sizes must exactly equal
`totalBytes` and may not exceed 100 GiB.

The bulk body is the concatenation of file bytes in manifest order; directory
entries have no body. The receiver writes only to a transfer-owned staging
directory, validates every declared digest, and commits only after every entry
has completed. Rejection, cancellation, disconnect, malformed framing, or a
digest mismatch removes that staging directory. User-visible destination choice,
portable-name mapping, conflict naming, and history are owned by the transfer
centers and are not inferred from the wire path.

File offers require explicit receiver acceptance and are independent of
`clipboard_control`; disabling clipboard sharing cancels image work, while input
session teardown cancels both image and file transfers.

## Clipboard messages

Clipboard sharing is opt-in and available only on the authenticated TLS
session. The Mac controller sends:

```json
{
  "type": "clipboard_control",
  "data": { "enabled": true }
}
```

After enabling, the Mac can send new local content:

```json
{
  "type": "clipboard_set",
  "data": {
    "content": {
      "plainText": "Passwall link",
      "rtfBase64": "e1xccnRmMVxiLi4u",
      "html": "<a href=\"https://example.com\">Passwall link</a>",
      "image": {
        "transferID": "12345678-1234-4abc-8abc-123456789abc",
        "mediaType": "image/png",
        "byteCount": 24576,
        "sha256": "4c21065a5135366eef72e22c4b8ea8d55e98d379f2e64a224099a3cb3ad95d40"
      }
    }
  }
}
```

The Windows receiver is the revision authority and returns accepted local or
remote content as:

```json
{
  "type": "clipboard_state",
  "data": {
    "revision": 7,
    "content": { "plainText": "Passwall link" }
  }
}
```

`plainText` is required and non-empty for text-only content. It may be empty when
`image` is present. `rtfBase64`, `html`, and `image` are optional;
RTF is Base64-encoded bytes and HTML is a raw fragment rather than a Windows
CF_HTML envelope. The combined UTF-8 plain-text bytes, decoded RTF bytes, and
UTF-8 HTML bytes must not exceed 524,288 bytes.

An image is one PNG or JPEG body of at most 32 MiB. Its bytes never enter the
JSON frame: metadata carries a UUIDv4 transfer ID, media type, exact byte count,
and SHA-256 digest, while the authenticated bulk session carries the body. For a
Mac-originated image, `transfer_offer` precedes `clipboard_set`; Windows returns
`transfer_accept` only after both declarations match. For a Windows-originated
image, `transfer_offer` precedes `clipboard_state`; Mac returns
`transfer_accept`. The receiver validates the declared size, digest, and image
representation before replacing its system clipboard. A failed, canceled,
disabled, or disconnected transfer leaves the existing clipboard unchanged.

The receiver increments its revision after each accepted Windows clipboard
change or Mac `clipboard_set`. A newer `clipboard_state` is written before the
next heartbeat response. Revisions remain monotonic for the receiver process;
the Mac ignores stale revisions and updates its pasteboard baseline after a
remote write to prevent echo loops.

For image uploads, the revision increments only after the complete bulk body is
validated and written. The resulting `clipboard_state` acknowledges the
Mac-originated transfer without rewriting the Mac pasteboard. For image
downloads, the Mac writes the pasteboard only after the complete body matches
the `clipboard_state` metadata. A newer local clipboard change cancels an older
outbound image. When several Windows image offers overlap, the Mac finishes the
active body and retains only the newest pending offer and state.

Enabling and reconnecting record the current clipboard sequence on each side
without transmitting existing content. Disabling stops monitoring and clears
pending state. `clipboard_set` before enable, clipboard messages on the
unauthenticated loopback listener, and messages sent in the wrong direction are
protocol errors. Session teardown disables clipboard monitoring before held
input is released.

## Required receiver behavior

- Reject unsupported versions and malformed or oversized frames.
- Apply messages only to the active authenticated session.
- Create a new `sessionID` for each TCP connection and maintain independent
  strictly increasing sequences in each direction.
- Reject the connection on a duplicate, stale, or wrong-session message before
  dispatching its payload.
- Coalesce pointer movement only without crossing button/key ordering boundaries.
- Release all held state when the stream ends for any reason.
- Echo every heartbeat. Mac sends one every 500 ms; both sides treat two seconds
  without valid peer activity as a failed connection and restore local state.
- On `remote_enter`, map `entryFraction` to the edge opposite
  `remotePosition`, then arm outward-pressure detection at that edge.
- On a detected return crossing, release held input and send `remote_exit` with
  the normalized exit position before accepting another remote handoff.
- Clamp pointer and scroll `gain` to `0.5...2.0`; missing or invalid values use
  `1.0`. Apply scroll gain after browser-navigation gesture recognition.

The receiver enforces connection-local session and sequence validation after
cryptographic peer authentication. A loopback-only development listener remains
available to receiver checks but is not exposed in the Mac UI.

## Pairing protocol v1

The TLS 1.3 pairing listener uses bounded ASCII lines. Windows first sends a
SHA-256 commitment to a fresh 16-byte nonce. The Mac then sends its own fresh
16-byte nonce, and Windows reveals the committed nonce. Both sides derive the
six-digit code from:

```text
SHA-256("passwall-pairing-v1" || certificate-fingerprint ||
        windows-nonce || mac-nonce)
```

The Mac validates the code locally, creates a random controller ID and 32-byte
shared secret, and saves them in Keychain before sending `CONFIRM`. The
confirmation includes an HMAC-SHA-256 proof keyed by the six-digit code and
bound to the certificate fingerprint, both nonces, controller ID, and secret.
Windows verifies the proof, stores the secret in Credential Manager, and
returns `PAIRED`.

On later connections the Mac sends `RESUME <controller-id>` with a fresh
HMAC-SHA-256 proof keyed by the stored secret. Windows loads the matching
credential and verifies the new nonce transcript, so no code is displayed.
Pairing expires after two minutes, cancellation is explicit, three incorrect
Mac entries end the attempt, and confirmed transcripts reject replay. After
`PAIRED`, the Mac must send exactly one declaration:

```text
SESSION input
SESSION bulk <transfer-id> <upload|download>
```

Windows replies `SESSION_OK` only after the declaration is syntactically valid.
Bulk declarations require trusted resume and a UUIDv4 transfer ID; first-time
pairing can establish only an input session. No input or bulk frame reaches its
session handler before authentication and role binding succeed. The listener
handles at most four concurrent authentication handshakes, while the runtime
enforces one active input and one active bulk session.

## Bulk framing

Bulk frames are binary and never Base64-encoded. Each frame has this network-byte
order header followed by its payload:

| Bytes | Field |
| --- | --- |
| 1 | kind: `1` chunk, `2` cancel, `3` complete |
| 16 | UUIDv4 transfer ID in canonical byte order |
| 8 | strictly increasing unsigned sequence |
| 4 | unsigned payload length |

Chunk payloads are limited to 262,144 bytes. Cancel and complete frames must have
zero payload. Receivers validate the length before allocation, keep at most one
encoded frame buffered, reject wrong IDs and non-increasing sequences, and stop
accepting frames after cancel or complete. EOF before a terminal frame is an
error. A complete transfer must contain exactly the `totalBytes` accepted on the
input session; cancellation may terminate a partial body. `upload` sessions send
chunks from Mac to Windows, while `download` sessions send them from Windows to
Mac. Either side abandons a bulk connection after 30 seconds without content
progress. Bulk handling runs independently, so input heartbeat and release paths
do not wait for content bytes.
