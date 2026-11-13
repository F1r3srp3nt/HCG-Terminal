# HCG Event Horizon

The visual system of HCG Terminal and HCG Terminal Unleashed. Both builds share it: the
Unleashed build only adds restrained violet around its own badge and selected controls.
Appearance never changes what the app may do. Every capability check is unchanged, and a
decoration never suggests that something unavailable has become available.

## Tokens

All colours come from `HCGPalette` (`HCGTerminalKit/Sources/TerminalUI/Views/Theme.swift`).
Views use the semantic names; the older names (`canvas`, `surface`, `ivory`, …) are aliases
of the same tokens.

| Token | Dark | Increase Contrast (dark) | Use |
|---|---|---|---|
| `background` | `#05090E` | `#000000` | Base behind everything |
| `surfaceDeep` | `#0B141E` | `#0B141E` | Panels, list rows, document surfaces |
| `surfaceElevated` | `#111F2B` | `#16293A` | Controls, keys, selector track |
| `border` | `#1D2D3B` | `#5C7385` | Fine borders and separators |
| `accentPrimary` | `#27D7EA` | `#6BEAF7` | Edge lighting, primary accent |
| `accentSecondary` | `#7CA8FF` | `#A9C6FF` | Secondary highlights |
| `textPrimary` | `#EDF5F8` | `#FFFFFF` | Text |
| `textSecondary` | `#A4B5C1` | `#D3DEE6` | Secondary text |
| `terminalSurface` | `#04080C` | — | Terminal background, always opaque |

Each token also has a light value for the System theme. Status colours (`ok`, `warn`, `loss`)
always come with an icon and a text label.

## Background system

`HCGBackdrop` (`Views/EventHorizon.swift`) covers every screen, sheet and empty state,
including the safe areas. It has three layers:

1. the near-black base;
2. a faint navy/cyan glow pooled in the corners, leaving the centre untouched;
3. sparse circuit traces (about 3 % opacity; 4.5 % with Enhanced detail), corner brackets,
   chamfer lines and, with Enhanced detail, rows of fine ticks.

The geometry (`Model/EventHorizonGeometry.swift`) is generated once from a fixed seed and
cached. Every point is anchored to an edge and lies at most 84 pt from it, so the centre of
every screen shape stays quiet. Unit tests check this. The backdrop reads no session state, so
terminal output never redraws it. It never takes touches and is hidden from VoiceOver.

`BackdropPolicy` decides which layers to draw. The following all give the **opaque fallback**
(flat base, no glow, no geometry, plain borders):

- Classic;
- Reduce visual effects;
- Reduce Transparency;
- Increase Contrast;
- the light appearance.

## Ambient motion

Off by default. When it is on, the edge glow breathes very slowly (a 12-second period, ±9 %).
`AmbientMotionPolicy` stops it during terminal use, in the background, in Low Power Mode, with
Reduce Motion, and whenever the glow is not drawn. There are no scanlines, flashing,
particles, falling code or fake telemetry.

## Terminal screen

- **Renderer:** unchanged. The character grid, ANSI colours (including explicit backgrounds),
  selection, scrolling, cursor, input and full-screen programs all behave as before.
- **Surface:** fully opaque, with no blur, opacity or decoration over the text. The chamfered
  frame and its two accent corners sit outside a 5-pt content inset; the inset exceeds what the
  8-pt chamfer reaches, so no cell is clipped. Classic stays edge to edge.
- **Header, first row:**
  - back button (iPhone only);
  - session name, middle-truncated, with the full name in VoiceOver;
  - mode badge;
  - Interrupt, Details and Close, each 44 pt.
- **Header, second row:**
  - the compact Vanilla/Unleashed selector;
  - a one-line summary of the real state and where the session runs, plus a note when the
    preferred mode is unavailable, still being checked, or different from this session's mode.
    Tapping it expands the backend and capability details.
- **Key row:** elevated keys with fine borders, at least 44 × 40 pt. A pressed key lights up in
  the mode accent. When Ctrl is armed it is filled with the accent and VoiceOver reports "On".
  The system keyboard is left to iOS.
- **No ambient motion** on this screen.

## Components

- **Panels:** opaque deep surface, chamfered corners, a fine border and a short cyan edge light.
  No glow in the opaque fallback.
- **List rows:** `hcgRows()` on every list and form, including sheets.
- **Empty states:** `HCGEmptyState`, with the terminal emblem (or a symbol), concise guidance
  and a primary action where one exists.
- **Documents:** editors and previews sit on an opaque document surface (`hcgDocumentSurface()`).
- **iPhone home:**
  - a reduced banner, at most 250 pt wide;
  - the mode selector, then a prominent **New Session** (local, localhost SSH on Unleashed, or
    remote).

## Settings

**Settings → Appearance:**

- **Style:** Event Horizon (default) or Classic.
- **Background detail:** Off, Subtle (default) or Enhanced.
- **Ambient motion:** off by default.
- Theme, accent, Reduce visual effects, Animated header (only when an animation is bundled) and
  terminal text size are unchanged. Saved settings from earlier versions keep their values.

## Verification

- **Unit tests** (`Tests/TerminalUITests/EventHorizonTests.swift`):
  - defaults and migration of saved settings;
  - background policy and the opaque fallback;
  - ambient motion conditions;
  - deterministic cached geometry and the quiet centre on eight screen shapes;
  - 45° geometry;
  - the reduced banner;
  - wording of the session-header summary.
- **CI screenshots in the iOS Simulator** (`.github/workflows/apple-build.yml`), both builds:
  - every screen and sheet;
  - long session names;
  - long ANSI output and a full-screen program drawing (synthetic output fed to the real
    renderer);
  - the editor, empty states, Classic, Enhanced and the opaque fallback;
  - keyboard hidden, landscape, large accessibility text and Increase Contrast, set with
    `simctl`;
  - small iPhone and iPad.
- **Not verified:**
  - on a physical device;
  - with the system's Reduce Motion / Reduce Transparency switches (the app's Reduce visual
    effects runs the same fallback path, which is unit tested);
  - ambient motion visually (only its policy is unit tested).
