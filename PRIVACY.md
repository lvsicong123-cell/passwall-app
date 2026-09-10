# Privacy And Local-Network Disclosure

Passwall is designed to operate directly between a Mac and a Windows PC on the
same local network. It has no cloud account, internet relay, analytics, crash
reporting, advertising, or automatic-update service.

## Data Sent Between Devices

- Pointer, keyboard, scroll, gesture, heartbeat, and display-layout events while
  input sharing is active
- Clipboard text, rich text, HTML, or one PNG/JPEG image only when clipboard
  sharing is enabled and newly copied content is detected
- File and folder metadata when a user explicitly creates a transfer offer
- File bytes only after the receiving user accepts that batch

Traffic uses an authenticated TLS 1.3 connection. Bonjour advertises the local
receiver so the Mac can discover it. This makes the receiver's service presence
and local device name visible to other devices on the same network.

## Local Storage

The Mac stores trusted-peer data in Keychain. Windows stores trusted-peer data
in Credential Manager and its device certificate in the current user's
certificate store. Each app stores local preferences and at most 100
metadata-only transfer-history records. Received files are saved only to the
destination selected by the receiving user.

Passwall logs operational state and error categories, not clipboard contents,
file contents, pairing codes, secrets, or complete private paths. Operating
system and development tools may keep their own logs outside Passwall's control.

## User Controls

Clipboard sharing is off by default and can be disabled at any time. Every
incoming file batch requires approval. Users can remove local application data
and trusted-peer records using their operating system tools; trust reset is not
performed automatically because it is destructive.

Use Passwall only on networks and devices you trust. Do not send sensitive
content while untrusted people can access either endpoint.
