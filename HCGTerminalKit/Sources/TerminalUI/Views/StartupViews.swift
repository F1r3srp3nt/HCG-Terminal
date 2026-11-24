#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCore
import UIKit

/// The app's first view. It shows the recovery screen after a failed launch, otherwise the app.
public struct LaunchRootView: View {
    @State private var controller: LaunchController

    public init(controller: LaunchController) {
        _controller = State(initialValue: controller)
    }

    public var body: some View {
        switch controller.stage {
        case .recovery(let previous):
            StartupRecoveryView(previous: previous, controller: controller)
        case .running(let model):
            RootView(model: model, launch: controller)
        }
    }
}

/// Deliberately plain SwiftUI: no app model, no design-system views, no environment scan. It
/// must open even when whatever stopped the earlier launch still fails.
struct StartupRecoveryView: View {
    let previous: StartupJournal.PreviousLaunch
    let controller: LaunchController
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("HCG Terminal did not finish starting last time", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(previous.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                } footer: {
                    Text("Nothing was changed on your device. iOS also keeps its own crash report: Settings › Privacy & Security › Analytics & Improvements › Analytics Data, entries starting with the app's name.")
                }

                Section {
                    Button {
                        controller.start(safeMode: true)
                    } label: {
                        Label("Start in Safe Mode", systemImage: "shield.lefthalf.filled")
                    }
                    Button {
                        controller.start(safeMode: false)
                    } label: {
                        Label("Start Normally", systemImage: "play.fill")
                    }
                } footer: {
                    Text("Safe Mode opens the app without detecting the jailbreak environment and without resuming background jobs. You can run each of them afterwards from the Safe Mode banner.")
                }

                Section("Startup report") {
                    ShareLink(item: controller.reportText, subject: Text("HCG Terminal startup report")) {
                        Label("Share Startup Report", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showLog.toggle()
                    } label: {
                        Label(showLog ? "Hide Log" : "Show Log", systemImage: "doc.text.magnifyingglass")
                    }
                    if showLog {
                        Text(controller.reportText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Startup Recovery")
        }
    }
}

/// Shown above the app while Safe Mode is on.
struct SafeModeBanner: View {
    let model: TerminalAppModel
    @State private var running = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
            VStack(alignment: .leading, spacing: 2) {
                Text("Safe Mode").font(.subheadline.weight(.semibold))
                Text("Environment detection and background jobs are off.").font(.caption)
            }
            Spacer(minLength: 8)
            Button(running ? "Running…" : "Run Detection") {
                running = true
                Task {
                    await model.runSkippedStartupSteps()
                    running = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(.primary)
        // Opaque, so it never shows the header artwork through it.
        .background {
            ZStack {
                Rectangle().fill(Color(uiColor: .systemBackground))
                Rectangle().fill(Color.orange.opacity(0.22))
            }
            .ignoresSafeArea(edges: .top)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Diagnostics row: this launch's startup log, shareable.
struct StartupLogSection: View {
    @State private var showLog = false

    var body: some View {
        Section {
            let report = StartupJournal.shared?.reportText() ?? "Startup log unavailable."
            ShareLink(item: report, subject: Text("HCG Terminal startup report")) {
                Label("Share Startup Report", systemImage: "square.and.arrow.up")
            }
            Button {
                showLog.toggle()
            } label: {
                Label(showLog ? "Hide Startup Log" : "Show Startup Log", systemImage: "list.bullet.rectangle")
            }
            if showLog {
                Text(report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("Startup")
        } footer: {
            Text("Each startup step, the app version and where its files are. It contains no passwords, keys, tokens, host names or commands.")
        }
    }
}
#endif
