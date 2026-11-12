#!/usr/bin/env bash
# Builds one HCG Terminal variant into its own output folder. macOS with Xcode only.
#
#   Scripts/package-ios.sh standard  [output-dir]   # → <out>/standard/…
#   Scripts/package-ios.sh unleashed [output-dir]   # → <out>/unleashed/…
#   Scripts/package-ios.sh <variant> [output-dir] --archive <existing.xcarchive>   # package without rebuilding
#
#   Unleashed only, for an already jailbroken device (opt-in, explicit):
#   Scripts/package-ios.sh unleashed dist --deb rootless|rootful --ldid-entitlements <file.plist>
#     → <out>/unleashed/com.hakmicapitalgroup.hcgterminal.unleashed_<version>-<build>_<arch>.deb
#     Signs ONLY the copy inside the package, with `ldid` (pseudo-signature, no certificate) and the
#     entitlements file YOU pass. The device's jailbreak decides whether such a signature is
#     accepted. The package is written to disk; nothing is installed or uploaded.
#
# Otherwise produces UNSIGNED artifacts only. Nothing is signed with your team, exported for
# distribution or uploaded anywhere. Signed builds for TestFlight/App Store are made by you in Xcode
# (Product → Archive → Distribute) or HCG Executable Maker.
set -euo pipefail
variant="${1:-}"; out="${2:-dist}"; existing=""; deb=""; entitlements=""
shift $(( $# >= 2 ? 2 : $# ))
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) existing="${2:?archive path}"; shift 2 ;;
    --deb) deb="${2:?rootless|rootful}"; shift 2 ;;
    --ldid-entitlements) entitlements="${2:?entitlements plist}"; shift 2 ;;
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
  [ -n "$entitlements" ] && [ -f "$entitlements" ] || { echo "error: --deb needs --ldid-entitlements <file.plist> (see HCGTerminal-Support/Unleashed-optional-entitlements.example.plist)" >&2; exit 2; }
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
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$staged_app/Info.plist")"
  echo "Signing the packaged copy with ldid and $entitlements (pseudo-signature)."
  ldid -S"$entitlements" "$staged_app/$executable"
  cat > "$stage/DEBIAN/control" <<CTL
Package: $bundle
Name: HCG Terminal Unleashed
Version: $version-$build
Architecture: $arch
Maintainer: Hakmi Capital Group
Author: Hakmi Capital Group
Section: Terminal_Support
Depends: firmware (>= 17.0)
Description: HCG Terminal Unleashed $version ($build), revision $rev. Uses only the access the device already grants; never elevates by itself.
CTL
  # Registers the app icon with the home screen after the package manager installs it. Visible in
  # the package manager's output; it changes nothing else.
  cat > "$stage/DEBIAN/postinst" <<POST
#!/bin/sh
if command -v uicache >/dev/null 2>&1; then uicache -p "$prefix/Applications/$(basename "$app")" || true; fi
exit 0
POST
  cat > "$stage/DEBIAN/postrm" <<POST
#!/bin/sh
if [ "\$1" = remove ] || [ "\$1" = purge ]; then command -v uicache >/dev/null 2>&1 && uicache -u "$prefix/Applications/$(basename "$app")" || true; fi
exit 0
POST
  chmod 0755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/postrm"
  debfile="$dest/${bundle}_${version}-${build}_${arch}.deb"
  rm -f "$debfile"
  if command -v dpkg-deb >/dev/null; then
    dpkg-deb --root-owner-group -Zgzip -b "$stage" "$debfile" >/dev/null
  else
    (cd "$stage/DEBIAN" && tar --uid 0 --gid 0 -czf "$work/control.tar.gz" .)
    (cd "$stage" && tar --uid 0 --gid 0 --exclude ./DEBIAN -czf "$work/data.tar.gz" .)
    printf '2.0\n' > "$work/debian-binary"
    (cd "$work" && ar -rc "$(cd "$(dirname "$debfile")" && pwd)/$(basename "$debfile")" debian-binary control.tar.gz data.tar.gz)
  fi
  echo "Package:  $debfile ($deb, $arch). Not installed; install it yourself with the device's package manager."
fi

echo "Variant:  $variant ($declared)"
echo "Bundle:   $bundle"
echo "Version:  $version ($build), revision $rev"
echo "Output:   $dest/"
ls -1 "$dest"
