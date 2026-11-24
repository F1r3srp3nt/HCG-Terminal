# HCG Terminal and HCG Nexus

HCG Nexus 0.4.0~beta1 and later show HCG Terminal in their **HCG Ecosystem** dashboard (HCG Interchange Protocol v1,
HCG-Nexus `docs/INTERCHANGE.md`). Both directions only navigate.

## Nexus → HCG Terminal

Nexus opens `<scheme>://open/<screen>` (`TerminalDeepLink`, `HCGTerminalKit/Sources/TerminalUI/Model/HCGEcosystem.swift`).
A link never starts a session, runs a command, changes a setting or passes text into a terminal.

| Screen | Link (Unleashed) | Since |
|---|---|---|
| Dashboard, Unleashed Tools, Diagnostics, Files, Log Console, SSH Hosts, Capabilities, Settings | `hcgterminal-unleashed://open/dashboard` … | 0.2.0~rc1 |
| Jailbreak Diagnostics | `hcgterminal-unleashed://open/jailbreak-diagnostics` | this branch (next RC) |
| Installed Packages (Unleashed Tools) | `hcgterminal-unleashed://open/packages` | this branch |
| Processes | `hcgterminal-unleashed://open/processes` | this branch |

The Unleashed target ships `HCGTerminal-Support/Info-Unleashed.plist`. Besides everything in `Info.plist` (keep the
two in step), it declares:

```xml
<key>HCGInterchange</key>
<dict><key>protocol</key><integer>1</integer><key>product</key><string>terminal-unleashed</string>
<key>routes</key><array><string>jailbreak-diagnostics</string><string>packages</string><string>processes</string></array></dict>
```

Nexus uses the three direct links only when this declaration is present. With 0.2.0~rc2, Nexus opens Unleashed Tools
and says the screen is one tap away. A declaration can only narrow what Nexus offers.

## HCG Terminal → Nexus

*Settings › HCG Ecosystem › HCG Nexus › Open in HCG Nexus* (Unleashed only) posts the Darwin notification
`com.hakmicapitalgroup.hcgnexus/open/product/terminal-unleashed`, with no payload (`HCGNexusLink`). The button
appears only when HCG Nexus 0.4.0 or later is installed (read from its Settings bundle).

Nexus opens its panel at HCG Terminal Unleashed's page in the HCG Ecosystem dashboard, under these conditions:
the iPhone is unlocked, *Let HCG Apps Open Nexus* is on, and the last request was more than 2 s ago. HCG Terminal
sends nothing else and receives nothing back.

HCG Terminal keeps its own hosts, keys, passwords and sessions; Nexus never sees them and never reports HCG Terminal
as "connected".
