# HCG Terminal Unleashed: Jailbreak Edition and HCG Repo release candidate

**Status: release candidate, NOT device-tested, NOT published.** The package is built and checked in CI. It has not yet been installed on a jailbroken device, so this edition is not complete (see [Validation](#validation)).

## Two editions

| | HCG Terminal (Standard) | HCG Terminal Unleashed (Jailbreak Edition) |
|---|---|---|
| Scheme / bundle ID | `HCGTerminal` / `com.hakmicapitalgroup.hcgterminal` | `HCGTerminalUnleashed` / `com.hakmicapitalgroup.hcgterminal.unleashed` |
| Distribution | App Store / TestFlight (you upload) | HCG Repo (`.deb`, rootless) for Sileo and Zebra |
| Sandbox | Always sandboxed | Outside the sandbox (`com.apple.private.security.no-sandbox`, `.deb` only) |
| Local terminal | Built-in commands on the app's own files | The device's own shell in a pseudo-terminal, with job control |
| Unleashed backend | Not linked (checked by `Scripts/verify-build-variant.sh`) | Linked |
| Jailbreak entitlements | None, ever | Only in the `.deb`, signed with `ldid` by `Scripts/package-ios.sh` |
| URL scheme (navigation only) | `hcgterminal://open/<screen>` | `hcgterminal-unleashed://open/<screen>` |

Nothing in this milestone changes the Standard edition's entitlements, sandbox or capabilities. The PTY helper, the entitlements file and the jailbreak diagnostics backend are packaged only into the Unleashed `.deb`.

## What the jailbreak edition does

**Local terminal**
- **The shell:** the device's real installed shell (`zsh`, `bash` or `sh` from the bootstrap) runs in a pseudo-terminal as the app's user (`mobile`). The terminal shows real output, never simulated results.
- **Job control:** `hcg-pty-helper` (source in `Unleashed-Helper/hcg-pty-helper.c`) makes the terminal the session's controlling terminal, which `posix_spawn` cannot do on iOS. With it:
  - Ctrl-C, Ctrl-Z and Ctrl-\ reach the foreground program;
  - window-size changes reach full-screen programs (`vim`, `top`, `less`);
  - `/dev/tty` works.

  Without the helper, the shell still runs, but without job control.
- **Inherited behaviour:** working directory, environment variables, ANSI rendering, keyboard shortcuts and the key row, session history, interrupt, terminate (SIGHUP, then SIGKILL), and the command guard (typed `sudo`/`rm -rf`/`reboot` lines are confirmed first).
- **Privileges:** privileged commands are never run automatically. `sudo` is only ever typed by you, and asks for its own password.

**Unleashed Tools** (all read-only unless marked)
- **Programs:** installed tools; running one asks for approval.
- **Processes:** the process list.
- **Environment and Tests:** layered capability checks, and an explicit shell test.
- **Jailbreak Diagnostics** (new):
  - install location, and the entitlements this copy is signed with (read from its own code signature);
  - whether the PTY helper is present;
  - the rootless bootstrap (`/var/jb` and its target, Procursus/Dopamine markers, shell, dpkg, apt, uicache, sudo);
  - package-database health (interrupted or broken installs, lock files);
  - repositories (APT sources, `http://` sources, whether HCG Repo is added, how fresh the lists are);
  - tweak injection and Safe Mode clues (injection libraries in this process, recently installed tweaks, SpringBoard crash reports from the last 7 days, with recovery steps);
  - storage (free space per volume);
  - a "Share Report" export.
- **Packages:** the inventory, read from the dpkg status file.
  - *Install*, *remove* and *refresh*, and now *install a downloaded `.deb`*, each show the exact command and need your approval. They then run visibly in a Local Unleashed session.
  - Nothing respring-related is ever run.
- **Permitted locations and logs:** browse, read log tails, and edit text files where writable (system and jailbreak locations ask each time).

## Supported devices and jailbreaks

| Device (owner) | iOS | Jailbreak | Package manager | Can install? | Tested |
|---|---|---|---|---|---|
| iPhone 11 Pro Max | 17.4 | Dopamine 2.x, rootless | Zebra 1.1.x | Yes (`firmware (>= 17.0)`) | **No: needed before release** |
| iPhone 13 Pro (iPhone14,2) | 16.5 | Dopamine, rootless, ElleKit | Zebra / Sileo | **No**: the app needs iOS 17 (SwiftUI/Observation) | n/a |
| Any arm64 / arm64e device | 17.0 – 17.x | Dopamine 2.x or palera1n rootless (Procursus) | Sileo, Zebra | Expected | No |
| Any | any | rootful (palera1n `-f`) | | `iphoneos-arm` package builds in CI, but is not offered in HCG Repo | No |
| Any | any | roothide (`iphoneos-arm64e`) | | Not supported | n/a |

## Installation (once published; today only for a test device)

**Before testing:** use a test device, and back up its configuration:
- run `dpkg --get-selections > ~/dpkg-selections.txt` (or use the jailbreak's backup tool);
- export Sileo or Zebra's source list.

1. **Remove any sideloaded copy** of *HCG Terminal Unleashed* (Xcode, IPA, TrollStore). It uses the same bundle ID.
2. **Add HCG Repo** in Sileo or Zebra: `https://repo.hakmicapitalgroup.com/repo/`. The Terminal package needs an HCG Connect sign-in to download.
   For a pre-release test, copy the candidate `.deb` to the device and install it with Filza or `sudo dpkg -i <file>` instead.
3. **Install HCG Terminal Unleashed.** The package's `postinst` runs `uicache -p /var/jb/Applications/HCGTerminalUnleashed.app`; the package manager shows this.
4. **Open the app:**
   - Unleashed Tools → **Jailbreak Diagnostics**: *Install location* and *Signature* should be OK.
   - **Environment and Tests → Run Shell Test**: *Verified working*.
   - Open a Local Unleashed session, then:
     - run `vi` or `top` and resize by rotating the device;
     - press Ctrl-C during `sleep 30`;
     - run a job with `&`, then use `jobs` and `fg`.
5. **Upgrade:** install a newer version over it. dpkg replaces the app, and `postinst` refreshes the icon. App data in the app's data folder is kept.
6. **Remove:** in Sileo or Zebra, remove the package. `postrm` unregisters the icon. Nothing outside `/var/jb/Applications/HCGTerminalUnleashed.app` is installed, so nothing else needs cleaning.

**Recovery if anything goes wrong**
- The package installs no tweak, so it cannot inject into SpringBoard or cause Safe Mode by itself.
- If the app fails to start, remove it in Sileo or Zebra, or over SSH: `sudo dpkg -r com.hakmicapitalgroup.hcgterminal.unleashed`.
- If the icon is missing, run `uicache -a`.

## The package

Built by `Scripts/package-ios.sh unleashed <out> --deb rootless --ldid-entitlements HCGTerminal-Support/Unleashed-jailbreak.entitlements --deb-version 0.2.0~rc1`. CI builds it on every push; see the *iOS · HCGTerminalUnleashed* job.

| Item | Value |
|---|---|
| Package | `com.hakmicapitalgroup.hcgterminal.unleashed` |
| Version | `0.2.0~rc1`. Sorts above the locked `0.1.0-1` and below a final `0.2.0`. |
| Architecture | `iphoneos-arm64` (rootless) |
| Depends | `firmware (>= 17.0), uikittools` |
| Contents | Only `/var/jb/Applications/HCGTerminalUnleashed.app/…`, including `hcg-pty-helper` (arm64). No setuid, nothing world-writable, no files outside the app. |
| Signing | Every Mach-O is signed with `ldid`: libraries and the helper with no entitlements, the app executable with exactly `com.apple.private.security.no-sandbox`. No Apple signatures remain mixed in. |
| Maintainer scripts | `postinst` (configure only: `uicache -p`), `postrm` (remove/purge only: `uicache -u`). No other changes. |
| Compression | gzip (not lzma: large lzma dictionaries failed to unpack on a device for another HCG package). |
| Next to it | `<deb>.sha256` and `<deb>.manifest.json`: version, SHA-256, size, source revision, control file, every file's mode and SHA-256, and each Mach-O's entitlements. |
| Checked by | CI step *HCG Repo inspection of the rootless candidate*: HCG Repo's own `bin/hcgrepo inspect` at a pinned commit, read-only. It checks layout, signatures, reviewed entitlements, dependencies and scripts. |

The CI artifact `hcg-terminal-unleashed-rootless-rc` holds the `.deb`, `.sha256` and manifest. It is kept for 3 days. GitHub artifacts on a public repository can be downloaded by signed-in GitHub users, so do not treat it as private.

## Validation

| # | Check | Result |
|---|---|---|
| 1 | Standard and Unleashed UI regression tests | Package tests (Linux, macOS, iOS Simulator) and Simulator screenshots of both editions in CI, including large text, Increase Contrast, Classic/Enhanced/Reduced, iPad and small iPhone. |
| 2 | Native iOS build | Release and Debug `iphoneos` builds and unsigned archives of both schemes in CI. |
| 3 | Rootless package structure | CI: `dpkg-deb -I/-c`, extraction, variant check, HCG Repo inspector. |
| 4 | Executable signing | CI: every Mach-O ad hoc / ldid-signed (`codesign -dv`), app entitlements printed (`ldid -e`), helper is arm64. |
| 5 | Local shell and PTY | Linux CI and here: real shells in PTYs (`ExecutionProviderTests`, `PTYHelperTests`). Compared with and without the helper: controlling terminal, Ctrl-C, window-size signal, working directory. |
| 6 | Interactive terminal | Same PTY tests (interrupt, resize, programs that read the terminal). **On a device: not done.** |
| 7 | Install on a jailbroken device | **Not done.** Needs the iPhone 11 Pro Max (iOS 17.4, Dopamine 2.x). |
| 8 | Upgrade and uninstall | **Not done on a device.** Package scripts reviewed; they only run uicache. |
| 9 | Safe Mode and recovery | **Not done on a device.** The package contains no tweak; recovery steps above. |
| 10 | Security and permission review | Done in code review (below). Device confirmation pending. |

**Security review**
- **Standard edition:** unchanged. It has no entitlements, no helper, no backend and no URL actions, only navigation.
- **Entitlements:** only no-sandbox, matching HCG Repo's recorded review. Not platform-application, not task-for-pid, not root.
- **No privilege changes:**
  - the helper does not change user IDs or signals, and runs only the program it was given;
  - shell sessions run as `mobile`;
  - `sudo` only runs when you type it.
- **Changes need approval:**
  - package installs and removals show the command and run visibly after approval;
  - diagnostics only read;
  - nothing edits APT sources, the dpkg database, sudoers or bootstrap files.
- **Deep links:** they only navigate. A link cannot start a session, run a command or pass text in.
- **Offline:** the local terminal needs no account or network. No licence is checked at runtime.

## HCG integration (what is real today)

The app shows this in Diagnostics → *HCG Ecosystem*.

| Product | Today |
|---|---|
| HCG Repo | Distribution channel for this package (access level `connect`). HCG Repo product page linked in Settings. |
| HCG Nexus | Nexus opens Terminal by bundle ID. **New:** `hcgterminal-unleashed://open/<dashboard\|tools\|diagnostics\|console\|hosts\|builds\|files\|settings\|capabilities\|artifacts\|about>`. This is the URL route Nexus's TODO #6 is waiting for. |
| HCG Sentinel | Terminal can open `hcgsentinel://open/securityLab`. No data is exchanged. |
| HCG Connect | **Not available.** No sign-in client has been issued for HCG Terminal. When one is, Terminal will use HCG's central sign-in (system browser, PKCE, refresh token in the Keychain), not its own accounts. The `hcg--connect` repository is currently a placeholder. |
| HCG Store licensing | **Not available.** The Store is not live. Access is enforced at download time by HCG Repo, not in the app. |
| HCG Server | **Not available** for phones: companion pairing is designed, not built, and there is no command API. |
| HCG Agent Runtime | **Does not exist yet** in any HCG product. |

## HCG Repo publication readiness

**Not ready to publish. Blocked by:**
1. **No device test.** HCG Repo's rules mark every version *experimental* until a `device_tests` record exists.
2. **The candidate channel refuses `connect` packages.** That's the `candidate-protected` rule. A candidate needs your exception in `packages/com.hakmicapitalgroup.hcgterminal.unleashed/package.toml [access]` (`exception`, `exception_versions = ["0.2.0~rc1"]`). Only you can approve that.
3. **Access delivery is not live yet.** HCG Connect sign-in and the Sileo payment endpoint are not live, so `connect` packages cannot be delivered to users yet.

**Ready once the above is resolved.** These changes in HCG-repo would be needed; I did **not** make them:
- **`CHANGELOG.md`:** add `## 0.2.0~rc1` with:
  - PTY helper for job control;
  - every Mach-O signed with ldid;
  - `uikittools` declared;
  - jailbreak diagnostics;
  - Nexus/Sentinel URL routes.
- **`package.toml [display] limitations`:**
  - remove the `uikittools` and mixed-signature notes, which this candidate fixes;
  - mention `hcg-pty-helper`.
- **`package.toml [review.entitlements]`:** unchanged. The helper and libraries carry no entitlements, so they need no review entry.
- **An import request** `imports/hcg-terminal-unleashed-0.2.0-rc1-rootless.toml`:
  - `kind = "github-artifact"`, repository `F1r3srp3nt/HCG-Terminal`;
  - the CI run ID and commit;
  - artifact `hcg-terminal-unleashed-rootless-rc`;
  - the `.deb`'s SHA-256;
  - `channel = "candidate"`.
- **Do not reuse `0.1.0-1`.** It is locked.

Pushing a `.deb` or an import request to any branch of the public HCG-repo repository already makes the file downloadable there. So nothing has been pushed to HCG-repo. Wait for your approval and the device test.
