# Doctor, Build & Install, Log Console

From the iPhone: pick a project on your Mac, check what it needs, run a real build, follow its log, get the product and see the right next step for it.

**Where:** Hosts & Projects → a host → Browse Projects → a project folder → **Doctor · Build & Install**. Jobs also appear in **Builds & Tests**; all output is in **Log Console** (sidebar).

## How it fits the existing app

| Piece | Reused | Added |
|---|---|---|
| Connection | The host's SSH connection, its host-key check and the stored password or key (Keychain). | — |
| Environment | `RemoteShell.login`: every probe and build runs in the user's **login shell**, so Doctor and builds see the same PATH, `DEVELOPER_DIR`, `THEOS`. | The build log starts with that PATH and `xcode-select -p`, as evidence. |
| iOS builds | **HCG Executable Maker's own engine** through its existing `tools/mobile-build/mobile-build.cs` CLI (import, inspect, xcodebuild, verify, checksums, build history). | A job wrapper (below). Builds are recorded in Executable Maker's normal history folder, so they also appear in its app. |
| Other builds | `BuildPlanner` (xcodebuild, `swift build`, `dotnet build`). | Theos `make package`: Executable Maker has no Theos pipeline. |
| Artifacts | `ArtifactDownloader` (SHA-256 checked against the host) and the workspace artifact index. | A manifest written on the host by the job. |
| `.deb` install | Unleashed's package workflow: approval prompt, then a visible Local Unleashed session. | One new request: install a `.deb` file with `dpkg -i`. |
| Pairing | — | None. HCG Connect has no pairing or device identity yet, in Executable Maker or HCG Server, so SSH stays the only link. |

**HCG Server** has no build, log or command API, so nothing is labelled "HCG Server". Every result shows **This device** or the host's name and address.

## Doctor (read-only)

Doctor runs one POSIX script in your login shell on the host. The script only reads:

- `uname`, `sw_vers`, `df`, `command -v`;
- version queries: `xcodebuild -version`, `dotnet --version` / `--list-sdks`, `make --version`, `ldid -v`, `dpkg-deb --version`;
- `xcrun --show-sdk-version`, `xcrun simctl list runtimes`;
- `xcodebuild -list` and `-showBuildSettings` (automatic package resolution off);
- `security find-identity -v -p codesigning` (names and hashes, never keys);
- provisioning profiles, decoded to a temporary file that is deleted right away.

It installs nothing and changes no settings. A test checks that the project folder and home folder are byte-for-byte unchanged afterwards.

**Checks:**

- **Host:** operating system and architecture.
- **Disk:** free space on the project volume. Under 10 GB is a warning; under 2 GB blocks the build.
- **Xcode:**
  - installed and selected (`xcode-select -p`), license accepted, first launch done;
  - SDKs and Simulator runtimes;
  - schemes;
  - the **effective** deployment target of the chosen scheme, compared with the SDK and the Simulator runtimes.
- **HCG Executable Maker:** a source checkout with the mobile-build CLI. Doctor looks in `~/HCG-Executable-Maker` and similar folders, or uses the folder set in the host's settings.
- **.NET:** SDK on PATH and the project's `global.json`. Doctor runs `dotnet --version` in the project folder, which is .NET's own verdict. It also checks target frameworks and the SDK Executable Maker needs (10.0.100, latestFeature).
- **Theos:** `$THEOS` in the login shell, the SDK named in the Makefile's `TARGET`, GNU Make 4 or newer, `ldid` and `dpkg-deb`.
- **Signing:** identities, and whether a provisioning profile covers the bundle ID and team (development, ad hoc, enterprise or App Store; expired or not).

**Statuses** are **Passed**, **Warning**, **Blocked** and **Unknown**. Unknown means the check could not be made; for example, Automatic signing cannot be confirmed without building.

**Tool states** need different fixes, so Doctor reports which one applies:

- **not installed**;
- **installed, but not found in this environment**: for example dotnet in `/usr/local/share/dotnet` but not on the login shell's PATH, or Xcode installed while `xcode-select` points at the Command Line Tools;
- **installed but incompatible**: for example `make` 3.81, a `global.json` SDK that is missing, or a deployment target newer than the SDK.

Each check shows its evidence (the detected version, path and command output), which outputs it affects, and specific next steps. HCG Terminal never runs `sudo`, `xcode-select -s` or `brew` for you.

## Build & Install

The plan sheet offers only outputs Doctor found for the project: iOS Simulator app, archive or IPA (through Executable Maker, or a direct xcodebuild), macOS app, Swift package, .NET, or Theos package. You also choose:

- the configuration;
- the scheme (for direct builds);
- signing, from the identities and profiles already on the Mac: project settings, unsigned (archive only), Automatic with a team, or Manual with a profile.

App Store Connect export is not offered.

**The preview** shows, before anything starts:

- the host;
- the engine and its location;
- the login shell and its PATH;
- the exact command;
- Doctor's blockers and warnings for that output.

**Start** is disabled while Doctor reports a blocker.

### Jobs survive the phone

Each build runs as a detached job in `~/.hcg-terminal/jobs/<job-id>/` on the host, started with `setsid` and `nohup`. The folder holds `run.sh`, `out.log`, `pid`, `exit` and `artifacts.tsv`.

- **One run per job.** The phone creates the job ID before sending anything and saves it. The host refuses an ID it has already seen (an atomic `mkdir`), so a retry after a lost reply never starts a second build.
- **One build per project.** A per-project lock refuses a second concurrent build of the same project and names the running job.
- **A lost connection is not a failure.** The job stays *running*. The phone retries after 2, 5, 10, 20, 30 and 60 s, then offers **Reattach**. Following resumes at the byte offset already stored, so no line is lost or repeated.
- **The outcome comes from the host.** Only the exit status the job writes on the host decides *succeeded* or *failed*. If the process disappears without one (for example the Mac restarted), the job is *ended without a result*.
- **Cancel** sends TERM to the job's process group, then KILL after 15 seconds.
- **Relaunch:** after an app relaunch, active jobs are reattached automatically.

**Artifacts** are listed with their name, type, size, SHA-256, source job and, for Executable Maker builds, its verification result.

- Folders (`.app`, `.xcarchive`) are packed in the job folder (`ditto` zip on macOS) so the download is a single file.
- Downloads go to the workspace under `/artifacts/<date>/` and are checked against the host's SHA-256. You can share them from there.

### Next step (installation)

The options depend on what the artifact supports. Each one needs confirmation, and the result reports only what the host confirmed. "Installed" appears only after the install tool succeeds; "launched" only after `simctl launch` returns a process ID.

| Artifact | Offered | Not offered, with the reason shown |
|---|---|---|
| iOS Simulator app | Install and launch in a Simulator on the build Mac whose iOS version is at least the app's minimum. | Installing on an iPhone. |
| Signed device app / IPA | Install through the Mac with `xcrun devicectl` on a connected or paired device. Development and ad hoc builds: only if the device is in the profile. Enterprise builds: any device. | App Store-signed builds (TestFlight/App Store only; HCG Terminal never uploads), unsigned builds, expired profiles, archives (export an IPA first). The iPhone cannot read its own UDID, so it is not matched automatically. |
| Theos `.deb` | Unleashed, when a package manager is found and Package management and Local shell are on: download, approval prompt, then `dpkg -i` in a visible Local Unleashed session. No respring. | Vanilla, or Unleashed without those: download and open it in your package manager. |
| macOS app, .NET, executables | Download only. | The compatible desktop host is identified: build host OS and architecture, the .NET runtime identifier, or "framework-dependent". |

## Log Console

- **Sources:** Doctor, Build, Install, and the app's own diagnostic log (This device).
  - Device or system logs are not offered: iOS does not let apps read them, and no authorized helper exists.
- **Labels:** every line carries a timestamp, its source, the execution host and the job.
- **Pause / resume:** Pause freezes the display while output keeps arriving; the count of new lines is shown.
- **Filters:** search, minimum severity and source.
- **Copy and export:** the lines currently shown.
- **Bounded:** at most 20 000 lines on screen. The job's full log stays on the phone and on the host.
- **Redaction:** before anything is stored, shown or exported. It covers:
  - Authorization headers, bearer tokens and passwords in URLs;
  - `password=` / `token=` / `api_key=` style values, `--password` / `--token` flags and MSBuild `/p:…Password=`;
  - GitHub, AWS, Slack, OpenAI/Anthropic-style, GitLab, npm and Google API keys, and JWTs;
  - PEM private keys;
  - the host's own saved password.
- **Severity by structure:**
  - compiler diagnostics (`file:line:col: error:`, `File.cs(1,2): error CS…`), linker errors, signing errors, test failures, tool errors (`xcodebuild: error:`, `command not found`, Theos `==> Error:`);
  - summaries such as `** BUILD FAILED **` and `make: *** Error 2`;
  - `ErrorView.swift`, `-Werror` and `0 Error(s)` are not errors.
- **First failure:** the earliest specific failure, with four lines before and after, from the stored (redacted) log. A generic summary is shown only when nothing specific exists, and is labelled as such.

## Setup on your Mac

1. Turn on **System Settings → General → Sharing → Remote Login**.
2. Add the Mac in **Hosts & Projects** (password or key) and verify its host key once.
3. For Executable Maker builds, the source checkout and the .NET 10 SDK are needed. For example:
   ```sh
   git clone https://github.com/F1r3srp3nt/HCG-Executable-Maker ~/HCG-Executable-Maker
   ```
   Install .NET 10 from dot.net. The first `dotnet run` compiles the CLI and restores NuGet packages, so it needs the network once. A different folder can be set in the host's settings.
4. Xcode selected (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`), license accepted, a Simulator runtime installed.
5. For Theos, also needed:
   - `THEOS` exported in your login profile (for example `~/.zprofile`);
   - GNU Make 4 (`brew install make`, with its gnubin on PATH or found by Doctor);
   - `ldid` and `dpkg`.
6. For device installs through the Mac: the iPhone paired with the Mac in Xcode (cable or network), and a development or ad hoc profile that includes it.

Run Doctor on the project. Each blocked check says what to change.

## Verification

| What | How | Where |
|---|---|---|
| Doctor rules: Xcode/CLT selection, license, deployment target vs SDK and runtimes, `global.json`, target frameworks, Executable Maker's .NET 10, dotnet off PATH, Theos THEOS/SDK, make 3.81 vs 4.x, ldid/dpkg-deb, signing states, profile kinds, Linux host, incomplete probe | `DoctorTests` (Mac facts as fixtures) | Linux + macOS CI |
| The real probe script runs, parses and changes nothing | `DoctorTests.testProbeScriptRunsAndIsReadOnly`; over SSH: `RemoteJobIntegrationTests.testDoctorProbeOverSSHUsesTheLoginShell` | Linux CI (OpenSSH) |
| Detached jobs: real exit status, redaction, idempotent start, project lock, cancel of the process group, resume at offset without repeats, restart reconciliation, removal, Theos artifact with checksum | `HostJobTests` (local `/bin/sh`) | Linux + macOS CI |
| SSH disconnection mid-build, reattach on a new connection, one run on the host, cancel over SSH | `RemoteJobIntegrationTests` | Linux CI (OpenSSH) |
| Phone flow through the app model: Doctor → job → console (host label, password redacted) → verified download → install options | `DevToolsCenterTests` | Linux CI (OpenSSH) |
| Executable Maker command (signing, export, no upload) and its output (stages, result, artifacts, checks, build ID) | `DoctorTests.testExecutableMakerCommandAndOutputParsing` | Linux + macOS CI |
| Install rules (simulators by minimum OS, profile device matching, unsigned/App Store/expired/archive, `.deb` only on Unleashed, desktop host) and outcome markers | `InstallHandoffTests` | Linux + macOS CI |
| Redaction, severity classification, first failure, bounded buffer | `SecretRedactionTests`, `LogClassifierTests` | Linux + macOS CI |
| Screens compile; Doctor, job and console screenshots with **synthetic, labelled** sample data (no Mac in CI) | `doctor`, `job`, `console` smoke scenarios | iOS Simulator CI |

**Not verified live:**

- an Executable Maker build on a real Mac;
- a Simulator install and launch;
- a `devicectl` install;
- a Theos build with the real toolchain;
- a `dpkg` handoff on a jailbroken device.

These need your Mac (Xcode, .NET 10, an Executable Maker checkout, signing assets), a paired iPhone and, for `.deb`, your jailbroken device. See [`TODO.md`](TODO.md).
