#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

/// Settings → Capabilities & Access. For every switch it shows three separate facts:
/// whether the code is in this build, what this device allows this app (detected), and what you
/// chose. The switch never changes the detected status; it can only stop HCG Terminal from using
/// what is there.
struct CapabilitiesAccessView: View {
    @Environment(TerminalAppModel.self) private var model

    private let groups: [(String, [AccessControl])] = [
        ("On this device · built in", [.workspaceCommands, .externalFiles]),
        ("On this device · Unleashed", [.localShell, .expandedFileRead, .expandedFileWrite, .packageManagement, .privilegedOperations]),
        ("On this device · system", [.processInspection]),
        ("Remote development", [.remoteSSH, .remoteBuilds]),
    ]

    var body: some View {
        List {
            Section {
                Text(AccessCopy.scope)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = model.accessChangeOutcome {
                Section {
                    Label(outcome, systemImage: "info.circle")
                        .font(.footnote)
                    Button("Dismiss") { model.accessChangeOutcome = nil }
                } header: { Text("Last change") }
            }
            ForEach(groups, id: \.0) { group in
                Section {
                    ForEach(group.1) { control in
                        AccessControlRow(control: control)
                    }
                } header: { Text(group.0) }
            }
            Section {
                Button("Restore Default Settings") { Task { await model.resetAccessToDefaults() } }
            } footer: {
                Text("Defaults: everything on except expanded filesystem writing and privileged operations.")
            }
        }
        .navigationTitle("Capabilities & Access")
        .hcgScreenBackground()
        .refreshable { await model.refreshCapabilities() }
    }
}

enum AccessCopy {
    static let scope = "These switches limit what HCG Terminal itself does. They do not change iOS permissions, do not remove or disable a jailbreak and do not undo earlier changes to files. Turning a switch off keeps your files, saved hosts, keys, passwords and session history. Turning one on never grants anything the device does not already allow."
}

/// One switch: your setting, plus what the build and the device allow.
struct AccessControlRow: View {
    @Environment(TerminalAppModel.self) private var model
    let control: AccessControl

    private var included: Bool {
        !(control.requiresUnleashedBackend && model.dependencies.distribution == .standard)
    }

    var body: some View {
        let isOn = model.accessSettings.isOn(control)
        let blocker = model.dependencies.access.blockingPrerequisite(of: control)
        VStack(alignment: .leading, spacing: 8) {
            if included {
                Toggle(isOn: Binding(
                    get: { model.accessSettings.isOn(control) },
                    set: { newValue in Task { await model.requestAccessChange(control, enabled: newValue) } }
                )) {
                    Label(control.title, systemImage: control.symbolName)
                        .font(.body.weight(.semibold))
                }
                .frame(minHeight: 44)
            } else {
                // No switch for code that is not in this build: a switch (even a disabled one in
                // the "on" position) would suggest the capability is enabled.
                Label(control.title, systemImage: control.symbolName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(HCGPalette.muted)
                    .frame(minHeight: 44, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { facts(isOn: isOn, blocker: blocker) }
                VStack(alignment: .leading, spacing: 6) { facts(isOn: isOn, blocker: blocker) }
            }

            NavigationLink {
                AccessControlDetailView(control: control)
            } label: {
                Text("When on, when off, prerequisites")
                    .font(.footnote)
            }
            .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func facts(isOn: Bool, blocker: AccessControl?) -> some View {
        if !included {
            Text("Not in this build: only the Unleashed app contains it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if let availability = model.detectedAvailability(for: control) {
                StatusChip(availability: availability)
                    .accessibilityLabel("On this device: \(availability.label)")
            } else {
                Text("Uses the system file picker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isOn, let blocker {
                Label("Inactive: needs \(blocker.title)", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HCGPalette.warn)
            } else if !isOn {
                Label("Off by your choice", systemImage: "pause.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HCGPalette.muted)
            }
        }
    }
}

/// Full explanation of one switch.
struct AccessControlDetailView: View {
    @Environment(TerminalAppModel.self) private var model
    let control: AccessControl

    var body: some View {
        List {
            Section {
                if !(control.requiresUnleashedBackend && model.dependencies.distribution == .standard) {
                    Toggle(isOn: Binding(
                        get: { model.accessSettings.isOn(control) },
                        set: { newValue in Task { await model.requestAccessChange(control, enabled: newValue) } }
                    )) { Text("Allow HCG Terminal to use this") }
                }
                LabeledContent("In this build", value: control.requiresUnleashedBackend && model.dependencies.distribution == .standard ? "Not included" : "Included")
                if let availability = model.detectedAvailability(for: control) {
                    LabeledContent("On this device") { StatusChip(availability: availability) }
                    Text(availability.reason).font(.footnote).foregroundStyle(.secondary)
                    if let remedy = availability.remedy, !availability.isUsable {
                        Label(remedy, systemImage: "lightbulb").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let effective = model.effectiveAvailability(for: control) {
                    LabeledContent("Result") { StatusChip(availability: effective) }
                }
            } header: { Text("Status") } footer: {
                Text("“On this device” comes from read-only checks and real use. Your setting can only turn a usable capability off; it never makes an unavailable one usable.")
            }

            Section("When on") { Text(control.whenOn).font(.callout) }
            Section("When off") { Text(control.whenOff).font(.callout) }

            Section("Prerequisites") {
                if control.prerequisites.isEmpty {
                    Text("None.").foregroundStyle(.secondary)
                }
                ForEach(control.prerequisites) { prerequisite in
                    LabeledContent(prerequisite.title, value: model.accessSettings.isOn(prerequisite) ? "On" : "Off")
                }
                if control.requiresUnleashedBackend {
                    Text("Also needs the Unleashed build and a device that allows it (see Unleashed environment in Diagnostics).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !control.dependents.isEmpty {
                Section {
                    ForEach(control.dependents) { dependent in Text(dependent.title) }
                } header: { Text("Stops working when this is off") }
            }

            Section("Open sessions and builds") {
                Text(control.activeSessionEffect).font(.callout)
            }

            Section { Text(AccessCopy.scope).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(control.title)
        .navigationBarTitleDisplayMode(.inline)
        .hcgScreenBackground()
    }
}

/// Explains a change before it is applied; offers cancelling it or applying it with a
/// controlled stop.
struct AccessChangeSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AccessChangeRequest

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.enabled ? request.control.whenOn : request.control.whenOff).font(.callout)
                    if let caution = request.caution {
                        Label(caution, systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(HCGPalette.warn)
                    }
                }
                let others = request.newlyDisabled.filter { $0 != request.control }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { Text($0.title) }
                    } header: { Text("Also stops, because it needs this") }
                }
                if !request.sessions.isEmpty {
                    Section {
                        ForEach(request.sessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title).font(.body.weight(.semibold))
                                TargetBadge(target: session.target)
                                Text(session.consequence).font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: { Text("Open sessions that will end") } footer: {
                        Text("Ended sessions stay in the list with their scrollback until you close them.")
                    }
                }
                if request.stopsRunningBuild {
                    Section("Running build") {
                        Text(AccessControl.remoteBuilds.activeSessionEffect).font(.footnote)
                    }
                }
                Section { Text(AccessCopy.scope).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(request.enabled ? "Turn On \(request.control.title)?" : "Turn Off \(request.control.title)?")
            .navigationBarTitleDisplayMode(.inline)
            .hcgScreenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep As Is") { model.cancelAccessChange(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, role: request.stopsSomething ? .destructive : nil) {
                        Task { await model.confirmAccessChange(); dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var confirmTitle: String {
        if request.enabled { return "Turn On" }
        return request.stopsSomething ? "Turn Off and Stop" : "Turn Off"
    }
}
#endif
