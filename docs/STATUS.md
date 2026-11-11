# v0.1 status: verified and unverified

Test environment: Linux x86_64 (Ubuntu 24.04), Swift 6.0.3 (Ubuntu's `swiftlang` package), OpenSSH 9.6 as the test SSH server. No Mac, Xcode, iOS SDK, simulator or device was available.

**Result: 81 package tests, 0 failures, 0 skipped** (`HCG_SSH_TEST=1 swift test`, with `Scripts/start-test-sshd.sh` running).

Note for Linux only: Ubuntu's packaged `libswiftObservation.so` has an unresolved toolchain symbol, so the test binary was linked with `swift build --build-tests -Xlinker --allow-shlib-undefined`. This is a packaging issue of that toolchain, not of this code; it does not apply to Xcode or the official toolchains.

## Verified by tests

| Area | What was exercised |
|---|---|
| Mode switching | Remote sessions are never closed or re-targeted; idle local sessions move only after explicit confirmation and restart fresh; running commands are never moved; nothing moves into an unavailable mode; preference persists |
| Standard build behaviour | Selecting Unleashed shows the exact unavailable message, opens no session, does not crash |
| Capability detection | Stock-device and rootless-jailbreak environments (scripted probes); a single indicator is not enough; detected ≠ verified; loopback service; spawn failure reported with the real error |
| Unleashed execution (on Linux) | Real `posix_spawn` + PTY with `dash` and `bash`: command output, window size via `stty size`, exit status, capability moving to *available* after a real start |
| Privileged commands | Return held until approval; declined line never runs, approved line runs as typed (dash and bash); no presenter = denied; each request decided once |
| Packages and locations | Exact apt command, no `sudo` added, invalid names rejected, declined approval throws; browser refuses paths outside permitted roots and `..` escapes |
| Vanilla | Built-ins on the workspace (pipes, redirection, globs, `&&`/`||`), sandbox escape via `..` and symlinks refused, other programs refused with exit 127 and never forwarded |
| SSH (real OpenSSH) | Unknown host key needs approval and the fingerprint matches `ssh-keygen -lf`; trusted key remembered; changed key refused without prompt; wrong password fails; Ed25519 key auth; exec stdout/stderr/status; PTY shell size and resize; closing one session leaves others and the connection working; PTY command exit status |
| Remote development (real SSH) | Browse a project, detect SwiftPM, `swift build` and `swift test` over SSH, test summary parsed, executable discovered and downloaded with SHA-256 matching the host |
| Parsers and guards | swiftc/clang and MSBuild diagnostics; XCTest, Swift Testing and dotnet test summaries; publishing guard blocks altool, fastlane pilot/beta/deliver, `-exportArchive`, nuget push, notarytool submit, npm publish, GitHub releases |

## Verified on Apple platforms (CI, `.github/workflows/apple-build.yml`)

GitHub-hosted `macos-latest` runner, **Xcode 26.6, Apple Swift 6.3.3**, iPhoneOS 26.5 SDK, deployment target iOS 17.0:

| Check | HCGTerminal | HCGTerminalUnleashed |
|---|---|---|
| Release build, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED | BUILD SUCCEEDED |
| Unsigned archive (HCG Executable Maker's *Unsigned* invocation) | ARCHIVE SUCCEEDED | ARCHIVE SUCCEEDED |
| App in archive | `HCGTerminal.app`, `com.hakmicapitalgroup.hcgterminal`, arm64 | `HCGTerminalUnleashed.app`, `com.hakmicapitalgroup.hcgterminal.unleashed`, arm64 |
| Errors / warnings from project sources | none | none |

Each scheme builds only its own target; the targets have no dependencies on each other.

macOS: the HCGTerminalKit package builds and its tests run on the same runner (Darwin PTY, `posix_spawn`, `sysctl`, Keychain code paths).

Fixed after the first Xcode builds:
- `TerminalHostView`: `Color` was ambiguous (SwiftUI and SwiftTerm both export one) → `SwiftUI.Color`.
- `BuildCenter`: weak capture inside an implicitly strong task capture, with one main-actor `Task` per log chunk (unordered) → ordered streams, explicit capture.
- `POSIXProcess`: `posix_spawn_file_actions_addchdir_np` is unavailable in the iOS SDK → shell trampoline on iOS, file action elsewhere.
- `PTYProcess` on Darwin: window size set before the secondary side was opened was discarded (child saw 0×0) → size set with the secondary side held open.

## Not verified

- **Signed archive and IPA export.** No signing certificate, team or provisioning profile is available to these builds, so nothing has been signed or exported. No IPA exists yet.
- **Running on an iPhone or iPad** (Simulator or device), including the Files-app workspace and the local-network prompt.
- **Unleashed on a jailbroken device**: whether the sandbox allows spawning, the rootless `/var/jb` layout, apt/dpkg, loopback terminal services. On most jailbreaks a sandboxed app cannot spawn processes; the build then reports that truthfully.
- **Remote builds against a Mac**: `xcodebuild` and `dotnet` plans, scheme listing and Xcode artifact discovery were tested for command construction only. Only SwiftPM was run end to end (against Linux).
- **Claude Code**: launched with a placeholder command over a real PTY channel, not with Claude Code itself.
- **Visual match with HCG ONE**: the selector follows the inspected `ExperienceSwitcher` structure and tokens; it has not been compared on screen.

## Not implemented in v0.1

- Importing existing private keys (only on-device Ed25519 generation); RSA keys (not supported by SwiftNIO SSH).
- SFTP; artifacts transfer over the exec channel.
- Reconnecting dropped SSH sessions automatically.
- An app icon (the asset slot is empty).
