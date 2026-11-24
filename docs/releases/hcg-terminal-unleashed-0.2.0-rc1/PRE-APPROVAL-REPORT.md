# HCG Terminal Unleashed 0.2.0~rc1: pre-approval report

**Status: FROZEN release candidate for PRIVATE device testing only** (frozen 2026-11-24: CI run 72, commit `1cc76a7`, SHA-256 `02626804…fc5a28`; no rebuild). Nothing has been merged, tagged or published. Nothing has been pushed to HCG Repo. Public distribution waits for your explicit approval, after a passing device test.

| | |
|---|---|
| Source | `F1r3srp3nt/HCG-Terminal`, branch `claude/unleashed-jailbreak-edition`, commit `1cc76a791cf785f80f4bd742224cd681c612d806`. Draft PR #3, not merged. |
| CI | Run 72, `45051075163`: **all 5 jobs passed**. macOS package tests; Linux OpenSSH tests; iOS HCGTerminal; iOS HCGTerminalUnleashed (including the `.deb`, signature checks and HCG Repo inspector); iOS Simulator smoke, screenshots and package tests. |
| Artifact | `hcg-terminal-unleashed-rootless-rc` (ID 14765917921), kept until 2026-11-25. GitHub zip SHA-256 `1752cd64fdae41d89401db9002256f9de993b2c883b52f91a39646cbd1b1f118`. |

## 1. Package and SHA-256

| | |
|---|---|
| File | `com.hakmicapitalgroup.hcgterminal.unleashed_0.2.0~rc1_iphoneos-arm64.deb` |
| Size | 7,020,986 bytes |
| **SHA-256** | **`02626804763200f9e29d651a213bdb92330351d3052073e6a52cb86d62fc5a28`** |
| Checked | Computed by the build script, by HCG Repo's inspector in CI, and again after downloading (`sha256sum -c`: OK). |
| Control | Package `com.hakmicapitalgroup.hcgterminal.unleashed`, Version `0.2.0~rc1`, Architecture `iphoneos-arm64`, Section `Terminal_Support`, Depends `firmware (>= 17.0), uikittools`. |
| Contents | Only `/var/jb/Applications/HCGTerminalUnleashed.app/…`: the app, `hcg-pty-helper`, `Frameworks/libswiftCompatibilitySpan.dylib`, icons, `Assets.car`, and the swift-crypto and swift-nio resource bundles. All owned by root:root; executables 0755, other files 0644. No setuid; nothing world-writable. |
| Scripts | `postinst` (configure only): `uicache -p /var/jb/Applications/HCGTerminalUnleashed.app`. `postrm` (remove/purge only): `uicache -u …`. Nothing else. |
| Compression | gzip |
| Versioning | App reports 0.2.0 (1). It sorts above the locked `0.1.0-1` and below a final `0.2.0`. |

**Any new commit rebuilds the package with a different SHA-256.** Test exactly this file.

## 2. Entitlement inventory (read from the built package)

| Mach-O | Architectures | Signature | Entitlements |
|---|---|---|---|
| `HCGTerminalUnleashed` (app) | arm64 | ldid (CodeDirectory, no certificate) | `com.apple.private.security.no-sandbox = true` (only) |
| `hcg-pty-helper` | arm64 | ldid | none |
| `Frameworks/libswiftCompatibilitySpan.dylib` | arm64, arm64e | ldid (re-signed; the Apple signature is gone) | none |

- **Not present:** `platform-application`, `task_for_pid-allow`, `get-task-allow`, `com.apple.private.persona-mgmt`, container overrides, root or any other private entitlement.
- **HCG Repo review:** matches HCG Repo's recorded review exactly (`entitlements-mismatch` / `entitlements-unreviewed`: none).
- **Standard edition** (`com.hakmicapitalgroup.hcgterminal`):
  - its entitlements files and sandbox are unchanged from `main` (empty diff);
  - it contains no helper and no Unleashed backend;
  - its only addition is the navigation URL scheme `hcgterminal://open/<screen>`.

## 3. Compatibility matrix

| Device | iOS | Jailbreak / bootstrap | Package manager | Installable | Device-tested |
|---|---|---|---|---|---|
| **iPhone 11 Pro Max (test device)** | 17.4 | Dopamine 2.x, rootless, Procursus | Zebra 1.1.x (Sileo if present) | Yes | **No: release gate** |
| iPhone 13 Pro (iPhone14,2) | 16.5 | Dopamine, rootless, ElleKit | Zebra / Sileo | **No**: needs iOS 17 (`firmware (>= 17.0)`) | n/a |
| Other arm64/arm64e iPhones and iPads | 17.0 – 17.x | Dopamine 2.x or palera1n rootless (Procursus) | Sileo, Zebra | Expected | No |
| Any | iOS 18+ | No supported public rootless jailbreak known to HCG | | Untested | No |
| Any | any | rootful (palera1n `-f`) | | An `iphoneos-arm` build exists in CI, but is **not proposed for HCG Repo** | No |
| Any | any | roothide (`iphoneos-arm64e`) | | **Not supported** | n/a |
| TrollStore / sideloaded IPA | any | | | Different install route; same bundle ID, so remove it first | n/a |

## 4. Installation, upgrade, uninstall and recovery (test device only)

**Before installing**
- Use the test device only.
- Back up the package selections: `dpkg --get-selections > /var/mobile/dpkg-selections-before.txt`.
- Export Zebra's sources, and note free space and whether Tweak Injection is on.
- Remove any sideloaded or TrollStore *HCG Terminal Unleashed* (same bundle ID). The App Store *HCG Terminal* can stay.

**Install (private, not through HCG Repo)**
1. Copy the `.deb` to the phone (AirDrop to Filza, or `scp`).
2. Run `shasum -a 256 <file>`. It must be `02626804…fc5a28`.
3. Install it: Filza → Install, or `sudo dpkg -i <file>`. If `uikittools` is missing, `sudo apt install uikittools` first (your choice).
4. Check `dpkg -s com.hakmicapitalgroup.hcgterminal.unleashed`. It should show `install ok installed`, `0.2.0~rc1`, and the icon should appear.

**Upgrade**
- Install a later candidate over it with `dpkg -i`.
- dpkg replaces the app bundle, and `postinst` refreshes the icon. The app's data folder is kept.
- Reinstalling the same version is also accepted.

**Uninstall**
- Remove it in Zebra or Sileo, or with `sudo dpkg -r com.hakmicapitalgroup.hcgterminal.unleashed`.
- `postrm` unregisters the icon. Nothing outside the app bundle was installed, so nothing else needs removing.
- Compare `dpkg --get-selections` with the backup.

**Recovery**
- The package contains **no tweak and no injected code**, so it cannot put SpringBoard into Safe Mode by itself.
- If the app crashes at launch, remove it (Zebra, Sileo or `dpkg -r`). If the icon is stale, run `uicache -a`.
- If SpringBoard enters Safe Mode during the test, it is caused by something else. In that case:
  - remove the most recently installed tweak in Zebra or Sileo (they work in Safe Mode);
  - or turn off Tweak Injection in Dopamine and re-jailbreak.
- Jailbreak Diagnostics → *Tweak injection and Safe Mode* lists recent tweaks and SpringBoard crash reports.

## 5. Real-device checklist for the iPhone 11 Pro Max

The full step list (35 steps, record Pass / Fail / Not run for each) is in `docs/DEVICE_TEST_UNLEASHED_RC.md` in commit `1cc76a7`. Summary:

| Section | Steps |
|---|---|
| A. Before installing | 1–5: baseline, backup, remove the sideloaded copy, note Tweak Injection |
| B. Install | 6–10: copy the file, check the SHA-256, install, `dpkg -s`, helper permissions |
| C. First launch | 11–15: launch; Jailbreak Diagnostics (location, signature, helper, outside the sandbox, `/var/jb` target, markers, tools); share the report; Run Shell Test → *Verified working* |
| D. Local terminal | 16–24: `id` is not root; Ctrl-C during `sleep`; `jobs`/`fg`/Ctrl-Z/`bg`; `vi`, `top`, `less`; resize by rotating; ANSI; history; background for 1 minute; `sudo` confirmation and its own password |
| E. Packages | 25–26: inventory count matches `dpkg -l`; optional approved install and remove of `nano` |
| F. Upgrade | 27–28: reinstall the same version; later candidate over it; data kept |
| G. Uninstall | 29–32: icon gone, nothing left, App Store *HCG Terminal* unaffected, selections diff clean |
| H. Safe Mode and recovery | 33–35: reboot and re-jailbreak; no new SpringBoard crashes; works with Tweak Injection off |

**What decides each question**
- **The release gate:** steps 11, 12 and 15 must pass. If the shell test says *Permission denied*, this entitlement set is not enough for Dopamine. That is reported; nothing is changed silently.
- **Whether iPhone behaves like macOS for job control:** steps 17, 18 and 20.

## 6. HCG Repo changes needed (prepared, NOT applied)

A patch, `hcg-repo-proposal-hcg-terminal-unleashed-0.2.0-rc1.patch`, is attached. It is based on HCG-repo `main` at `4aa36a0`.
- In a local copy with it applied, `bin/hcgrepo validate` passes and all 161 HCG Repo tests pass.
- Nothing in it starts *Prepare packages*: it no longer contains an `imports/*.toml` request.

It changes:
1. **`packages/com.hakmicapitalgroup.hcgterminal.unleashed/CHANGELOG.md`:** a new `## 0.2.0~rc1` section that names the frozen SHA-256.
2. **`packages/com.hakmicapitalgroup.hcgterminal.unleashed/package.toml`:**
   - `limitations`: drops the `uikittools` and mixed-signature notes (both fixed); adds that shell sessions run as `mobile`.
   - `install`: adds the Jailbreak Diagnostics step.
   - `[access]`: `exception` and `exception_versions = ["0.2.0~rc1"]` are present **only as comments**. The candidate channel refuses `connect` packages without your exception, and only you can approve it.
   - `[review.entitlements]`: unchanged. The new helper and the library have no entitlements.

**How the frozen bytes get into HCG Repo (after approval only).** The CI artifact expires on 2026-11-25. An `imports/*.toml` request pointing at it would then fail, and a rebuild would give new bytes. So the earlier artifact request was dropped from the patch. Instead, after approval the frozen `.deb` is imported from your copy with `hcg-repo-import-frozen-rc1.py`. Run it from the HCG-repo checkout with the patch applied and the exception filled in:
- it uses HCG Repo's own `import_deb` checks, the same as `import-request`;
- it requires package, version, architecture and SHA-256 `02626804…fc5a28` to match;
- it places the package in the **candidate** channel;
- it records provenance as commit `1cc76a7`, run 45051075163;
- it writes `pool/…deb`, `…provenance.json` and a `repo-lock.json` entry, all for a pull request.

Tested on a throwaway copy: imported, same SHA-256 and size, channel `candidate`, `validate` OK. The copy was deleted. Publishing itself remains the manual *Publish repository* workflow on `main`.

**Not changed:**
- the locked `0.1.0-1` entry;
- any other package;
- signing settings, the payment endpoint, Publish.

After a passing device test, the patch also needs `[versions."0.2.0~rc1"]` with `status = "device-tested"` and a `device_tests` record.

## 7. Integration limitations

| Product | Today |
|---|---|
| HCG Connect | **Not available.** No sign-in client has been issued for HCG Terminal, and the `hcg--connect` repository is a placeholder. No accounts are created by HCG Terminal; when a client is issued, sign-in will use HCG's central issuer (system browser, PKCE). |
| HCG Store licensing | **Not available.** The Store and its licensing are not live. No licence is checked in the app; access is enforced at download by HCG Repo (`connect` level), which is not live for protected packages yet. |
| HCG Server | **Not available.** Phone companion pairing is designed, not built, and there is no command or build API. |
| HCG Agent Runtime | **Development project; not available to HCG Terminal yet.** Agent Runtime exists as an HCG development project, but it has no native release and no HCG Terminal integration yet, so nothing is connected. The in-app *HCG Ecosystem* text in this frozen candidate still says no Agent Runtime interface exists; that wording is corrected in the next candidate (rc2), not in these frozen bytes. |
| HCG Nexus | Opens Terminal by bundle ID (existing). **New:** navigation-only `hcgterminal-unleashed://open/<screen>`. Nexus itself still needs a change to use it (its TODO #6). |
| HCG Sentinel | Terminal can open `hcgsentinel://open/securityLab`. No data exchange in either direction. |
| HCG Repo | Distribution channel. The candidate is blocked on your access exception. Publication waits for your approval. |
| Offline | The local terminal and all diagnostics work without network or account. |

## 8. CI-verified vs. needs the physical device

| Verified in CI (run 72 and earlier runs on this branch) | Needs the iPhone 11 Pro Max |
|---|---|
| Both iOS apps build (Release, Debug, unsigned archives); variant checks keep Standard without the backend | The app launches from `/var/jb/Applications` with an ldid signature under Dopamine 2.x |
| Rootless `.deb`: layout, control, scripts, permissions; every Mach-O ldid-signed with no certificate; exact entitlements; helper is arm64 | Dopamine accepts the signature and the no-sandbox entitlement is enough to spawn the shell (Run Shell Test) |
| HCG Repo inspector (pinned `4aa36a0`): passes, 0 warnings | Install, upgrade and uninstall through dpkg / Zebra / Sileo, and `uicache` registering and unregistering the icon |
| PTY with the helper (Linux and macOS): controlling terminal, Ctrl-C, window-size signal, working directory. Without the helper (Linux): no controlling terminal | Job control, interrupt and resize on iOS itself (`vi`, `top`, `less`, Ctrl-C/Z, `fg`/`bg`) |
| Real shells in PTYs, the command guard, programs and processes (Linux / macOS package tests) | Behaviour in the background, and after reboot and re-jailbreak |
| Jailbreak Diagnostics on fake rootless device trees: correct findings, writes nothing; Mach-O signature parser | Diagnostics against the real Dopamine bootstrap, dpkg database, sources, crash logs |
| Deep links accept navigation only; the ecosystem screen claims nothing unbuilt | No Safe Mode or SpringBoard crash caused by the package; recovery steps |
| Doctor, Build & Install and the Log Console, including real OpenSSH tests (Linux) | `sudo` and the command guard with the device's real `sudo` |
| Standard edition: entitlements and sandbox unchanged; UI screenshots of both editions (Simulator), including large text | Approved package actions running in a visible local session on the device |

**Known issue in this candidate (cosmetic, fixed in the next candidate):**
- **Symptom:** when the jailbreak root is rootful or empty, Jailbreak Diagnostics shows "at ." instead of "/".
- **Where it shows:** seen in the Simulator (which has no jailbreak).
- **Your device:** not reachable on a rootless Dopamine device, where the root is `/var/jb` or a relocated path.
- **Why not fixed now:** fixing it rebuilds the package, which would change the SHA-256 you are testing.

**Release approval is not requested yet.** First run the device checklist on this exact file. Then send me the results and the Jailbreak Diagnostics report. After that, decide on the HCG Repo access exception and publication.
