# HCG Terminal

Native SwiftUI terminal for iPhone and iPad by Hakmi Capital Group. Local commands, remote SSH development, remote Swift / Xcode / .NET builds and tests, logs and artifacts.

**Status: v0.1 development build.** Both iOS schemes build and archive (unsigned) with Xcode 26.6 in CI; nothing has been signed, exported or run on a device yet. See [`docs/STATUS.md`](docs/STATUS.md) for what is verified and what is not.

## Modes

| | Vanilla | Unleashed |
|---|---|---|
| For | Standard iPhone and iPad | Supported jailbroken devices (separate build) |
| Local terminal | Built-in commands on the app workspace | Real shell in a pseudo-terminal, or an existing local terminal service, **only where the device allows it** |
| Remote SSH, builds, Claude Code | Yes | Yes (same code, independent of mode) |
| Privileged actions | Never | Only after explicit approval of each action, with the permissions the device actually grants |
| Accent | HCG blue/green | Restrained violet |

The **Vanilla | Unleashed** selector sits in every session header and in Preferences. Switching never interrupts SSH sessions. Open local sessions keep running where they are unless you confirm restarting them in the other mode; nothing is ever transferred between environments.

If Unleashed is not available, the app says so:

> Unleashed features are not available in this environment. Vanilla terminal and remote development remain available.

## Layout

```
HCGTerminal.xcodeproj        two app targets sharing HCGTerminal/:
                               HCGTerminal           standard build (no Unleashed code linked)
                               HCGTerminalUnleashed  Unleashed build (adds UnleashedIntegration)
HCGTerminal/                 app entry point, assets (shared by both targets)
Variants/Standard|Unleashed/ per-target composition: decides which backend is linked
HCGTerminal-Support/         Info.plist additions, entitlements
HCGTerminalKit/              Swift package with all modules and tests
Scripts/                     test SSH server, project generator, packaging, build-variant check
docs/                        architecture, distribution, status
```

Modules (in `HCGTerminalKit/Sources`): TerminalCore, TerminalUI, LocalCommandEngine, VanillaExecutionProvider, UnleashedExecutionProvider, TerminalCapabilityProvider, RemoteSSH, FileWorkspace, DeveloperWorkspace, BuildOrchestrator, ArtifactManager, TerminalSecurity (the requested "Security" module; renamed so it does not shadow Apple's Security framework), Diagnostics, and UnleashedIntegration. Details in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Build and install

Requirements: Xcode 16 or later (CI uses Xcode 26.6), iOS / iPadOS 17 or later. Set your team under Signing & Capabilities for the target you build.

| Goal | How |
|---|---|
| Standard app on your own iPhone/iPad | Open `HCGTerminal.xcodeproj`, scheme **HCGTerminal**, your device, Run. |
| Standard app for TestFlight/App Store | Scheme **HCGTerminal** → Product → Archive → Distribute App (you upload; HCG Terminal never does). In HCG Executable Maker choose scheme `HCGTerminal`. |
| Unleashed app | Scheme **HCGTerminalUnleashed**. Separate app (bundle ID `…hcgterminal.unleashed`); see [`docs/UNLEASHED.md`](docs/UNLEASHED.md) for prerequisites and the separate installation. |
| Unsigned artifacts, kept apart | `Scripts/package-ios.sh standard dist` → `dist/standard/…`; `Scripts/package-ios.sh unleashed dist` → `dist/unleashed/…` (unsigned archive; Unleashed also an unsigned `.ipa`). Both refuse a bundle whose code does not match its variant. |
| Jailbroken device (`.deb`) | `Scripts/package-ios.sh unleashed dist --deb rootless --ldid-entitlements <file>`; you install it with the device's package manager. See [`docs/UNLEASHED.md`](docs/UNLEASHED.md). |

**Settings → Capabilities & Access** lets you turn each area on or off (enforced in the services). A switch only limits HCG Terminal; it never grants anything. See [`docs/CAPABILITIES_AND_ACCESS.md`](docs/CAPABILITIES_AND_ACCESS.md). Remaining work: [`docs/TODO.md`](docs/TODO.md).

Check what is installed in **Diagnostics → Build**: variant (from the linked code), version, build number, source revision and bundle ID. [`docs/BUILD_VARIANTS.md`](docs/BUILD_VARIANTS.md) explains the two variants and why the first TestFlight build was the standard one.

### Package tests

```bash
cd HCGTerminalKit && swift test
```

The core modules use only Foundation and also build and test on Linux. Remote SSH integration tests need a disposable OpenSSH server:

```bash
sudo Scripts/start-test-sshd.sh          # Linux only; creates user hcgtest
HCG_SSH_TEST=1 swift test --package-path HCGTerminalKit
```

CI (`.github/workflows/apple-build.yml`) builds both schemes for devices (Debug, Release, unsigned archive, identity, icons, encryption inventory, separate packaging), launches both apps in the iOS Simulator, and runs the package tests on macOS and on the iOS Simulator.

## Distribution

The standard build is meant for ordinary iOS / iPadOS distribution. The Unleashed build is separate and is **not** assumed to be eligible for the App Store. HCG Terminal never publishes or uploads anything — not to TestFlight, App Store Connect or any other channel. See [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md).
