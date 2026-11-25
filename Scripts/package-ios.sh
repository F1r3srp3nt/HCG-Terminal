#!/usr/bin/env bash
# Builds one HCG Terminal variant into its own output folder. macOS with Xcode only.
#
#   Scripts/package-ios.sh standard  [output-dir]   # → <out>/standard/…
#   Scripts/package-ios.sh unleashed [output-dir]   # → <out>/unleashed/…
#   Scripts/package-ios.sh <variant> [output-dir] --archive <existing.xcarchive>   # package without rebuilding
#
#   Unleashed only, for an already jailbroken device (opt-in, explicit):
#   Scripts/package-ios.sh unleashed dist --deb rootless|rootful --ldid-entitlements <file.plist> [--deb-version 0.2.0~rc1]
#     → <out>/unleashed/com.hakmicapitalgroup.hcgterminal.unleashed_<version>_<arch>.deb (+ .sha256, .manifest.json)
#     Bundles hcg-pty-helper (controlling terminal for the shell) and ldid-signs every Mach-O.
#     Signs ONLY the copy inside the package, with `ldid` (pseudo-signature, no certificate) and the
#     entitlements file YOU pass. The device's jailbreak decides whether such a signature is
#     accepted. The package is written to disk; nothing is installed or uploaded.
#
# Otherwise produces UNSIGNED artifacts only. Nothing is signed with your team, exported for
# distribution or uploaded anywhere. Signed builds for TestFlight/App Store are made by you in Xcode
# (Product → Archive → Distribute) or HCG Executable Maker.
set -euo pipefail
variant="${1:-}"; out="${2:-dist}"; existing=""; deb=""; entitlements=""; deb_version_override=""
shift $(( $# >= 2 ? 2 : $# ))
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) existing="${2:?archive path}"; shift 2 ;;
    --deb) deb="${2:?rootless|rootful}"; shift 2 ;;
    --ldid-entitlements) entitlements="${2:?entitlements plist}"; shift 2 ;;
    --deb-version) deb_version_override="${2:?debian version}"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
case "$variant" in
  standard) scheme=HCGTerminal ;;
  unleashed) scheme=HCGTerminalUnleashed ;;
  *) echo "usage: $0 standard|unleashed [output-dir] [--archive path]" >&2; exit 2 ;;
esac
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$out/$variant"
mkdir -p "$dest"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

if [ -n "$existing" ]; then
  archive="$existing"
else
  archive="$work/$scheme.xcarchive"
  xcodebuild -project "$root/HCGTerminal.xcodeproj" -scheme "$scheme" -configuration Release \
    -destination generic/platform=iOS -archivePath "$archive" -derivedDataPath "$work/DerivedData" \
    COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= archive
fi

app="$(ls -d "$archive"/Products/Applications/*.app | head -1)"
plist="$app/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || echo unknown; }
declared="$(read_key HCGBuildVariant)"; bundle="$(read_key CFBundleIdentifier)"
version="$(read_key CFBundleShortVersionString)"; build="$(read_key CFBundleVersion)"; rev="$(read_key HCGSourceRevision)"
if [ "$declared" != "$variant" ]; then
  echo "error: $app declares variant '$declared', expected '$variant'. Not packaging." >&2; exit 1
fi
case "$variant" in
  standard) [[ "$bundle" != *.unleashed ]] || { echo "error: standard build has an Unleashed bundle ID" >&2; exit 1; } ;;
  unleashed) [[ "$bundle" == *.unleashed ]] || { echo "error: Unleashed build lacks the .unleashed bundle ID" >&2; exit 1; } ;;
esac
# The code must match the declared variant (backend marker present / absent).
"$root/Scripts/verify-build-variant.sh" "$app" "$variant"

name="$scheme-$version-$build-$rev"
rm -rf "$dest/$name-unsigned.xcarchive"
cp -R "$archive" "$dest/$name-unsigned.xcarchive"

if [ "$variant" = unleashed ]; then
  mkdir -p "$work/ipa/Payload"
  cp -R "$app" "$work/ipa/Payload/"
  dest_abs="$(cd "$dest" && pwd)"
  rm -f "$dest_abs/$name-unsigned.ipa"
  (cd "$work/ipa" && /usr/bin/zip -qry "$dest_abs/$name-unsigned.ipa" Payload)
  cat > "$dest/README.txt" <<TXT
HCG Terminal Unleashed $version ($build), source revision $rev
Bundle ID: $bundle

This folder contains the SEPARATE Unleashed variant. It is not for the App Store or TestFlight.
The .ipa is UNSIGNED. Installing it is the device owner's decision and uses the method the
already-configured device provides; HCG Terminal does not sign, install or modify anything.
See docs/UNLEASHED.md for prerequisites and what works with and without the app sandbox.
TXT
fi

if [ -n "$deb" ]; then
  [ "$variant" = unleashed ] || { echo "error: --deb is only for the Unleashed variant" >&2; exit 2; }
  [ -n "$entitlements" ] && [ -f "$entitlements" ] || { echo "error: --deb needs --ldid-entitlements <file.plist> (HCG Repo builds use HCGTerminal-Support/Unleashed-jailbreak.entitlements)" >&2; exit 2; }
  command -v ldid >/dev/null || { echo "error: ldid not found (brew install ldid). Nothing was packaged." >&2; exit 2; }
  case "$deb" in
    rootless) prefix="/var/jb"; arch="iphoneos-arm64" ;;
    rootful) prefix=""; arch="iphoneos-arm" ;;
    *) echo "error: --deb rootless|rootful" >&2; exit 2 ;;
  esac
  stage="$work/deb"
  mkdir -p "$stage$prefix/Applications" "$stage/DEBIAN"
  cp -R "$app" "$stage$prefix/Applications/"
  staged_app="$stage$prefix/Applications/$(basename "$app")"
  installed_app="$prefix/Applications/$(basename "$app")"
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$staged_app/Info.plist")"
  min_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$staged_app/Info.plist" 2>/dev/null || echo 17.0)"

  # The controlling-terminal helper (Unleashed-Helper/hcg-pty-helper.c): only in the .deb, where
  # the app runs outside the sandbox and can start processes.
  xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min="$min_os" -O2 -Wall -Werror \
    -o "$staged_app/hcg-pty-helper" "$root/Unleashed-Helper/hcg-pty-helper.c"
  chmod 0755 "$staged_app/hcg-pty-helper"

  # Every Mach-O gets the same kind of signature (ldid pseudo-signature): embedded libraries and
  # the helper without entitlements, the app executable last with the reviewed entitlements.
  # Mixed Apple/ldid signatures inside one app are not reliably accepted by jailbreaks.
  echo "Signing every Mach-O in the packaged copy with ldid (pseudo-signature)."
  while IFS= read -r -d '' f; do
    [ "$f" = "$staged_app/$executable" ] && continue
    if file -b "$f" | grep -q "Mach-O"; then ldid -S "$f"; echo "  signed $(basename "$f")"; fi
  done < <(find "$staged_app" -type f -print0)
  ldid -S"$entitlements" "$staged_app/$executable"
  echo "  signed $executable with $(basename "$entitlements")"

  deb_version="${deb_version_override:-$version-$build}"
  cat > "$stage/DEBIAN/control" <<CTL
Package: $bundle
Name: HCG Terminal Unleashed
Version: $deb_version
Architecture: $arch
Maintainer: Hakmi Capital Group
Author: Hakmi Capital Group
Section: Terminal_Support
Depends: firmware (>= $min_os), uikittools
Description: Jailbreak edition of HCG Terminal: a local shell in a pseudo-terminal with job control, using only the access the device already grants. Never elevates by itself. App $version ($build), revision $rev.
CTL
  # Registers / unregisters the home-screen icon. Visible in the package manager's output; they
  # change nothing else (HCG Repo convention: configure only; remove/purge only).
  cat > "$stage/DEBIAN/postinst" <<POST
#!/bin/sh
if [ "\$1" = "configure" ]; then
  uicache -p "$installed_app" || echo "HCG Terminal Unleashed: uicache failed; run 'uicache -a' to show the icon." >&2
fi
exit 0
POST
  cat > "$stage/DEBIAN/postrm" <<POST
#!/bin/sh
if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
  uicache -u "$installed_app" 2>/dev/null || true
fi
exit 0
POST
  chmod 0755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/postrm"
  debfile="$dest/${bundle}_${deb_version}_${arch}.deb"
  rm -f "$debfile"
  if command -v dpkg-deb >/dev/null; then
    # gzip, not lzma/xz: large lzma dictionaries fail to unpack on some devices.
    dpkg-deb --root-owner-group -Zgzip -b "$stage" "$debfile" >/dev/null
  else
    (cd "$stage/DEBIAN" && tar --uid 0 --gid 0 -czf "$work/control.tar.gz" .)
    (cd "$stage" && tar --uid 0 --gid 0 --exclude ./DEBIAN -czf "$work/data.tar.gz" .)
    printf '2.0\n' > "$work/debian-binary"
    (cd "$work" && ar -rc "$(cd "$(dirname "$debfile")" && pwd)/$(basename "$debfile")" debian-binary control.tar.gz data.tar.gz)
  fi

  # Checksum and build manifest next to the package.
  sha="$(shasum -a 256 "$debfile" | cut -d' ' -f1)"
  printf '%s  %s\n' "$sha" "$(basename "$debfile")" > "$debfile.sha256"
  python3 - "$debfile" "$stage" "$prefix" "$sha" "$bundle" "$deb_version" "$arch" "$version" "$build" "$rev" "$min_os" "$entitlements" <<'PY'
import hashlib, json, os, subprocess, sys, datetime
deb, stage, prefix, sha, bundle, debver, arch, version, build, rev, min_os, ents = sys.argv[1:]
files = []
for dirpath, _, names in os.walk(stage):
    for n in sorted(names):
        full = os.path.join(dirpath, n)
        rel = os.path.relpath(full, stage)
        if rel.startswith("DEBIAN"):
            continue
        entry = {"path": rel, "size": os.path.getsize(full), "mode": oct(os.stat(full).st_mode & 0o7777),
                 "sha256": hashlib.sha256(open(full, "rb").read()).hexdigest()}
        if b"Mach-O" in subprocess.run(["file", "-b", full], capture_output=True).stdout:
            out = subprocess.run(["ldid", "-e", full], capture_output=True).stdout.decode(errors="replace").strip()
            entry["macho"] = True
            entry["entitlements_plist"] = out
        files.append(entry)
manifest = {
    "format": "hcg.terminal.deb-manifest", "formatVersion": 1,
    "package": bundle, "version": debver, "architecture": arch, "layout": "rootless" if prefix else "rootful",
    "file": os.path.basename(deb), "size": os.path.getsize(deb), "sha256": sha,
    "app": {"version": version, "build": build, "sourceRevision": rev, "minimumOS": min_os},
    "signing": {"tool": "ldid", "mainExecutableEntitlements": os.path.basename(ents)},
    "control": open(os.path.join(stage, "DEBIAN", "control")).read(),
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "installed": False, "published": False,
    "files": files,
}
json.dump(manifest, open(deb + ".manifest.json", "w"), indent=2)
PY
  echo "Package:  $debfile ($deb, $arch), sha256 $sha"
  echo "          Not installed and not published; install it yourself with the device's package manager."
fi

echo "Variant:  $variant ($declared)"
echo "Bundle:   $bundle"
echo "Version:  $version ($build), revision $rev"
echo "Output:   $dest/"
ls -1 "$dest"
