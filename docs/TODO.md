# HCG Terminal: TODO and milestones

Legend: ✅ done and covered by automated checks · 🧪 done, verified only in the Simulator or CI · 📱 needs a physical device · ⬜ not started

## Done

### Foundation (v0.1)
- ✅ Vanilla / Unleashed modes; the selector never touches SSH sessions.
- ✅ Built-in command interpreter with persisted history and working directory, quoting, help and errors. It is labelled "not a system shell".
- ✅ Workspace files: browse, edit, import and export with conflict handling.
- ✅ SSH with host-key verification (trust on first use with approval; changed keys refused), classified errors, connection test, reconnect without re-running anything.
- ✅ Remote builds and tests with real exit status, cancellation (TERM to the remote process group), paths with spaces and artifact download (SHA-256 checked).
- ✅ Build identity: variant, version, build number, revision and bundle ID in Diagnostics.

### This milestone
- ✅ **Capabilities & Access**: ten switches with prerequisites. Defaults: expanded write off, privileged operations off. Settings persist. Each switch is enforced in its service (see `CAPABILITIES_AND_ACCESS.md`).
- ✅ Turning a switch off while something runs: explained first, cancellable, and applied with a controlled stop. Only verified stops are reported as stops.
- ✅ Statuses: not included / disabled by you / environment unknown / tool missing / permission denied / available, untested / verified working. A switch never turns an unavailable capability green.
- ✅ Layered environment assessment:
  - build, device, bootstrap (rootless, relocated, custom, rootful; strong and weak indicators; resolved tools), process (container, install route) and operations;
  - indicators kept separate from shell usability; "not observable" inside the sandbox.
- ✅ Explicit, bounded tests: shell test (5 s limit) and write test (temporary file removed and checked).
- ✅ Unleashed programs: listed from the program folders; run with a 20 s limit or in a PTY session; accurate errors (EPERM, ENOENT, ENOEXEC, SIGKILL at launch, timeout).
- ✅ Process list gated by its switch; package inventory first, then changes only after approval.
- ✅ Build integrity:
  - target-only `Variants/` composition with `#error` guards;
  - "Verify build variant" phase (backend marker) with a self-test on fake bundles;
  - packaging refuses a mismatched bundle.
- ✅ Optional `.deb` (rootless or rootful) for jailbroken devices; written to disk only.
- ✅ Fixed a PTY descriptor-reuse race that intermittently caused empty process output.
- 🧪 HCG design: obsidian/metal/cyan theme, violet Unleashed, dashboard, compact capability cards, appearance settings (theme, accent, reduced effects, terminal text size), Dynamic Type text styles, 44 pt targets. Compiled and launched in the Simulator in CI; not reviewed on a device.

### Home-screen header
- ✅ `TerminalHero` artwork in the asset catalog (both targets, checked in Release builds by CI). Shown as `TerminalHeroHeader`: in the iPhone home list, centred on the iPad dashboard, smaller in landscape. A single VoiceOver heading.
- ✅ Looping-video support with a static fallback, playback rules and the Animated header setting. The setting is hidden until a `TerminalHero.mp4`/`.mov` is bundled.
- ⬜ Animation file: not supplied yet (see `HEADER.md`).

### Unleashed diagnostics and local terminal path (from the iPhone 11 Pro Max screenshots)
- ✅ Every probe recorded with operation, path, return value, errno and time. Every shell, package and helper path is resolved and listed.
- ✅ EPERM/EACCES reported as denied, never missing. ENOENT is absence only where the roots could be inspected. Broken symlinks and missing execute bits are reported separately.
- ✅ Independent results:
  - listing, reading and writing are separate;
  - package inventory (from the dpkg status file, no apt) is separate from package changes;
  - the localhost SSH fallback is its own capability.
- ✅ "Unleashed partially available" banner, with the actions Recheck, Test local shell, Configure connection and View setup requirements.
- ✅ Test local shell tries existing shell files even when `access(X_OK)` was refused; only a launch can verify. Sessions use the shell that launched.
- ✅ Localhost SSH with an explicit host and port (this device only) and host-key verification. Verified only after sign-in plus a PTY.
- ✅ Switches: Unleashed features (master), Localhost SSH fallback, plus the existing shell, browsing and modification switches, with confirmation for open sessions.
- 📱 Device checklist for both phones: `DEVICE_TESTS.md`.
- ⬜ **Needed from you:** jailbreak name and version, bootstrap, and whether TrollStore is installed. These decide the `.deb` entitlements for an unsandboxed install, the only route to a working local shell on Phone A.

### HCG Event Horizon reskin (see `DESIGN.md`)
- ✅ Semantic tokens with Increase Contrast values; background policy, cached geometry, ambient-motion rules and session-header wording are unit tested.
- 🧪 Background system, edge-lit panels, compact terminal header and frame, themed key row, empty states, document surfaces, reduced iPhone banner, Appearance settings (Event Horizon / Classic, background detail, ambient motion). Checked in Simulator screenshots in CI (both builds, small iPhone, iPad, landscape, large text, Increase Contrast); not on a device.
- 📱 Device check: Reduce Motion and Reduce Transparency system switches, ambient motion on and off in Low Power Mode, key row feel and pressed states, ProMotion scrolling with long output.

## Remaining milestones

### Device verification 📱
- [ ] Ordinary iPhone, small screen (SE / mini): dashboard, Capabilities & Access, VoiceOver labels, largest Dynamic Type sizes, Reduce Motion / Reduce Transparency, System theme in light mode.
- [ ] iPad (split view and full screen): dashboard grid, keyboard shortcuts and key row with a hardware keyboard.
- [ ] Header: look at it on a small iPhone, an iPad and an iPhone in landscape; with an animation bundled, check pause on navigation, background and Low Power Mode.
- [ ] Standard build from Xcode and from TestFlight: Diagnostics → Build shows "Standard", Unleashed switches show "Not in this build".
- [ ] Unleashed build, sandboxed install on a jailbroken device: Permission denied / not observable shown correctly; loopback service works.
- [ ] Unleashed `.deb` install (**needs your jailbreak, iOS version and bootstrap**): shell test, PTY, programs, packages, write test, approval prompts, switches turned off while a shell runs.

### Product
- [ ] Remote builds against a real Mac (`xcodebuild`, simulators) and Windows / .NET hosts.
- [ ] Private-key import; SFTP transfers.
- [ ] Per-host "remote builds allowed" switch (today a single global switch).
- [ ] Snapshot or UI tests for the new screens (XCUITest in the Simulator job).
- [ ] App Store Connect: rename the record for `…hcgterminal` to "HCG Terminal"; create a separate record only if an Unleashed TestFlight is wanted (it would still be sandboxed).

### Release hygiene
- [ ] Signed archive and IPA export by you (HCG Terminal never uploads or publishes).
- [ ] Encryption export-compliance answer confirmed by you (unchanged in this milestone).
