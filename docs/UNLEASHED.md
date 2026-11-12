# HCG Terminal Unleashed

The Unleashed variant adds a backend that uses what an **already configured** device actually allows this app:

- a local shell in a pseudo-terminal;
- installed programs;
- folders outside the app sandbox;
- the process list;
- the device's package manager.

It contains no jailbreak, no exploit, no hidden helper and no way to raise privileges. Detection is read-only. Something is shown as *Verified working* only after it has actually worked.

The standard variant (`HCGTerminal`) does not contain this backend at all; see `BUILD_VARIANTS.md`.

## Which artifact is which

| | Standard | Unleashed |
|---|---|---|
| Scheme | `HCGTerminal` | **`HCGTerminalUnleashed`** |
| Bundle ID | `com.hakmicapitalgroup.hcgterminal` | `com.hakmicapitalgroup.hcgterminal.unleashed` |
| Proof the backend is linked | — | Diagnostics → Build shows "Unleashed (backend included)". The "Verify build variant" build phase found the backend marker in the executable. |
| Package formats | `.xcarchive`, or an `.ipa` you export | Unsigned `.xcarchive` and `.ipa`, plus an optional `.deb` (rootless or rootful) |

If the app says **"Standard build: the Unleashed backend is not linked"**, the installed binary was built from the `HCGTerminal` scheme. The name shown in TestFlight comes from the App Store Connect record, not from the binary. A different display name or bundle ID does not add the backend.

## Installing an ordinary IPA does not grant expanded access

Every app installed through Xcode, TestFlight, the App Store or an ad hoc profile runs **inside the iOS sandbox**. This is true even for the Unleashed build, and even on a jailbroken device. In that case:

- starting a shell is refused by the system (`EPERM`) → *Permission denied*;
- folders outside the container are mostly invisible → *Environment unknown*. That status does not say whether the device is jailbroken.
- the device's own SSH service on 127.0.0.1 can still be used (*Connect to Local Terminal Service*), with that service's account.

Expanded local access needs an installation **outside the sandbox**, done by the device owner with tools their jailbreak provides.

## Supported environment

| Requirement | Detail |
|---|---|
| Device | iPhone or iPad on iOS/iPadOS 17 or later (the deployment target), arm64 or arm64e |
| Userland | A Procursus-based bootstrap, either rootless (`/var/jb`, or a relocated root under `/private/preboot/<UUID>/jb-…` / `dopamine-…`) or rootful (`/`). You can enter a custom root in Settings → Unleashed Environment. |
| Tools | A POSIX shell (`sh`, `bash` or `zsh`). Optional: `apt`/`dpkg` (package list and changes), `sudo` (only ever run by you; it asks for its own password), an SSH server for the loopback route. |
| Installation | Outside the app sandbox (see below) |

Not yet verified on hardware: which jailbreak, iOS version and bootstrap combinations accept the `.deb` route. **Tell us which jailbreak, iOS version and bootstrap you use** so it can be tested and documented exactly.

## Building and packaging (on a Mac with Xcode)

```bash
# Unsigned archive + unsigned IPA, kept apart from the standard build:
Scripts/package-ios.sh unleashed dist
#   dist/unleashed/HCGTerminalUnleashed-<version>-<build>-<revision>-unsigned.xcarchive
#   dist/unleashed/HCGTerminalUnleashed-<version>-<build>-<revision>-unsigned.ipa
#   dist/unleashed/README.txt

# Debian package for a jailbroken device (opt-in; needs `brew install ldid`, optionally `brew install dpkg`):
Scripts/package-ios.sh unleashed dist --deb rootless --ldid-entitlements my-entitlements.plist
#   dist/unleashed/com.hakmicapitalgroup.hcgterminal.unleashed_<version>-<build>_iphoneos-arm64.deb
#   (--deb rootful → _iphoneos-arm.deb, app in /Applications)
```

What the script does and does not do:

- It checks that the app declares the Unleashed variant and that its code contains the backend. If either check fails, nothing is packaged.
- With `--deb` it pseudo-signs **only the copy inside the package**, using `ldid` and the entitlements file you pass. `HCGTerminal-Support/Unleashed-optional-entitlements.example.plist` is a starting point; which entitlements your jailbreak needs is your decision.
- The package's `postinst` runs `uicache` so the home screen shows the app. The package manager prints this step.
- It never installs, uploads, signs with your team, or changes a device or Xcode signing settings.

## Installation routes

| Route | Sandbox | What works |
|---|---|---|
| A. Xcode Run / ad hoc / TestFlight with your team | Yes | Remote development; the loopback terminal service if one runs; local shell *Permission denied* |
| B. `.deb` installed with the device's package manager (Sileo, Zebra, `dpkg -i`) | No, if your jailbreak accepts the pseudo-signature and entitlements | Local shell, programs, folders, packages and processes, as the device permits |
| C. Another unsandboxed installer the device already provides | Depends on the entitlements used | As for B |

Afterwards, open **Settings → Unleashed Environment** and tap **Run Shell Test**. It is the only way to see *Verified working* without opening a session.

## What the app checks (read-only, layered)

1. **Build**: variant and backend marker.
2. **Device**: model, CPU architecture, system and kernel.
3. **Bootstrap evidence**:
   - candidate roots: `/var/jb` with its target resolved, relocated roots under `/private/preboot` when listable, your custom root, and the system root;
   - strong indicators: `.procursus_strapped`, `.installed_dopamine`, `/.bootstrapped`, the dpkg database, `etc/apt`;
   - weak indicators: package-manager app bundles;
   - resolved paths of `sh`/`bash`/`zsh`, `apt`, `dpkg`, `sudo`.
4. **Process**: uid/euid/gid, whether the home is an app container, the install route (TestFlight receipt, provisioning profile), and paths the system refused.
5. **Operations**: what actually happened (spawns, explicit tests, listings, writes).

"Jailbreak indicators found" is shown separately from "this app can run a shell". When nothing is visible from a sandboxed process, the result is *Unknown — not observable*, never "not jailbroken".

Statuses: **Not included · Disabled by you · Environment unknown · Tool missing · Permission denied · Available, untested · Verified working**.

## What the backend does

- **Shell**: a real PTY. Supports input/output, resizing, Ctrl-C to the foreground process group, and exit status. When stopped, the exit is confirmed.
- **Programs** (Unleashed Tools → Programs): lists executables in the detected program folders. Each one can be run with a 20-second limit or opened in a terminal session. Errors are reported as they really happened:
  - `EPERM`: sandbox;
  - `ENOENT`;
  - `ENOEXEC`;
  - SIGKILL at launch: usually code signing;
  - timeout.
- **Files**: browse, read and edit only in locations the scan could list. Writing needs the write switch and `access(W_OK)`. System and jailbreak locations ask before every change, and symlinks out of a permitted location are refused.
- **Processes**: the process table as far as the system shows it.
- **Packages**: the installed-package list (`dpkg-query`) comes first. Install, remove and refresh happen only after you approve the exact command, which then runs visibly in a new session. No `sudo` is added.

## Defaults and switches

Settings → Capabilities & Access (see `CAPABILITIES_AND_ACCESS.md`):

- Expanded filesystem access starts **read-only**.
- **Privileged operations start off.** While off, privileged commands HCG Terminal recognizes are refused without asking.
- Turning a switch off is enforced in the services themselves.
- A switch never changes iOS permissions, never removes the jailbreak and never undoes earlier changes.

## Device tests still needed

None of these has run on hardware yet:

- **Ordinary iPhone and iPad, Unleashed build installed from Xcode:**
  - Environment unknown / Permission denied;
  - Vanilla and remote development unaffected.
- **Jailbroken device, sandboxed install (route A):**
  - shell *Permission denied* with `EPERM`;
  - loopback service sign-in;
  - indicators shown as found or not observable, never as "can run".
- **Jailbroken device, `.deb` install (route B):**
  - shell test verified; PTY size, Ctrl-C and exit status;
  - programs including the SIGKILL code-signing case;
  - package list, then an approved install;
  - write test in a writable folder, with cleanup confirmed;
  - approval prompts for `/var/jb`;
  - switches turned off while a shell is open.
