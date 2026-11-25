# Connected Devices (HCG Device Link)

**Connected Devices** (sidebar → Device) connects HCG Terminal to an HCG Server through HCG Device Link
(`hcg.devicelink/1`). The protocol is specified in HCG-Server `docs/DEVICE-LINK.md`. HCG Terminal uses
the shared Swift client from HCG-Server, vendored unmodified in `HCGDeviceLink/`. CI checks the copy
against `HCGDeviceLink/VENDORED.sha256`. To update it, re-vendor from HCG-Server; never edit it here.

## What it does

| Section | What you see |
|---|---|
| HCG Connect account | Whether sign-in is configured, and the signed-in account. Sign-in uses `ASWebAuthenticationSession` with PKCE. Tokens are kept only in the Keychain (this device only). A local-development pairing is labelled **LOCAL DEVELOPMENT — not an HCG account** here. |
| This device | Marked **LOCAL**: name, app and variant (Vanilla or Unleashed), the short installation ID, the key fingerprint (groups of four), the key kind (Secure Enclave or software) and the capabilities this installation advertises. |
| Pair with HCG Server | Paste an invitation code (`hcg1-…`). Before anything is sent, the screen shows the server's name, its address, its key fingerprint and this device's key fingerprint, so you can compare them with HCG Server's approval screen. After you send the request, the app checks every few seconds until the owner approves or rejects it. An invitation from a server in local development pairing mode (`"am": "local-development"`) is labelled **LOCAL DEVELOPMENT — not an HCG account** and can be used without HCG Connect (see below). |
| HCG Server host | Shown once paired. The host summary from the server's last answer (name, platform, chip, memory, load, agent version and uptime, gateway exposure) and whether the server is **Reachable**, **Unreachable** (with the real network or TLS error) or answering with an error. Nothing is shown before the server answers. |
| Hosted services | Each service HCG Server hosts (for example HCG System Tester, `system-tester`): status, health, uptime, restarts, last health check. **Open in Safari** appears for openable services; see *Opening a hosted service*. |
| Server diagnostics (read only) | The server's summary lines, availability, version, uptime, authority, TLS (device API, server key SHA-256, gateway state, exposure, CA SHA-256, certificate expiry), failed authentications in the last 24 h and the redacted security events. Nothing here can change the server. |
| Connection | The state, with the next retry time when offline, and the time of the last sync. |
| Paired devices | The server (marked **SERVER**) and your other installations, each marked **REMOTE**. Each shows its name, app, variant, platform, presence (online, offline or never seen, with when it was last seen) and the capabilities it advertises. |
| Shared reports | Reports from other devices: title, sender, when it was received, and status. Opening a report marks it `opened`. |
| Pending approvals | Shows the server's note. The list is always empty in this milestone, because action execution is disabled. |
| Removal | **Remove This Device from the Server** (`/unregister`, after you confirm) and **Forget Pairing on This Device Only**. Both delete the installation key on this device. |

The app syncs only while this screen is open and the app is in the foreground:

- a heartbeat with the advertised capabilities every 20 s, together with the device list, approvals, the host and its
  services (`link/services`) and the diagnostics (`link/diagnostics`);
- the inbox every 10 s.

Retryable errors back off 1, 2, 4 … 60 s with ±20 % jitter, and `retryAfterSeconds` is honoured. Errors that end the
link stop syncing and are remembered, so reopening the screen does not retry:

- `device_revoked`, `wrong_account`, `access_revoked` and `pin_mismatch` show *Removed from the server*;
- `hcg_session_ended` shows *Sign-in ended* and signs out on this device;
- `authority_changed` shows *Pair again*: the server switched how it authorizes apps (local development pairing
  switched off, or HCG Connect configured or removed). The reason is kept across relaunches, the installation key is
  replaced, and the pair section is offered for a new invitation.

A missing ERP permission for one part (for example approvals) is shown on that section only. A server without hosting
(`501 hosting_unavailable`) shows *This HCG Server does not host services.*; data from an earlier answer is dropped
rather than shown as current.

## Local development pairing

HCG Server's owner can switch on local development pairing (`hcg-agent link dev-mode on
--i-approve-local-development-pairing`) while HCG Connect is not configured on the server. Its invitations carry
`"am": "local-development"`.

- HCG Terminal pairs with such an invitation without HCG Connect: it uses `LocalDevelopmentTokens`, so no HCG token is
  ever sent (the server refuses one). The server authorizes the installation key and the owner's approval, for that
  server only; nothing is granted on HCG services and every remote action is refused.
- The pairing record keeps `authMode`, so relaunches use the same path.
- Every place the connection appears says **LOCAL DEVELOPMENT — not an HCG account**: the pair preview, the account and
  connection sections, the host section, paired devices with that authority, the diagnostics' authority and the
  dashboard summary.
- A normal invitation still needs HCG Connect exactly as before.

## Opening a hosted service

**Open in Safari** asks HCG Server for a single-use link (`POST link/services/{id}/open`, valid once within 60 s) and
hands it to the system browser with `openURL`. Only an `https` link is opened, and the link is not kept. Safari verifies
the gateway with the **HCG Server Local CA**, which must be installed and trusted on the device first; HCG Terminal has
no web view for it and never weakens certificate checks. The screen then shows the CA SHA-256 and the server's note,
and warns if the CA differs from the one in the diagnostics.

If the gateway is reachable from the Mac only, the server refuses with `gateway_local_only`. The screen explains that
the owner must approve local-network exposure on the Mac (`hcg-agent hosting expose lan
--i-approve-local-network-exposure`).

Nothing in Connected Devices is needed by any local feature. When the server or HCG cannot be reached, the
terminal, files and SSH work exactly as before.

## Capability advertising: Vanilla and Unleashed

`TerminalLinkCapabilities.advertised(distribution:reports:access:)` builds the advertisement. Its only inputs are:

- the build that is running (from what the app target linked);
- this app's own capability reports (detection plus real use on this device);
- your Capabilities & Access switches.

There is no input from the server.

| Capability | Vanilla build | Unleashed build |
|---|---|---|
| `report.receive`, `report.view` | available | available |
| `terminal.workspace.commands` | available. It is `disabled` when the *Local workspace commands* switch is off, and `unavailable` when the Vanilla report says the workspace is not usable. | same |
| `terminal.remote.ssh` | available, or `disabled` when the *Remote SSH* switch is off | same |
| `terminal.local.shell` | unavailable ("Vanilla build") | `verified` only when the Unleashed report's *Local shell* result is **Verified working** |
| `terminal.files.expanded` | unavailable ("Vanilla build") | `verified` only when *Reading files* is **Verified working** |
| `terminal.privileged` | unavailable ("Vanilla build") | `verified` only when *Privileged operations* is **Verified working** |

For the three Unleashed capabilities, every other result is advertised as follows:

| Result | Advertised as |
|---|---|
| No Unleashed report, or the backend is not included | unavailable, "Unleashed helper not available" |
| Detected but not used yet | unavailable, "Not verified on this device yet" |
| Permission denied, tool missing or not observable | unavailable, with that label and its reason (shortened) |
| Switched off by you | `disabled` |

A `verified` entry carries the time of the check and a short, fixed description, never local paths. The app name, the
bundle identifier, installed packages and marker files are never used on their own.

Advertisements are information. HCG Server may refuse an operation because of them, but they never allow
anything, and nothing the server sends changes what this app may do locally.

## Security notes

**Identity.**
- Each app has its own installation ID and P-256 key (Secure Enclave when available).
- They are kept in the Keychain under the service `<bundle identifier>.devicelink`, so the standard and Unleashed apps never share an identity.
- The key never leaves the device. Every request is signed with it and carries the HCG Connect token.
- HCG Server checks the token, the account and organisation boundary, and the ERP App Access permission on every request.

**Transport.**
- TLS 1.3 to the address in the invitation, pinned to the server key fingerprint from the invitation (`PinnedSessionTransport`).
- No certificate authority or host name is trusted. A different key is refused before anything is sent.
- `Info.plist` sets `NSAllowsLocalNetworking`, so App Transport Security allows the self-signed server on the local network. Other connections keep the default rules.

**Reports are data.**
- The viewer renders `ReportTextRenderer.sections` with `Text(verbatim:)`: no Markdown, no links and no `openURL`.
- Nothing is copied to a shell, a command line or a URL handler. Nothing in a report is ever run.
- The header always says *Report from <device> (remote) — data only, never executed*.

**No remote execution.**
- Pending approvals are shown read-only, and the app has no code path that runs an action from another device.
- A server claim that execution is enabled is ignored.

**Configuration.**
- `hcg-connect.json` (contract `hcg.terminal.connect/1`) is read from Application Support (`HCGTerminal/hcg-connect.json`) or, if that file does not exist, from the app bundle.
- A file with secret-looking or unknown keys is refused.
- The bundled file contains only the contract version.

## What is not done

- **No HCG Connect client ID has been issued for HCG Terminal.** Sign-in shows: *HCG has not issued an HCG Connect client for HCG Terminal yet, so sign-in is not configured. Nothing is contacted.* No client ID or redirect URI is invented. When HCG issues them, put `clientId` and `redirectUri` in `hcg-connect.json`.
- **No remote command execution.** Device Link carries no shell or command. Remote shells stay on Terminal's SSH workflow with host-key verification.
- **No verification of other devices.** Other devices' capabilities are their own statements and are only displayed. Whether a device belongs in the boundary is decided by HCG Server's owner when they approve it.
- **No background sync and no push.** Polling runs only while the screen is open in the foreground.
- **HCG Terminal does not send reports** in this milestone (it does not advertise `report.send`).
- **No control of hosted services.** HCG Terminal shows them and opens them in Safari; it cannot start, stop or
  configure them.
- **Not tested against a real HCG Server, and not run on a device.** The logic is covered by package tests against a scripted server (`DeviceLinkIntegrationTests`). The SwiftUI screen is compiled only by the iOS CI builds.
