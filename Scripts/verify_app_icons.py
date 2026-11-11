#!/usr/bin/env python3
"""Checks the app icon metadata of a built iOS .app bundle.

Usage: Scripts/verify_app_icons.py <path/to/App.app> [--icon-name AppIcon]

Reports, from the built product (not from the source asset catalog):
  - Info.plist: CFBundleIconName (top level and inside CFBundleIcons / CFBundleIcons~ipad),
    CFBundlePrimaryIcon icon files for iPhone and iPad;
  - Assets.car: every rendition of the icon set, by idiom and pixel size
    (needs `xcrun assetutil`, i.e. macOS with Xcode);
  - loose icon PNGs Xcode copies into the bundle.

Fails (exit 1) when CFBundleIcons or CFBundleIcons~ipad does not name the icon set in
CFBundlePrimaryIcon.CFBundleIconName, or when the compiled catalog lacks the iPhone home-screen
icons (120, 180 px), the iPad home-screen icons (152, 167 px) or the App Store icon (1024 px).
Everything else is reported, not enforced.

On iOS, CFBundleIconName belongs inside CFBundleIcons / CFBundlePrimaryIcon; that is where actool
writes it (verified with Xcode 26.6). A top-level CFBundleIconName is the macOS location and is
only reported.
"""
import json
import os
import plistlib
import subprocess
import sys

EXPECTED = {
    # idiom -> {pixel size: purpose}
    "phone": {40: "notification 20@2x", 60: "notification 20@3x", 58: "settings 29@2x", 87: "settings 29@3x",
              80: "spotlight 40@2x", 120: "spotlight 40@3x / app 60@2x", 180: "app 60@3x"},
    "pad": {20: "notification 20@1x", 40: "notification 20@2x / spotlight 40@1x", 29: "settings 29@1x",
            58: "settings 29@2x", 80: "spotlight 40@2x", 76: "app 76@1x", 152: "app 76@2x", 167: "app 83.5@2x"},
    "marketing": {1024: "App Store 1024@1x"},
}
REQUIRED = {"phone": {120, 180}, "pad": {152, 167}, "marketing": {1024}}


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    app = args[0].rstrip("/")
    icon_name = args[args.index("--icon-name") + 1] if "--icon-name" in args else "AppIcon"
    failures = []

    with open(os.path.join(app, "Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    print(f"== {app}")
    print(f"CFBundleIdentifier: {info.get('CFBundleIdentifier')}")
    print(f"CFBundleIconName (top level, macOS location, informational): {info.get('CFBundleIconName')}")
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        primary = (info.get(key) or {}).get("CFBundlePrimaryIcon") or {}
        print(f"{key}.CFBundlePrimaryIcon.CFBundleIconName: {primary.get('CFBundleIconName')}")
        print(f"{key}.CFBundlePrimaryIcon.CFBundleIconFiles: {primary.get('CFBundleIconFiles')}")
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        name = ((info.get(key) or {}).get("CFBundlePrimaryIcon") or {}).get("CFBundleIconName")
        if name != icon_name:
            failures.append(f"{key}.CFBundlePrimaryIcon.CFBundleIconName is {name!r}, expected {icon_name!r}")

    loose = sorted(f for f in os.listdir(app) if f.startswith(icon_name) and f.endswith(".png"))
    print(f"Loose icon PNGs in bundle: {loose or 'none'}")

    car = os.path.join(app, "Assets.car")
    if not os.path.exists(car):
        failures.append("Assets.car is missing")
    else:
        try:
            raw = subprocess.run(["xcrun", "--sdk", "iphoneos", "assetutil", "--info", car],
                                 check=True, capture_output=True, text=True).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"assetutil unavailable: {error}")
            raw = None
        if raw is not None:
            renditions = [r for r in json.loads(raw) if isinstance(r, dict) and r.get("Name") == icon_name]
            found = {}
            for r in renditions:
                idiom = (r.get("Idiom") or "universal").lower()
                width = r.get("PixelWidth")
                if isinstance(width, int):
                    found.setdefault(idiom, set()).add(width)
            print(f"Assets.car renditions named {icon_name}: {len(renditions)}")
            for idiom in sorted(found):
                print(f"  {idiom}: {sorted(found[idiom])} px")
            for idiom, sizes in EXPECTED.items():
                have = found.get(idiom, set())
                for size, purpose in sorted(sizes.items()):
                    print(f"  coverage {idiom:9} {size:5} px ({purpose}): {'present' if size in have else 'absent'}")
            for idiom, sizes in REQUIRED.items():
                missing = sorted(sizes - found.get(idiom, set()))
                if missing:
                    failures.append(f"Assets.car lacks {idiom} icon sizes {missing}")

    for failure in failures:
        print(f"FAIL: {failure}")
    print("RESULT:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
