#!/bin/sh
# Fails when an app bundle's code does not match the variant it declares.
#
#   Xcode build phase (both targets):  Scripts/verify-build-variant.sh
#   Command line / CI / packaging:      Scripts/verify-build-variant.sh <App.app> [standard|unleashed]
#
# Evidence used (a display name or bundle identifier alone proves nothing):
#   - HCGBuildVariant in the bundle's Info.plist;
#   - the Unleashed backend marker string (UnleashedBackend.marker), which the backend references at
#     runtime and which therefore only exists in a binary that links the backend. The main executable
#     and Xcode's debug dylib (<name>.debug.dylib, Debug builds) are searched.
# An Unleashed bundle without the marker, or a standard bundle with it, is an error.
set -u
marker="HCG-UNLEASHED-BACKEND-LINKED-v1"
if [ $# -ge 1 ]; then
  app="$1"; expected="${2:-}"
else
  app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"; expected="${HCG_BUILD_VARIANT:-}"
fi
plist="$app/Info.plist"
read_key() {
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null
  else
    python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get(sys.argv[2],""))' "$plist" "$1" 2>/dev/null
  fi
}
[ -f "$plist" ] || { echo "error: verify-build-variant: $plist not found"; exit 1; }
declared="$(read_key HCGBuildVariant)"
executable="$(read_key CFBundleExecutable)"
[ -n "$executable" ] || executable="$(basename "$app" .app)"

found=0; searched=""
for file in "$app/$executable" "$app/$executable.debug.dylib"; do
  [ -f "$file" ] || continue
  searched="$searched $(basename "$file")"
  if grep -a -q "$marker" "$file"; then found=1; fi
done
[ -n "$searched" ] || { echo "error: verify-build-variant: no executable found in $app"; exit 1; }

status=0
if [ -n "$expected" ] && [ "$declared" != "$expected" ]; then
  echo "error: $app declares variant '$declared' but '$expected' was expected."; status=1
fi
case "$declared" in
  unleashed)
    if [ "$found" -ne 1 ]; then
      echo "error: $app declares the Unleashed variant but its code does not contain the Unleashed backend (marker not found in:$searched). Build the HCGTerminalUnleashed scheme; see docs/BUILD_VARIANTS.md."; status=1
    fi ;;
  standard)
    if [ "$found" -ne 0 ]; then
      echo "error: $app declares the standard variant but contains the Unleashed backend."; status=1
    fi ;;
  *)
    echo "error: $app does not declare HCGBuildVariant (got '$declared')."; status=1 ;;
esac
if [ "$status" -eq 0 ]; then
  echo "verify-build-variant: $declared · Unleashed backend $( [ "$found" -eq 1 ] && echo linked || echo 'not linked') ·$searched"
fi
exit $status
