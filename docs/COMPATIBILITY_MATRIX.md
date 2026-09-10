# Compatibility Matrix

## Earlier accepted physical fixture

| Component | Verified fixture |
| --- | --- |
| Mac | MacBook Pro `Mac17,9`, Apple M5 Pro, 48 GB |
| macOS | 26.6.2 (`25G83`) |
| Windows PC | MSI `MS-7E13`, Windows 11 build `26200` |
| Windows display | 2560x1440 at 240 Hz |
| Windows GPU | NVIDIA GeForce RTX 4060 Ti |

| Workflow | Evidence |
| --- | --- |
| Secure discovery, pairing, and trusted resume | Physical pass, including Mac app and Windows receiver process restarts |
| Pointer crossing, movement, click, drag, scroll, Escape passthrough, and Option-Escape return | Physical pass |
| Receiver loss, Wi-Fi loss, sleep/wake, and watchdog release | Physical pass |
| Two-finger navigation, pinch, three-finger drag, and four-finger actions | Physical pass |
| Excel horizontal scrolling and browser Back/Forward separation | Physical pass |
| Ordinary typing and agreed Command/Option shortcut map | Physical pass |
| Windows interactive login task | Physical reboot/login pass reported by the user |
| macOS login item | Physical reboot/login pass reported by the user |
| Unsigned archive uninstall and reinstall | Physical pass on both accepted fixtures |
| Protocol-v2 bidirectional plain/rich clipboard, baselining, toggle, restart, and image/file exclusion | Physical pass in TextEdit, Edge, and Notepad |
| Windows scaling at 100%, 125%, 150%, 175%, and 200% | User-observed physical pass for pointer, click, two-axis scroll, and Option-Escape; restored to 100% |

## Public-alpha protocol-v3 evidence

| Workflow | Evidence |
| --- | --- |
| Single PNG/JPEG clipboard in both directions with text/rich fallback | Automated size, signature, revision, and echo checks plus the T-610 physical Paint/Preview and text/rich pass |
| Explicit file/folder transfer in both directions | Automated manifest, approval, streaming, hash, staging, cleanup, queue, and history checks plus the T-640 physical 13-file Mac-to-Windows batch and 60-byte Windows-to-Mac hash match |
| Empty, Unicode, nested, conflicting, canceled, rejected, disconnected, and corrupt transfers | Automated Mac and Windows checks pass; physical receiver-kill at 16.6% of a 16-GiB upload failed the sender cleanly, restart removed the partial, and trusted TLS resumed |
| 10,000-entry, 100-GiB, disk-space, and bounded-discovery limits | Exact-boundary and overflow checks pass on both endpoints; discovery is globally capped before deterministic sorting |
| Large-transfer integrity and memory | A 4-GiB Mac-to-Windows transfer matched SHA-256 `8479e439...fcddca`; Mac physical footprint peaked at 153.1 MiB and Receiver working set at 89,468,928 bytes. A separate 1-MiB transfer also matched SHA-256 end to end |
| Input isolation during bulk transfer | The 64-MiB automated check kept heartbeat and release-all responsive. During the 4-GiB physical transfer, pointer, click, two-axis scroll, ordinary Escape, and Option-Escape passed. During a 16-GiB transfer, physical Wi-Fi loss released input, returned control to Mac, failed/canceled the transfer, removed the partial, and reconnected with saved trust |
| Live send-completion latency | Thirty UI-triggered samples on the accepted LAN were P50 6.50 ms and P99 8.98 ms; this is a send-completion proxy, not direct pointer-delivery instrumentation |
| Thirty-minute stability | From 21:40:38 to 22:11:14, 360 five-second samples found zero Mac-process, TLS-session, Receiver/Watchdog, or Receiver-restart misses. Mac RSS peaked at 203,760 KB; Receiver working set peaked at 56,979,456 bytes during the observation |
| Log privacy | Source and deployed-log audits exclude clipboard/file contents, exception details, complete private paths, and pairing codes; pairing codes require an explicit UI callback instead of a console-log fallback |

The T-610 and T-640 physical rows are earlier accepted endpoint evidence. The
T-650 rows use the 2026-09-03 deployed Windows receiver and installed Mac app.

## T-670 candidate recheck (2026-09-06--10)

Earlier accepted rows above are not final acceptance of the later shortcut and
blocked-input recovery changes. The fixed candidate was deployed with user
authorization on September 8. Required available-fixture acceptance completed
September 10 using independent verification and explicitly attributed user
observations. Accepted unavailable-fixture limitations remain NOT RUN below.

| Workflow | Evidence |
| --- | --- |
| Mac automated checks | September 7 12:46 +08:00 independent full run: 91/91 tests across 22 suites PASS, exit 0, including Keychain and clipboard suites; supersedes the earlier authorization failure |
| Windows automated checks | Three Release builds and 86 pre-session checks PASS. September 8 user-run full current interactive suite: 206 checks PASS, reported exit 0; retained log independently reviewed and final Checks DLL hash verified. Supersedes the older 200-check evidence |
| Input and edge return after UAC | Automated regression PASS. September 8 user-observed ordinary input and edge return PASS after the requested UAC prompt/cancel check; no secure-desktop control claim |
| Candidate archives | Fresh 0.1.0 Mac ad-hoc and Windows unsigned packages, contents, and SHA-256 checks PASS; Mac bundle matches the installed bundle. September 8 independent Windows repeat packaging PASS: 6/6 payload files byte-identical, both ZIP checksums and six members valid. ZIP bytes differ; no byte-identical archive claim. Local original candidate unchanged |
| Source and deployed version | All 52 Windows source/version files match staging. September 8 authorized deployment PASS, installer exit 0; independent verification confirms 6/6 installed hashes match the fixed payload and both processes run from the installed directory |
| Trusted connection and capture permission | After September 8 deployment, Mac UI reports TLS 1.3 and Accessibility granted; new Receiver has an established LAN connection. These are connection/permission observations only |
| Windows startup and installation | PASS. September 10 independent check: boot 20:06:17 +08:00, login task/Receiver start 20:06:26, Watchdog start 20:06:37, both in session 1 with fixed hashes; Mac TLS 1.3 connected. User confirms automatic connection and normal ordinary input/Option-Escape after this login. Agent did not initiate reboot |
| Ordinary input, drag/scroll, edge return, and Option-Escape | September 8 PASS, explicitly reported by the user on the deployed fixed candidate. Ordinary edge return does not establish recovery after UAC |
| Command-A, browser Command-L, and Escape | September 8 user-observed PASS: select all, select address bar without locking Windows, and close menu/cancel. User also reports the requested text copy/paste workflow correct |
| Bidirectional text/image clipboard | September 8 user-reported functional PASS in response to the requested bidirectional workflow. User performed image tests independently; exact image fixtures and per-direction observations were not supplied. No agent endpoint/image comparison claim |
| Bidirectional files | PASS: September 8 user report corroborated September 10 by matching endpoint histories for new transfer IDs 6af27c7d-e3fd-44ee-af65-16f407f68ba3 (52 bytes) and 358238cc-b7b6-4c56-a0a9-33fc00cc10e1 (53 bytes). Independent source/received SHA-256 comparisons match in both directions; no repeated transfer or clipboard change |

T-670 is accepted for this available Mac/Windows fixture. UAC secure-desktop
control remains unsupported; ordinary input and edge-return recovery after
cancelling that context passed by user observation. Acceptance is not
publication authorization or evidence for the unavailable fixtures below.

## Accepted known limitations

The following fixtures remain NOT RUN. On 2026-09-03 the user explicitly
accepted them as public-alpha limitations; they are not PASS results.

- Multiple Windows displays with mixed scale and refresh rates.
- Minimum supported macOS 14 and additional supported Windows 11 builds.
- Expired trust and revoked trust flows.
- True disk-full hardware behavior; automated capacity-boundary checks pass.
- Direct P50/P99 pointer-delivery instrumentation; the current UI exposes only
  local send-completion timing.

Signing, notarization, Authenticode, automatic update, and rollback are not
planned for the unsigned alpha.

Automated builds and checks do not replace a physical pass for unchecked rows.
