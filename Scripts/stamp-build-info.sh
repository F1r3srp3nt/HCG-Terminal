#!/bin/sh
# Xcode build phase: writes the git source revision into the built Info.plist
# (key HCGSourceRevision). Never fails the build; falls back to "unknown".
#
# Override with HCG_SOURCE_REVISION_OVERRIDE=<value> (for example from CI).
# The variant key (HCGBuildVariant) comes from the target's HCG_BUILD_VARIANT setting.
set -u
plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$plist" ]; then
  echo "warning: stamp-build-info: $plist not found; revision not stamped"
  exit 0
fi
rev="${HCG_SOURCE_REVISION_OVERRIDE:-}"
if [ -z "$rev" ] && command -v git >/dev/null 2>&1 && git -C "$SRCROOT" rev-parse --git-dir >/dev/null 2>&1; then
  rev=$(git -C "$SRCROOT" rev-parse --short=12 HEAD 2>/dev/null || true)
  if [ -n "$rev" ] && [ -n "$(git -C "$SRCROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    rev="$rev-modified"
  fi
fi
[ -n "$rev" ] || rev="unknown"
/usr/libexec/PlistBuddy -c "Set :HCGSourceRevision $rev" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :HCGSourceRevision string $rev" "$plist"
echo "HCGSourceRevision=$rev (variant $(/usr/libexec/PlistBuddy -c 'Print :HCGBuildVariant' "$plist" 2>/dev/null || echo '?'))"
