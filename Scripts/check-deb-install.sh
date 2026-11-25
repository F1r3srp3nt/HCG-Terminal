#!/bin/sh
# Installation check for an HCG Terminal Unleashed .deb, without a device.
#
#   Scripts/check-deb-install.sh <package.deb>
#
# dpkg installs the package into a scratch root, the same way Zebra and Sileo hand it to dpkg.
# A stub `uicache` records how the maintainer scripts call it. The script then checks:
#   - the app bundle lands in /var/jb/Applications (rootless);
#   - Info.plist names an executable that exists and is executable;
#   - CFBundleIdentifier and CFBundlePackageType (APPL);
#   - the PTY helper is executable; files are not group/world writable;
#   - postinst registers the app with `uicache -p <bundle>`;
#   - reinstall (the upgrade path) works;
#   - remove runs `uicache -u <bundle>` and leaves no files behind.
# Nothing is installed on this machine outside the scratch root.
set -eu

deb="${1:?usage: check-deb-install.sh <package.deb>}"
deb=$(cd "$(dirname "$deb")" && pwd)/$(basename "$deb")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"
mkdir -p "$root/var/lib/dpkg/info" "$root/var/lib/dpkg/updates" "$work/bin"
: > "$root/var/lib/dpkg/status"
log="$work/uicache.log"
cat > "$work/bin/uicache" <<EOF
#!/bin/sh
echo "uicache \$*" >> "$log"
EOF
chmod +x "$work/bin/uicache"

fail() { echo "FAIL: $*" >&2; exit 1; }
dpkg_run() {
  PATH="$work/bin:$PATH" dpkg --root="$root" --force-not-root --force-depends --force-architecture \
    --force-script-chrootless --log=/dev/null "$@"
}

package=$(dpkg-deb -f "$deb" Package)
version=$(dpkg-deb -f "$deb" Version)
echo "== $package $version"

echo "-- install"
dpkg_run -i "$deb"
dpkg --root="$root" -s "$package" | grep -q "^Status: install ok installed" || fail "not installed"

app=$(find "$root/var/jb/Applications" -maxdepth 1 -name "*.app" -type d | head -1)
[ -n "$app" ] || fail "no app bundle under /var/jb/Applications"
bundle="/var/jb/Applications/$(basename "$app")"
echo "bundle $bundle"

python3 - "$app" <<'PY'
import os, plistlib, stat, sys
app = sys.argv[1]
info = plistlib.load(open(os.path.join(app, "Info.plist"), "rb"))
def need(cond, msg):
    if not cond:
        sys.exit("FAIL: " + msg)
exe = info.get("CFBundleExecutable")
need(exe, "Info.plist has no CFBundleExecutable")
path = os.path.join(app, exe)
need(os.path.isfile(path), f"executable {exe} is missing")
mode = os.stat(path).st_mode
need(mode & stat.S_IXUSR and mode & stat.S_IXOTH, f"{exe} is not executable for everyone ({oct(mode)})")
need(info.get("CFBundlePackageType") == "APPL", "CFBundlePackageType is not APPL")
need(str(info.get("CFBundleIdentifier", "")).startswith("com.hakmicapitalgroup."), "unexpected CFBundleIdentifier")
need("iPhoneOS" in info.get("CFBundleSupportedPlatforms", []), "CFBundleSupportedPlatforms lacks iPhoneOS")
helper = os.path.join(app, "hcg-pty-helper")
if os.path.exists(helper):
    need(os.stat(helper).st_mode & stat.S_IXOTH, "hcg-pty-helper is not executable")
for base, dirs, files in os.walk(app):
    for name in dirs + files:
        p = os.path.join(base, name)
        m = os.lstat(p).st_mode
        need(not (m & stat.S_IWOTH or m & stat.S_IWGRP), f"{p} is group/world writable")
        need(not (m & (stat.S_ISUID | stat.S_ISGID)), f"{p} is setuid/setgid")
print(f"Info.plist: {info['CFBundleIdentifier']} executable {exe} ({oct(mode & 0o7777)}), version {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})")
PY

grep -qx "uicache -p $bundle" "$log" || { cat "$log" 2>/dev/null; fail "postinst did not run 'uicache -p $bundle'"; }
echo "postinst: uicache -p $bundle"

echo "-- reinstall (upgrade path)"
: > "$log"
dpkg_run -i "$deb"
dpkg --root="$root" -s "$package" | grep -q "^Status: install ok installed" || fail "not installed after reinstall"
grep -qx "uicache -p $bundle" "$log" || fail "postinst did not register the app again after reinstall"

echo "-- remove"
: > "$log"
dpkg_run -r "$package"
grep -qx "uicache -u $bundle" "$log" || { cat "$log" 2>/dev/null; fail "postrm did not run 'uicache -u $bundle'"; }
[ ! -e "$app" ] || fail "app bundle left behind after removal"
dpkg_run -P "$package"
if dpkg --root="$root" -s "$package" >/dev/null 2>&1; then fail "still known to dpkg after purge"; fi
echo "OK: install, reinstall, remove and purge behave as expected"
