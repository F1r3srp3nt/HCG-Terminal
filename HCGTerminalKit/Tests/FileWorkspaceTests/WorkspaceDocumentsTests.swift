import FileWorkspace
import Foundation
import XCTest

final class WorkspaceDocumentsTests: XCTestCase {
    var root: URL!
    var outside: URL!
    var workspace: FileWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-doc-\(UUID().uuidString)")
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        workspace = try FileWorkspace(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    func testImportConflictPolicies() throws {
        let source = outside.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: source)
        try workspace.write("old", to: WorkspacePath("/home/report.txt"))

        XCTAssertEqual(workspace.conflicts(importing: [source], into: .home), ["report.txt"])
        XCTAssertThrowsError(try workspace.importItem(from: source, into: .home, policy: .fail)) { error in
            XCTAssertEqual(error as? DocumentError, .conflict("report.txt"))
        }
        XCTAssertEqual(try workspace.importItem(from: source, into: .home, policy: .skip), .skipped("report.txt"))
        XCTAssertEqual(try workspace.readText(WorkspacePath("/home/report.txt")), "old")

        XCTAssertEqual(try workspace.importItem(from: source, into: .home, policy: .keepBoth), .keptBoth(try WorkspacePath("/home/report 2.txt")))
        XCTAssertEqual(try workspace.readText(WorkspacePath("/home/report 2.txt")), "new")
        XCTAssertEqual(workspace.uniqueName(for: "report.txt", in: .home), "report 3.txt")

        XCTAssertEqual(try workspace.importItem(from: source, into: .home, policy: .replace), .replaced(try WorkspacePath("/home/report.txt")))
        XCTAssertEqual(try workspace.readText(WorkspacePath("/home/report.txt")), "new")
    }

    func testImportFolder() throws {
        let folder = outside.appendingPathComponent("My Project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("print(1)".utf8).write(to: folder.appendingPathComponent("src/main.swift"))
        XCTAssertEqual(try workspace.importItem(from: folder, into: .projects, policy: .fail), .imported(try WorkspacePath("/projects/My Project")))
        XCTAssertEqual(try workspace.readText(WorkspacePath("/projects/My Project/src/main.swift")), "print(1)")
    }

    func testTextEditingDetectsChangesOnDisk() throws {
        let path = try WorkspacePath("/home/notes.md")
        try workspace.write("v1", to: path)
        let document = try workspace.openTextDocument(path)
        XCTAssertEqual(document.text, "v1")
        let saved = try workspace.saveTextDocument(document, text: "v2")
        XCTAssertEqual(try workspace.readText(path), "v2")

        // Someone else changes the file (the terminal, or the Files app).
        Thread.sleep(forTimeInterval: 1.1)
        try workspace.write("changed elsewhere!", to: path)
        XCTAssertThrowsError(try workspace.saveTextDocument(saved, text: "v3")) { error in
            XCTAssertEqual(error as? DocumentError, .changedOnDisk("/home/notes.md"))
        }
        XCTAssertEqual(try workspace.readText(path), "changed elsewhere!")
        try workspace.saveTextDocument(saved, text: "v3", overwriteChanges: true)
        XCTAssertEqual(try workspace.readText(path), "v3")
    }

    func testBinaryAndOversizeFilesAreNotOpenedAsText() throws {
        try workspace.write(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]), to: WorkspacePath("/home/image.png"))
        XCTAssertThrowsError(try workspace.openTextDocument(WorkspacePath("/home/image.png"))) { error in
            XCTAssertEqual(error as? DocumentError, .notText("/home/image.png"))
        }
        try workspace.write(Data(repeating: 0x41, count: Int(FileWorkspace.editableTextLimit) + 1), to: WorkspacePath("/home/big.txt"))
        XCTAssertThrowsError(try workspace.openTextDocument(WorkspacePath("/home/big.txt")))
    }

    func testRenameAndCreate() throws {
        let file = try workspace.createItem(named: "untitled.txt", in: .home, directory: false)
        XCTAssertEqual(file.string, "/home/untitled.txt")
        let second = try workspace.createItem(named: "untitled.txt", in: .home, directory: false)
        XCTAssertEqual(second.string, "/home/untitled 2.txt")
        let renamed = try workspace.rename(file, to: "My Notes.txt")
        XCTAssertEqual(renamed.string, "/home/My Notes.txt")
        XCTAssertThrowsError(try workspace.rename(second, to: "My Notes.txt"))
        XCTAssertThrowsError(try workspace.rename(second, to: "../escape"))
        let folder = try workspace.createItem(named: "New Folder", in: .home, directory: true)
        XCTAssertTrue(workspace.isDirectory(folder))
    }
}
