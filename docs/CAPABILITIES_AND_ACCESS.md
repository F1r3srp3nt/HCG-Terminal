# Capabilities & Access

**Settings → Capabilities & Access** has one switch per area. For each switch, three facts are kept separate:

1. **Included in this build**: whether the code exists. Unleashed areas are not in the standard build.
2. **Available to this process on this device**: what read-only detection and real use observed.
3. **Enabled by you**: the switch.

The status you see applies the switch last. A switch can turn a usable status into *Disabled by you*. It cannot turn an unavailable status into an available one, and it never grants anything.

The switches restrict HCG Terminal only:

- They do not change iOS permissions.
- They do not remove or disable a jailbreak.
- They do not undo earlier filesystem changes.
- Turning a switch off deletes nothing. Files, saved hosts, keys, passwords and session history are kept.

## Switches

| Switch | Default | Needs | Enforced in |
|---|---|---|---|
| Local workspace commands | On | — | `VanillaExecutionProvider.makeSession`; `BuiltinShellSession`, checked before every command line (`exit` always works) |
| Files you choose (import/export) | On | — | `FileWorkspace.importItem`, `exportURL` |
| Unleashed features (master) | On | Unleashed build | Prerequisite of every Unleashed switch below |
| Local shell execution | On | Unleashed features | `UnleashedExecutionProvider.makeSession`; `LocalProcessSession.start` and every `send` (input is dropped with a notice); `UnleashedOperations` (programs, shell test) |
| Localhost SSH fallback | On | Unleashed features | `SSHConnection.connect` with `requiredAccess: [.localhostSSH]` (before any network activity); only 127.0.0.1, localhost or ::1 |
| Expanded filesystem browsing | On | Unleashed features | `HostFileSystem.list`, `readTail`, `readText` |
| Filesystem modifications | **Off** | browsing | All `HostFileSystem` changes and the write test; listings report nothing writable while off |
| Package management | On | Unleashed features | Inventory: `PackageManagerClient.inventory` (reads the dpkg status file, no shell needed). Changes: `authorizedCommand` also requires Local shell execution. |
| Process inspection | On | — | `ProcessInspector.listProcesses` (returns *disabled* without reading the table) |
| Privileged operations | **Off** | shell | `AuthorizationGate.decide`: requests are refused without asking while off. Covers commands typed in a shell and programs launched from Unleashed Tools. |
| Remote SSH | On | — | `SSHConnection.connect` (before any network activity), `stream`, `openSession`; every SFTP request (`SFTPClient`) |
| Remote builds and tests | On | SSH | `BuildOrchestrator.run` (recorded as *could not start*; nothing is sent). Each host also has its own **Allow builds and tests** setting, checked there too. |

Turning a prerequisite off also stops its dependents. The dependent keeps your setting and is shown as "Inactive: needs …".

## Turning a switch off while something runs

The change is explained first, in a sheet listing every affected session and build:

- **Keep As Is** cancels the change.
- **Turn Off and Stop** applies it with a controlled stop. The result reports only what is known:

| Affected | What happens | What is reported |
|---|---|---|
| Built-in command session | Ended | "Ended" |
| Local shell (Unleashed) | SIGHUP, then SIGKILL; the exit is waited for (bounded) | "exit confirmed", or "exit not confirmed" |
| Loopback terminal service, SSH session | Channel closed, connection closed | "Disconnected… may still be running… not verified" |
| Running build | Channel closed, TERM sent to the remote process group | "Whether it stopped is shown in the build log, not assumed" |

Ended sessions stay in the list, with their scrollback, until you close them. Switching the local mode (Vanilla ↔ Unleashed) never disconnects SSH sessions or stops builds.

Turning on expanded write or privileged operations shows a short explanation and needs confirmation.

## Tests

Service-level enforcement, persistence, prerequisites, unavailable capabilities and active-session transitions are covered by:

- `Tests/TerminalCoreTests/AccessPolicyTests.swift`
- `Tests/ExecutionProviderTests/AccessEnforcementTests.swift`
- `Tests/RemoteSSHTests/SSHAccessTests.swift`
- `BuildAccessTests` in `Tests/DeveloperToolsTests/DeveloperToolsTests.swift`
- `Tests/TerminalUITests/AccessTransitionTests.swift`
