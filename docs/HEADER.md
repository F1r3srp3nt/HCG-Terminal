# Home-screen header

The home screen shows the HCG Terminal artwork (`TerminalHero` in `HCGTerminal/Resources/Assets.xcassets`). It is the angular HCG lettering with ">_ TERMINAL", stored as a lossless 2000×667 PNG.

The view is `TerminalHeroHeader` (`HCGTerminalKit/Sources/TerminalUI/Views/TerminalHeroHeader.swift`), and it is the same in the Standard and Unleashed apps. It says nothing about which capabilities are enabled.

| Layout | Where | Size |
|---|---|---|
| iPhone, portrait | Top of the home list, above the mode selector and New Session | Full content width inside the normal list margins (e.g. 288 pt on a 320 pt screen) |
| iPhone, landscape (compact height) | Same place | At most 330 pt wide (≈110 pt tall), so the controls stay on screen |
| iPad and other regular-width layouts | Centred at the top of the Dashboard | At most 560 pt wide |

- **Scaling:** the image is aspect-fit at its 3:1 ratio. It is never stretched or cropped.
- **Background:** the area around it is #010305, the colour of the artwork's own edges, so no rectangle shows.
- **Title:** the navigation bar keeps "HCG Terminal" as its title (for back buttons) but does not draw it.
- **VoiceOver:** reads the header once, as the heading "HCG Terminal". The image and any video layer are hidden from it.

## Animation (not bundled yet)

No animation file has been supplied, so the header is static, and **Settings → Appearance → Animated header** is hidden.

To add one, put a silent `TerminalHero.mp4` or `.mov` in `HCGTerminal/Resources/`. Both targets copy everything in that folder; nothing is loaded from the network. The file should be a seamless 6–8 s loop with the same 2000×667 framing and edge colour #010305; H.264 or HEVC is fine. With a file present:

- The static image is shown at once. The video fades in only once its first frame is ready, and stays hidden if playback fails.
- There is one muted, looping player per header, with no controls. View updates never create another player.
- It plays only while all of these hold: the setting is on, Reduce Motion is off, the in-app Reduce visual effects is off, Low Power Mode is off, the app is active and the home screen is visible. It pauses when you navigate away or the app goes to the background.
- The setting reads: "Animate the HCG logo on the home screen. Turn off for a still image and lower power use." It is saved with the other appearance settings.

`HeroPlaybackPolicy` and `TerminalHeroLayout` hold these rules. `Tests/TerminalUITests/TerminalHeroTests.swift` tests them, together with saving the setting and loading settings saved by older versions.
