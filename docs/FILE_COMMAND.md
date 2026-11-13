# HCG File Command

File Command is the file-management entry point in the Terminal sidebar and dashboard.
It reuses the workspace and Unleashed filesystem services; it does not create a second
copy of the user's terminal files.

## Included

- Workspace folder navigation, current-folder search, hidden-file toggle, path display.
- Existing create, rename, delete, Files import/export and UTF-8 text editing.
- Quick Look previews for workspace PDFs, images and supported Office/RTF documents.
  Rich documents are preview-only; this is not a Word/PDF editing engine.
- Device locations in Unleashed, including `/` when the actual process can list it.
- Read/write settings enforced by the services, folder/file sizes, folder-first device
  sorting, denied-location errors, and navigation through directory symlinks.
- Full-file UTF-8 editing up to 2 MB; larger device files can show a labelled log tail
  but cannot be edited from that truncated preview.
- Explicit save, protection against accidentally leaving with unsaved device edits,
  and checks for external content changes/deletion before a save.

The workspace's `/` is virtual. Device Root `/` is the real device filesystem, still
subject to the OS's actual permissions. Selecting Unleashed is not an entitlement or
sandbox escape. Other apps' protected/encrypted files may remain inaccessible.
The root scan only lists directory names; it does not recursively scan the phone.

## Save behavior and limits

Device edits retain the existing per-operation approval for protected locations.
A save checks access again after approval, and refuses changed/deleted files. Edits
remain in the editor on failure so the user can copy them before reopening.
Workspace conflict checks also compare contents, catching same-size changes even if
modification times match. Writes use the existing Foundation atomic replacement.
There is no backup/version-history feature, no external file coordination, and no
transactional compare-and-swap against concurrent writers. Do not use this editor to
modify live database files. Device file preview is text-only in this iteration.

## Validation

Added regression tests for oversized device files, stale/deleted documents,
permission revocation during approval, explicit root access, and workspace content
changes with restored timestamps.

This change was prepared in an environment without Swift or Xcode. The tests and
Apple targets have NOT been compiled or run here. Before merging, run:

```sh
cd HCGTerminalKit
swift test --filter 'HostFileSystemTests|WorkspaceDocumentsTests'
```

Then build both iOS variants in Xcode/HCG Executable Maker. On a device, verify:

1. File Command → Documents & Notes → create/edit/save/reopen a text file.
2. Import and preview a PDF/image; verify it is not opened in the plain-text editor.
3. Search and toggle hidden files in both workspace and device directories.
4. On Unleashed, open Device Root if offered, follow a directory symlink, and open a
   denied folder; the denial must not appear as an empty folder.
5. Modify an open file in the terminal before saving in the editor; saving must fail
   without overwriting the terminal's changes.
6. Open a text file larger than 2 MB; Edit must refuse rather than truncate it.
7. Change read/write switches while a file is open; subsequent operations must respect
   the switches. Turning read access off hides device content without deleting files.
8. Edit a file and leave: Save/Discard/Keep Editing must preserve the chosen behavior.

No release, TestFlight upload, or jailbreak installation is part of this change.
