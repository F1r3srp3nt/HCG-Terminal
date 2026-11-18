# HCG Nexus handoff (contract version 1)

HCG Nexus, a separate app by the same owner, can hand off to HCG Terminal by opening a URL. A
link can do exactly two things: bring HCG Terminal to the front, or show one of Terminal's saved
connections so the user can tap **Connect**. Nothing else is accepted.

HCG Terminal keeps owning credentials, host keys and sessions. Nexus never reads Terminal's
data, and no session state is shared with Nexus in either direction.

## Detecting support

| Info.plist key | Type | Value |
|---|---|---|
| `HCGNexusHandoff` | integer | `1` (this contract version) |
| `CFBundleURLTypes[0].CFBundleURLName` | string | `com.hakmicapitalgroup.hcgterminal.nexus-handoff` |
| `CFBundleURLTypes[0].CFBundleURLSchemes` | array | one scheme, per variant (below) |

Nexus can read these from the installed app's Info.plist. A missing `HCGNexusHandoff` means the
build predates handoff; a higher value means a later contract.

## Schemes

Each variant declares only its own scheme, so iOS never has to choose between two installed
apps, and each build accepts only its own scheme.

| Variant | Bundle ID | Scheme |
|---|---|---|
| Standard | `com.hakmicapitalgroup.hcgterminal` | `hcgterminal` |
| Unleashed | `com.hakmicapitalgroup.hcgterminal.unleashed` | `hcgterminal-unleashed` |

The scheme comes from the per-target build setting `HCG_URL_SCHEME` (set by
`Scripts/generate-xcodeproj.py`), substituted into the shared `HCGTerminal-Support/Info.plist`.
CI checks the built Info.plist of each variant for its scheme and `HCGNexusHandoff = 1`.

## Routes

| Link | Effect |
|---|---|
| `<scheme>://open` | Brings the app forward. No other effect. |
| `<scheme>://connection?id=<UUID>` | Shows the saved connection with that ID in a sheet with **Connect** and **Cancel**. Nothing connects until the user taps Connect. If no saved connection has that ID, a non-blocking notice says "This saved connection isn't on this device." |

`<UUID>` is the canonical 8-4-4-4-12 hexadecimal form (either case), e.g.
`hcgterminal://connection?id=6F9619FF-8B86-D011-B42D-00C04FC964FF`.

The scheme and the route name are compared case-insensitively; everything else is exact.

## Refused links

Anything else is refused: the app shows a short non-blocking notice ("Link ignored. … Nothing was
run.") and does nothing else. A refusal is logged in Diagnostics with a fixed reason code only,
never the link's text. Refused, in order of checking:

- longer than **256** bytes (UTF-8);
- empty, or containing anything other than printable ASCII (spaces, control characters, raw
  Unicode), or not parseable as a URL;
- another scheme, **including the other variant's scheme**;
- not of the form `<scheme>://route` (e.g. `hcgterminal:open`, `hcgterminal:///open`);
- a user name or password (`user@`, `user:pw@`), a port (`:22`, or an empty `:`), a fragment
  (`#…`, even empty) or a path (`/…`, even a single `/`);
- any query parameter named `command`, `cmd`, `run`, `exec`, `script` or `input` (any case,
  percent-encoded names included), on any route: **links never run commands**;
- any other route name (`session`, `connect`, `shell`, a hostname, …);
- `open` with any query, even an empty `?`;
- `connection` with no `id`, an empty `id`, more than one `id`, any parameter other than `id`
  (including `ID`), or an `id` that is not a canonical UUID (braces, missing dashes, wrong
  length, non-hex, percent-escapes, trailing text).

## No automatic execution

A link never connects, never starts a session, never sends input and never runs a command,
local or remote. The only thing a `connection` link does is put that saved connection on screen;
the user decides whether to tap Connect, which opens an ordinary shell exactly as Hosts & Projects
does (with the usual host-key verification and stored credentials).

## Getting a link: "Copy Link for HCG Nexus"

In **Hosts & Projects**, long-press a saved connection (context menu) or open it and tap **Copy
Link for HCG Nexus**. The pasteboard then holds `<own scheme>://connection?id=<UUID>`, using the
running build's scheme. This is how Nexus learns connection IDs. The link contains only the
saved connection's ID: no hostname, address, user name, key or secret.

## Where it lives

| Part | File |
|---|---|
| Parser and link builder (pure, tested on Linux and macOS) | `HCGTerminalKit/Sources/TerminalCore/NexusHandoff.swift` |
| Routing into the app model | `TerminalAppModel.handleOpenURL(_:)`, `nexusLink(for:)` in `HCGTerminalKit/Sources/TerminalUI/Model/TerminalAppModel.swift` |
| Sheet, notice banner, copy action | `HCGTerminalKit/Sources/TerminalUI/Views/NexusHandoffViews.swift` |
| `.onOpenURL` | `HCGTerminal/App/HCGTerminalApp.swift` |
| Tests | `Tests/TerminalCoreTests/NexusHandoffTests.swift`, `Tests/TerminalUITests/NexusHandoffModelTests.swift` |

## Verification

Unit tests cover every accept and refuse rule above for both schemes, the variant mismatch, and
that a copied link round-trips through the parser. CI also opens `open`, an unknown `connection`
and a `command=` link in the iOS Simulator for each variant and checks the app keeps running
(screenshots in `simulator-screenshots/handoff`). Opening links from HCG Nexus on a device has
not been tested.
