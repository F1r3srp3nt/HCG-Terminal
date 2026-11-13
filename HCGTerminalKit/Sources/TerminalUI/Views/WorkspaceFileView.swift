#if canImport(UIKit) && canImport(SwiftUI)
import FileWorkspace
import QuickLook
import SwiftUI

/// Rich documents are previewed by the system, never re-saved as plain text.
struct WorkspaceFileView: View {
    @Environment(TerminalAppModel.self) private var model
    let path: WorkspacePath
    @State private var previewURL: URL?
    @State private var error: String?
    private var usesPreview: Bool {
        ["pdf", "png", "jpg", "jpeg", "heic", "gif", "tiff", "doc", "docx", "rtf", "pptx", "xlsx"]
            .contains((path.name as NSString).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if !usesPreview {
                TextFileEditor(path: path)
            } else if let previewURL {
                WorkspaceQuickLook(url: previewURL)
                    .navigationTitle(path.name)
                    .navigationBarTitleDisplayMode(.inline)
            } else if let error {
                HCGEmptyState("Cannot Preview", systemImage: "doc.questionmark", description: Text(error))
            } else { ProgressView().tint(HCGPalette.accentPrimary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background { HCGBackdrop() }
        .task {
            guard usesPreview else { return }
            do { previewURL = try model.dependencies.workspace.url(for: path) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct WorkspaceQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
#endif
