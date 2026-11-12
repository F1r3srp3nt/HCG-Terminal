# Device test checklist

Nothing below has been verified on a device by the project. CI and the scripted fixtures in `UnleashedDiagnosticsTests` reproduce what the device screenshots showed, but they are not device evidence. Fill in each line with **Pass / Fail / Not run**, the date and the build (Diagnostics → Build: version, build number, revision).

## Phone A — iPhone 11 Pro Max (iPhone12,5), iOS 17.4, Dopamine-style markers under /var/jb

### A1. Unleashed build installed from Xcode (sandboxed): the current installation

| # | Step | Expected |
|---|---|---|
| A1.1 | Diagnostics → Build | Variant "Unleashed (backend included)", no warnings |
| A1.2 | Tap Unleashed in the mode selector | Sheet titled "Unleashed partially available". The current mode is kept. |
| A1.3 | Working list | Directory listing ("Verified working", **partial**, scope /var/jb, /var/jb/etc, /var/jb/var/log …), Reading files, Package inventory |
| A1.4 | Not working list | Local shell and Running programs: **Permission denied** (never "Tool missing"). Writing files: Permission denied (access(W_OK) refused). Localhost SSH: no service listening. Process inspection, Privileged operations, Package changes: blocked, each with its reason. |
| A1.5 | All checks → Local shell | Every attempted path is listed (16 shell paths: /var/jb and / × bin, usr/bin × zsh, bash, sh, dash), each with its call, errno and time |
| A1.6 | Test local shell | It runs once, then reports the real launch result (expected: refused, EPERM). The shell stays "Permission denied", never "Verified". |
| A1.7 | Recheck | The check time updates; earlier test results keep their own time |
| A1.8 | Unleashed Tools → Permitted locations | /var/jb is browsable. A folder that cannot be listed shows its error inline and navigation keeps working. |
| A1.9 | Unleashed Tools → Packages | Count and source "/var/jb/var/lib/dpkg/status". Install/Remove are not offered; the reason is shown instead. |
| A1.10 | Settings → Capabilities & Access → turn off "Unleashed features" | Unleashed rows show "Disabled by you"; Vanilla and Remote SSH are unaffected |
| A1.11 | Localhost SSH (this device) | If no SSH package runs: connecting fails with "connection refused" and the status stays "Tool missing" |

### A2. Optional: localhost SSH fallback (needs an SSH server package running on the phone)

| # | Step | Expected |
|---|---|---|
| A2.1 | Configure connection: 127.0.0.1, port of the service, account, password | Host-key approval sheet appears with the fingerprint |
| A2.2 | Approve and connect | A terminal opens. Localhost SSH becomes "Verified working" only now. |
| A2.3 | Wrong password | Authentication error; the status is not verified |
| A2.4 | Turn off "Localhost SSH fallback" with the session open | A confirmation lists the session. Cancel keeps it; confirm disconnects it with "not verified" for remote programs. |

### A3. Unleashed `.deb` installed without the sandbox (needs your jailbreak details)

| # | Step | Expected |
|---|---|---|
| A3.1 | `Scripts/package-ios.sh unleashed dist --deb rootless --ldid-entitlements <file>`, install with Sileo/Zebra/`dpkg -i` | The app appears on the home screen (from /var/jb/Applications) |
| A3.2 | Diagnostics → Unleashed environment → process | Not an app container; install route "Unknown" |
| A3.3 | Test local shell | `HCG_SHELL_OK` and status 0. Local shell becomes "Verified working". |
| A3.4 | New Session → Local Unleashed | Interactive shell; `stty size` matches after rotating; Ctrl-C stops `sleep 30`; `exit 3` shows status 3 |
| A3.5 | Close the session while `sleep 100` runs | Process gone (`ps`), exit confirmed |
| A3.6 | Write test in a writable folder you pick | "Created, wrote and read back… removed"; only that file touched |
| A3.7 | Turn off "Local shell execution" with a shell open | Confirmation, then the shell is stopped with its exit confirmed |
| A3.8 | Packages → install a small package | Approval sheet with the exact apt command; it runs visibly in a new session |

## Phone B — iPhone17,2, iOS 27.0.1, no jailbreak observed

| # | Step | Expected |
|---|---|---|
| B1 | Standard build (HCGTerminal) | Header and home list render. Unleashed rows say "Not in this build" and have no switches. |
| B2 | Unleashed build from Xcode | "Unleashed is not available"; local items show Environment unknown or Permission denied with the real errno, never "Tool missing" for refused paths |
| B3 | Bootstrap evidence | "Unknown — not observable from this app" (not "not jailbroken") |
| B4 | Test local shell | "Nothing to launch: none of the … shell paths exists as a file", or a refused launch. Never "Verified". |
| B5 | Vanilla session and Remote SSH | Work as before; switching modes never disconnects SSH |
| B6 | Accessibility | Largest Dynamic Type sizes, VoiceOver reads the header once as "HCG Terminal", Reduce Motion |

## What to send back

- Screenshots of: the Unleashed sheet, All checks expanded for Local shell, Running programs and Directory listing, and Setup requirements.
- **Jailbreak name and version, bootstrap (rootless/rootful), and whether TrollStore is installed.** These decide the exact entitlements for the `.deb` route.
