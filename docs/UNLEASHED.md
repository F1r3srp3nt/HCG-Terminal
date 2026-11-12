# HCG Terminal Unleashed

The Unleashed variant (`HCGTerminalUnleashed` scheme, bundle ID `com.hakmicapitalgroup.hcgterminal.unleashed`) adds a backend that uses what an **already configured** device actually allows: a local shell in a pseudo-terminal, installed command-line tools, permitted folders outside the app sandbox, the process list and the device's package manager. It contains no jailbreak, no exploit and no way to raise privileges. Every capability is enabled only after a read-only check finds it, and is shown as *Verified working* only after it has actually worked.

The standard variant (`HCGTerminal`) does not contain this backend at all. See `BUILD_VARIANTS.md`.

## What works where

| Device / installation | Local shell | Tools | Folders outside sandbox | Packages | Processes |
|---|---|---|---|---|---|
| Ordinary iPhone/iPad, any installation | Unsupported environment | Unsupported | Unsupported | Unsupported | Permission denied |
| Configured device, app installed **sandboxed** (Xcode, TestFlight, ad hoc) | **Permission denied** for starting a shell (the sandbox refuses `posix_spawn`); **available** through the device's own SSH service on 127.0.0.1 if it is running | Through that service only | Usually permission denied | Through that service only | Usually permission denied |
| Configured device, app installed **without the sandbox** by the device owner | Available → verified after the first session | Available | As the device's file permissions allow | Listing; changes after approval | As the system allows |

The capability screen (Preferences, or tapping **Unleashed**) shows which row applies, with the checks that ran and their results (`EPERM` vs `ENOENT`, which shells and tools were found, which ports answered).

## Prerequisites (device owner)

These are not provided, installed or modified by HCG Terminal:

- A device the owner has already set up with a supported rootless userland (`/var/jb`) that includes a POSIX shell (`sh`, `bash` or `zsh`). The scanner also recognises tools at the system root.
- For the terminal-service path: an SSH server package installed and **running** on the device, listening on 127.0.0.1 port 22 or 2222, and a known password for the account you sign in with (usually `mobile`). HCG Terminal verifies its host key on first use exactly like a remote host.
- Optional: `apt`/`dpkg` (package listing and approved changes), `sudo` (only ever run by you, it asks for its own password).
- iOS/iPadOS 17 or later (the app's deployment target).

## Installing the Unleashed variant

It is a separate app with its own bundle ID and is installed separately from the standard app; both can be installed side by side.

**A. Sandboxed (simplest).** Build and run the `HCGTerminalUnleashed` scheme from Xcode with your development team (or distribute it ad hoc). Local process starts will be reported as *Permission denied*; use **New Session → Connect to Local Terminal Service** if the device runs an SSH server. Remote development works as in the standard app.

**B. Without the app sandbox (owner's decision).** Only some configured devices can run apps outside the sandbox, using the installation method that device already provides. To prepare the files:

```bash
Scripts/package-ios.sh unleashed dist
# dist/unleashed/HCGTerminalUnleashed-<version>-<build>-<revision>-unsigned.ipa
# dist/unleashed/HCGTerminalUnleashed-<version>-<build>-<revision>-unsigned.xcarchive
# dist/unleashed/README.txt
```

The `.ipa` is unsigned. `HCGTerminal-Support/Unleashed-optional-entitlements.example.plist` documents the entitlement such installations use; no target uses it, and HCG Terminal never signs, installs, or changes code-signing or security settings. Such a build is not valid for the App Store or TestFlight.

Artifacts stay separate: `dist/standard/…` and `dist/unleashed/…`, file names start with the scheme name, and the script refuses to package a bundle whose `HCGBuildVariant` or bundle ID does not match the requested variant.

## Safety rules the backend follows

- Detection is read-only (`lstat`, `access`, directory listing, `sysctl`, loopback TCP connect without data). No single marker (such as `/var/jb`) makes anything available.
- Shells and tools run with the app's own user ID and permissions. HCG Terminal never adds `sudo`, never supplies passwords, never changes permissions, never remounts or modifies system partitions.
- Privileged-looking commands typed into a local shell (`sudo`, package changes, `launchctl`, writes to system paths, …) are held until you approve each one; declined lines are erased, not run.
- File changes outside the sandbox: only inside locations the scan could list, only where `access(W_OK)` succeeds, and changes under system or jailbreak locations (`/var/jb`, `/usr`, `/etc`, …) need approval each time. Symlinks out of a permitted location are refused.
- Package installs/removals produce the exact `apt` command only after approval and run visibly in a new local session.
- Remote SSH host-key verification is the same as in the standard app; a changed key is refused.

## Device tests still needed

Not yet run on hardware (no device was available while developing):

- Ordinary iPhone and iPad with the Unleashed build: all local capabilities reported as unsupported/denied, Vanilla and remote unaffected.
- Configured device, sandboxed install: `posix_spawn` refusal reported as *Permission denied*; terminal-service sign-in verified.
- Configured device, unsandboxed install: shell starts (window size, Ctrl-C, exit status), package listing, file writes in a writable location, approval prompts for `/var/jb` changes.
