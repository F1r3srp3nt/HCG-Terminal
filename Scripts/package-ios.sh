#!/usr/bin/env bash
# Builds one HCG Terminal variant into its own output folder. macOS with Xcode only.
#
#   Scripts/package-ios.sh standard  [output-dir]   # → <out>/standard/…
#   Scripts/package-ios.sh unleashed [output-dir]   # → <out>/unleashed/…
#   Scripts/package-ios.sh <variant> [output-dir] --archive <existing.xcarchive>   # package without rebuilding
#
# Produces UNSIGNED artifacts only. Nothing is signed with your team, exported for distribution
# or uploaded anywhere. Signed builds for TestFlight/App Store are made by you in Xcode
# (Product → Archive → Distribute) or HCG Executable Maker, from the HCGTerminal scheme only.
set -euo pipefail
variant="${1:-}"; out="${2:-dist}"; existing=""
if [ "${3:-}" = "--archive" ]; then existing="${4:?archive path}"; fi
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

echo "Variant:  $variant ($declared)"
echo "Bundle:   $bundle"
echo "Version:  $version ($build), revision $rev"
echo "Output:   $dest/"
ls -1 "$dest"
