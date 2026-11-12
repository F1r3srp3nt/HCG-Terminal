# Build variants

HCG Terminal has two app targets built from the same sources. They are separate apps with separate bundle identifiers; one never turns into the other at runtime.

| | Standard | Unleashed |
|---|---|---|
| Scheme / target | `HCGTerminal` | `HCGTerminalUnleashed` |
| Bundle ID | `com.hakmicapitalgroup.hcgterminal` | `com.hakmicapitalgroup.hcgterminal.unleashed` |
| Home-screen name (`CFBundleDisplayName`) | HCG Terminal | HCG Terminal Unleashed |
| `HCGBuildVariant` (Info.plist) | `standard` | `unleashed` |
| Swift condition | — | `HCG_UNLEASHED_BUILD` (Debug and Release) |
| Target-only source folder | `Variants/Standard` | `Variants/Unleashed` |
| Package products linked | TerminalUI, FileWorkspace | + UnleashedIntegration (→ UnleashedExecutionProvider) |
| Build check | "Verify build variant" phase: backend marker must be **absent** | "Verify build variant" phase: backend marker must be **present** |
| Archive configuration | Release | Release |
| Distribution | App Store / TestFlight | Separate installation on a configured device (see `UNLEASHED.md`) |

## How the backend gets into the Unleashed app (and cannot silently go missing)

The project gives each app target its own synchronized source folder, in addition to the shared `HCGTerminal/` folder.

- `Variants/Standard/VariantComposition.swift` is compiled only into `HCGTerminal`. It builds the standard dependencies.
- `Variants/Unleashed/VariantComposition.swift` is compiled only into `HCGTerminalUnleashed`. It calls `UnleashedIntegration.dependencies(…)`, which links the backend.

Which backend is linked therefore follows from **target membership**, not from a flag that an external build tool could override. Three independent checks back this up:

1. **Compile time.** Each file contains an `#error` that stops the build if it is compiled with the wrong `HCG_UNLEASHED_BUILD` condition. If the file were missing from the target, `VariantComposition` would be undefined and the build would fail.
2. **After linking (every build, including Archive).** The "Verify build variant" phase runs `Scripts/verify-build-variant.sh`. It reads `HCGBuildVariant` and searches the executable, plus Xcode's `<name>.debug.dylib` in Debug builds, for the backend marker string `HCG-UNLEASHED-BACKEND-LINKED-v1`. The marker is referenced at runtime, so it is only present when the backend is linked. A mismatch fails the build with an `error:`.
3. **Packaging and CI.** `Scripts/package-ios.sh` runs the same check before it writes anything. CI runs the script on the Release app and on the extracted `.deb`, and runs `Scripts/tests/verify-build-variant-test.sh`, which feeds it fake bundles: a correct one, a "named Unleashed but no backend" one, and a "standard with backend" one.

At runtime, Diagnostics → Build shows the variant decided by the linked code. It warns if the declared variant, bundle ID, display name or backend marker disagree.

Signing settings, bundle identifiers, entitlements and app icons are unchanged by this.

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
- The Unleashed variant needs its own bundle ID. To put it on TestFlight you would need a **separate** App Store Connect record for `…hcgterminal.unleashed`.
- A TestFlight or App Store build of Unleashed is sandboxed like any other app, so its local shell reports *Permission denied* even on a jailbroken device. Expanded access needs an unsandboxed installation; see `UNLEASHED.md`.
- In HCG Executable Maker, choose the scheme explicitly; it preselects `HCGTerminal`. The "Verify build variant" phase now fails any Unleashed build that lacks the backend.
