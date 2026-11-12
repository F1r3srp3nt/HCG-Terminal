# Build variants

HCG Terminal has two app targets built from the same sources. They are separate apps with separate bundle identifiers; one never turns into the other at runtime.

| | Standard | Unleashed |
|---|---|---|
| Scheme / target | `HCGTerminal` | `HCGTerminalUnleashed` |
| Bundle ID | `com.hakmicapitalgroup.hcgterminal` | `com.hakmicapitalgroup.hcgterminal.unleashed` |
| Home-screen name (`CFBundleDisplayName`) | HCG Terminal | HCG Terminal Unleashed |
| `HCGBuildVariant` (Info.plist) | `standard` | `unleashed` |
| Swift condition | — | `HCG_UNLEASHED_BUILD` (Debug and Release) |
| Package products linked | TerminalUI, FileWorkspace | + UnleashedIntegration (→ UnleashedExecutionProvider) |
| Archive configuration | Release | Release |
| Distribution | App Store / TestFlight | Separate installation on a configured device (see `UNLEASHED.md`) |

## How to see which one is installed

Open **Diagnostics → Build** (or Preferences). It shows:

- **Variant**: decided by the code linked into the binary, never by the name;
- **Version** (`CFBundleShortVersionString`) and **build number** (`CFBundleVersion`);
- **Source revision**: the git commit, stamped into Info.plist by `Scripts/stamp-build-info.sh` during the build (`-modified` if the working tree had uncommitted changes, `unknown` if git was not available);
- **Bundle ID**, display name and the declared `HCGBuildVariant`;
- a warning if any of these disagree (for example a bundle named "Unleashed" without the backend).

CI (`.github/workflows/apple-build.yml`, step *Build identity*) fails if the HCGTerminal binary contains Unleashed backend symbols, if the HCGTerminalUnleashed binary lacks them, or if `HCGBuildVariant` does not match the scheme.

## Why TestFlight build 0.1.0 (1) contained the standard backend

The installed app reported "Standard build" and "backend not included". In the code that text exists only in the composition used when `HCG_UNLEASHED_BUILD` is **not** defined, and only the `HCGTerminal` target is built without it (both its Debug and Release configurations). So that archive was built from the **HCGTerminal** scheme.

The name "HCG Terminal Unleashed" in TestFlight is not taken from the app binary: TestFlight shows the **name of the App Store Connect app record**. The standard binary's own display name is "HCG Terminal", which is what appears under its icon on the home screen.

Contributing factor: HCG Executable Maker preselects the first shared scheme alphabetically (`HCGTerminal`), and its project summary lists every target's bundle ID, including the Unleashed one, so the summary can suggest Unleashed while the Standard scheme is being archived.

To check an existing upload: the bundle ID of the App Store Connect record (App Information) tells you which target it belongs to: `…hcgterminal` is Standard, `…hcgterminal.unleashed` is Unleashed.

## Recommended App Store Connect setup

- Name the record for `com.hakmicapitalgroup.hcgterminal` "HCG Terminal".
- The Unleashed variant needs its own bundle ID. A TestFlight/App Store build of it is sandboxed like any other app, so its local shell will report *Permission denied* on most devices; see `UNLEASHED.md` for what it can and cannot do there.
