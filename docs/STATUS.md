# Status: what is verified, and how

Three kinds of evidence are kept apart:

- **Automated**: package tests on Linux and macOS, and iOS device builds in CI.
- **Simulator**: CI installs both apps in the iOS Simulator and launches them.
- **Physical device**: nothing has been verified on a physical iPhone or iPad by this project yet. Your own TestFlight install of the standard build is the only device evidence. Its screenshots showed the standard backend, which is explained in `BUILD_VARIANTS.md`.

## Automated

| Where | Toolchain | Result |
|---|---|---|
| Linux x86_64 | Swift 6.0.3, OpenSSH 9.6 test server (`HCG_SSH_TEST=1`) | **144 tests, 0 failures, 0 skipped**, including real-SSH build/test/cancel/artifact workflows |
| macOS (CI, `macos-latest`) | Xcode 26.6, Swift 6.3.3 | 144 tests, 0 failures, 12 skipped (the SSH-server tests) |
| iOS Simulator runtime (CI) | Xcode 26.6 | 130 tests in 7 bundles, `** TEST SUCCEEDED **` |

Linux note: Ubuntu's packaged `libswiftObservation.so` needs `-Xlinker --allow-shlib-undefined` when building the tests. This is a toolchain packaging issue only.

### Covered by tests in this milestone

- **Capabilities & Access** (`AccessPolicyTests`): defaults, prerequisites, persistence including unknown keys, observers, reset.
- **Service-level enforcement** (`AccessEnforcementTests`):
  - built-in shell: refuses new sessions and each command once off;
  - import and export;
  - host filesystem: read and write enforced separately, and write blocked by its read prerequisite;
  - write test removes its file;
  - package listing and changes: refused without asking;
  - privileged requests: refused without asking while off;
  - process table not read while off;
  - shell: input dropped while off, and stopping it confirms the exit;
  - provider refuses to open a shell;
  - programs: run with a time limit; errors reported accurately.
- **SSH and builds** (`SSHAccessTests`, `BuildAccessTests`): SSH refused before any network activity; the loopback service uses the shell switch; builds are not started while builds or SSH are off, and nothing is sent.
- **Layered detection** (`EnvironmentAssessmentTests`):
  - a sandboxed process gets "not observable", never "not jailbroken";
  - `/var/jb` symlinked to a relocated root is resolved once;
  - relocated root without `/var/jb`, custom root, rootful indicators, weak-indicator-only device;
  - indicators found but spawn refused gives *Permission denied*;
  - a switch never upgrades a status.
- **Active-session transitions** (`AccessTransitionTests`):
  - turning a switch off asks first, and cancel keeps everything;
  - confirming stops only the affected sessions and keeps them listed;
  - the outcome never claims remote termination;
  - mode switching never disconnects SSH;
  - appearance settings persist.
- **Fixed race:** a PTY descriptor could be reused while its reader thread still held it. This intermittently caused empty process output (1 in 12 runs before the fix, 0 in 20 after).

### HCG Device Link (Connected Devices)

- **Linux, Swift 6.0.3:** 221 tests, 12 skipped (the SSH-server tests), 0 failures. 184 before this change; the 37 new tests are in `DeviceLinkIntegrationTests` (36) and `TerminalAppModelTests` (1). They cover capability advertising for both builds, the connection-state reducer and back-off, the `hcg-connect.json` rules (the shipped file has no client ID), and pairing, sync, report viewing and removal against a scripted server.
- **Not verified yet:** the Connected Devices screen has not been compiled or run by this project (it is SwiftUI, iOS only; CI builds it). Nothing has been tested against a real HCG Server, and HCG Connect sign-in cannot be tested until HCG issues a client. See `CONNECTED_DEVICES.md`.

## iOS builds in CI (`.github/workflows/apple-build.yml`, run 43143412406, commit a9e7e38)

| Check | HCGTerminal | HCGTerminalUnleashed |
|---|---|---|
| Release and Debug builds (signing disabled) | BUILD SUCCEEDED ×2 | BUILD SUCCEEDED ×2 |
| Unsigned archive | ARCHIVE SUCCEEDED | ARCHIVE SUCCEEDED |
| "Verify build variant" build phase, every build | standard · backend not linked | unleashed · backend **linked** |
| `nm` symbols of `UnleashedExecutionProvider` | 0 | 1701 |
| Variant-check self-test (6 fake bundles) | all PASS | all PASS |
| App icon metadata | PASS | PASS |
| Packaging | `dist/standard/` | `dist/unleashed/` (unsigned `.ipa`) plus rootless (`iphoneos-arm64`) and rootful (`iphoneos-arm`) `.deb` files. Their contents were checked, they were re-verified after extraction, and the ldid entitlements were printed. |
| Warnings from project sources | 0 | 0 |

The macOS package build had one deprecation warning (`String(cString:)`), fixed in fe458ee.

## Simulator (CI)

Both apps were installed and launched in an iPhone simulator. Each was driven into 8 states (launch, dashboard, Unleashed tap, session, Capabilities & Access, Settings, Files, Diagnostics) with Debug-only `-HCGSmokeScenario` arguments. All **16 checks** found the app still running. Screenshots are in the run's `simulator-screenshots` artifact; they have not been reviewed by a person.

## Not verified

- **Any physical device**: layout on small iPhones and iPad, VoiceOver, largest Dynamic Type sizes, Reduce Motion / Reduce Transparency, the light System theme, and the key row with a hardware keyboard.
- **Unleashed on a jailbroken device**: a sandboxed install (expected *Permission denied* / *not observable*) and an install from the `.deb` (shell, programs, packages, write test, prompts). The required jailbreak, iOS version and bootstrap are not yet known.
- **Whether a jailbreak accepts the `.deb`'s ldid pseudo-signature and the example entitlements.**
- **Signed archive and IPA export**: nothing has been signed or exported with a team. HCG Terminal never uploads.
- **Remote builds against a Mac** (`xcodebuild`) or a .NET host: command construction is tested; only SwiftPM ran end to end.

See `TODO.md` for the milestones that close these gaps.
