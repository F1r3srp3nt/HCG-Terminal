# Freeze record: HCG Terminal Unleashed 0.2.0~rc2

**Frozen 2026-11-24.** Built once by a manual CI run on `main` with `release_version=0.2.0~rc2`. Never rebuilt: CI refuses a version that has this record. Any change becomes `0.2.0~rc3`.

| | |
|---|---|
| Package | `com.hakmicapitalgroup.hcgterminal.unleashed` |
| Version | `0.2.0~rc2` (app 0.2.0, build 2), `iphoneos-arm64`, rootless (`/var/jb`) |
| File | `com.hakmicapitalgroup.hcgterminal.unleashed_0.2.0~rc2_iphoneos-arm64.deb` |
| Size | 7,053,756 bytes |
| **SHA-256** | `597eb8f11519c9a91a0daa8c72eb9f70f5e38c4fc2e1ffaba469d8420606ff84` |
| Source | `main` @ `22912b4c7dc05de4256ffe12ab7070456de85622` |
| CI | Apple build run #77 (run ID `45365201577`, workflow_dispatch), all jobs green |
| CI artifact | `hcg-terminal-unleashed-rootless-release-candidate` (ID `14907036848`), zip SHA-256 `0d91d5a29f43d770dd8ede70ca3125033151f943b25f6189b911ad790eeb3983`, kept until 2026-12-24 |
| Entitlements | App: `com.apple.private.security.no-sandbox` only (same as rc1). `hcg-pty-helper` and `libswiftCompatibilitySpan.dylib`: none |
| Signatures | ldid; every page hash and the XML/DER entitlement slots verified (main executable 2366/2366 pages) |
| Install check | dpkg scratch root: install, reinstall, remove, purge; `uicache -p` / `uicache -u` with the bundle path |
| HCG Repo inspector | OK (HCG-repo `09df297`) |
| Published | **No.** HCG Repo publication needs the owner's approval of this exact SHA-256. |

## What changed since rc1
- Startup journal and Startup Recovery screen. Safe Mode skips environment detection and background jobs; the startup report can be shared. See docs/JAILBREAK_EDITION.md.
- Fixes: Agent Runtime status text; "at ." in Jailbreak Diagnostics.

## Files here
- `….deb.sha256`, `….deb.manifest.json`: from the CI run.
- `hcg-repo-proposal.patch`: the HCG Repo Candidate changes. Applies to HCG-repo `09df297`; not applied, not pushed.

The `.deb` is not committed to Git.
