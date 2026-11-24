# Freeze record: HCG Terminal Unleashed 0.2.0~rc1

**Frozen 2026-11-24 for private physical-device testing.** This candidate is not rebuilt. Any change to the app produces a new candidate (`0.2.0~rc2`) with a new checksum; it never replaces these bytes.

| | |
|---|---|
| Package | `com.hakmicapitalgroup.hcgterminal.unleashed` |
| Version | `0.2.0~rc1` (app 0.2.0, build 1), `iphoneos-arm64`, rootless (`/var/jb`) |
| File | `com.hakmicapitalgroup.hcgterminal.unleashed_0.2.0~rc1_iphoneos-arm64.deb` |
| Size | 7,020,986 bytes |
| **SHA-256** | `02626804763200f9e29d651a213bdb92330351d3052073e6a52cb86d62fc5a28` |
| Source commit | `1cc76a791cf785f80f4bd742224cd681c612d806` (branch `claude/unleashed-jailbreak-edition`, draft PR #3, not merged) |
| CI | Apple build run #72, run ID `45051075163`, all 5 jobs green, built 2026-11-22T17:56:58Z |
| CI artifact | `hcg-terminal-unleashed-rootless-rc` (ID `14765917921`), zip SHA-256 `1752cd64fdae41d89401db9002256f9de993b2c883b52f91a39646cbd1b1f118`, 3-day retention, expires 2026-11-25 |
| HCG Repo inspector | OK, 0 warnings (HCG-repo `bin/hcgrepo` pinned at `4aa36a0`) |
| Published | **No.** Nothing has been pushed to HCG Repo; not tagged; not merged. |

## What is in this folder

| File | Purpose |
|---|---|
| `FREEZE.md` | This record |
| `….deb.sha256` | Checksum file from the CI run (`sha256sum -c` format) |
| `….deb.manifest.json` | Build manifest from the CI run: control file, every file's path, mode, size and SHA-256 |
| `PRE-APPROVAL-REPORT.md` | Pre-approval report: entitlements, compatibility, procedures, CI-verified vs device-needed |
| `hcg-repo-proposal.patch` | Proposed HCG Repo changes for 0.2.0~rc1. **Not applied, not pushed.** Applied only after device testing and your approval |
| `hcg-repo-import-frozen-rc1.py` | After approval only: imports the frozen `.deb` from the owner's copy into HCG Repo's candidate channel, with HCG Repo's own checks and the SHA-256 pinned. It replaces the CI-artifact import request, which stops working when the artifact expires |

The `.deb` itself is not committed to Git. The owner holds the copy delivered from the CI artifact; check it against the checksum above before installing.

## Verify a copy

```sh
sha256sum -c com.hakmicapitalgroup.hcgterminal.unleashed_0.2.0~rc1_iphoneos-arm64.deb.sha256
# on the phone: shasum -a 256 <file>.deb
```

## Verify the source has not drifted

After `1cc76a7`, only documentation changed, plus the CI version label: CI now builds `0.2.0~dev.<run>`, so a rebuild can never carry the frozen version. The app and packaging sources are unchanged. This must print nothing:

```sh
git diff 1cc76a791cf785f80f4bd742224cd681c612d806 HEAD -- . ':!docs' ':!.github/workflows/apple-build.yml'
```

## Known issues carried by these frozen bytes (fixed in rc2, not here)

1. *HCG Ecosystem* screen: the Agent Runtime row says no interface exists in any HCG product. Correct status: Agent Runtime exists as a development project; its native release and HCG Terminal integration are not yet available. The documentation is already corrected.
2. Jailbreak Diagnostics: if the jailbreak root is empty, some lines read "at ." instead of naming a path. Cosmetic; it does not appear on a normal Dopamine rootless install.

## Next gate

1. The owner runs `docs/DEVICE_TEST_UNLEASHED_RC.md` on the iPhone 11 Pro Max test device.
2. With the results, the final merge and HCG Repo publication approval request is prepared.
3. Nothing is merged or published without explicit approval.
