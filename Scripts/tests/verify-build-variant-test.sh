#!/bin/sh
# Self-test for Scripts/verify-build-variant.sh with fake bundles: it must accept matching
# bundles and reject an "Unleashed" bundle without the backend (and the reverse).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mk() { # dir variant executable content
  mkdir -p "$1"
  python3 -c 'import plistlib,sys; plistlib.dump({"HCGBuildVariant":sys.argv[2],"CFBundleExecutable":sys.argv[3]},open(sys.argv[1],"wb"))' "$1/Info.plist" "$2" "$3"
  printf "%b" "$4" > "$1/$3"
}
mk "$tmp/Unleashed.app" unleashed U 'x\000HCG-UNLEASHED-BACKEND-LINKED-v1\000y'
mk "$tmp/Standard.app" standard S 'plain'
mk "$tmp/NamedOnly.app" unleashed N 'plain'
mk "$tmp/Leaky.app" standard L 'x\000HCG-UNLEASHED-BACKEND-LINKED-v1\000'
mk "$tmp/DebugDylib.app" unleashed D 'stub'
printf 'x\000HCG-UNLEASHED-BACKEND-LINKED-v1\000' > "$tmp/DebugDylib.app/D.debug.dylib"
fail=0
expect() { # expected-exit app [variant]
  "$here/verify-build-variant.sh" "$2" ${3:-} >/dev/null 2>&1; got=$?
  if [ "$got" -eq "$1" ]; then echo "PASS: $(basename "$2") ${3:-} → exit $got"; else echo "FAIL: $(basename "$2") ${3:-} → exit $got, expected $1"; fail=1; fi
}
expect 0 "$tmp/Unleashed.app" unleashed
expect 0 "$tmp/Standard.app" standard
expect 0 "$tmp/DebugDylib.app"
expect 1 "$tmp/NamedOnly.app"
expect 1 "$tmp/Leaky.app"
expect 1 "$tmp/Standard.app" unleashed
exit $fail
