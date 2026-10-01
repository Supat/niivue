//
//  NiiMonoApp.swift — Preview-style MRI viewer. DocumentGroup supplies the native
//  document browser, title menu and window management; DocumentView takes it from there.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct NiiMonoApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MRIDocument.self) { file in
            DocumentView(document: file.document, fileURL: file.fileURL)
                .onAppear { LastLocation.remember(file.fileURL) }
        }
        // The launch screen in front of the system document browser. The browser itself
        // is out of process on iPadOS 26 (no UIDocumentBrowserViewController to steer:
        // revealDocument(at:) was tried and there is nothing to call it on), so the way
        // back to the last scan is a one-tap action here.
        DocumentGroupLaunchScene("NiiMono") {
            OpenLastScanButton()
        } background: {
            Color.black
        }
    }
}

/// The last opened scan, so it can be reopened with one tap from the launch screen.
enum LastLocation {
    private static let key = "lastOpenedBookmark"
    private static let nameKey = "lastOpenedName"

    static func remember(_ url: URL?) {
        guard let url else { return }
        // Documents from other providers are only reachable inside their security scope.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            UserDefaults.standard.set(try url.bookmarkData(), forKey: key)
            UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
        } catch {
            MemoryLog.log.notice("last location: bookmark failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static var name: String? { UserDefaults.standard.string(forKey: nameKey) }

    static var url: URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

private struct OpenLastScanButton: View {
    var body: some View {
        if let url = LastLocation.url, FileManager.default.fileExists(atPath: url.path) {
            // SwiftUI's openDocument action is macOS-only; handing the file URL to the system
            // routes it back into this app's DocumentGroup, as opening it from Files would.
            Button("Open \(LastLocation.name ?? url.lastPathComponent)", systemImage: "clock.arrow.circlepath") {
                UIApplication.shared.open(url)
            }
        } else {
            // An actions block with nothing in it falls back to a "Create Document" button,
            // which a viewer has no use for.
            Text("Open a scan from the browser below").foregroundStyle(.secondary)
        }
    }
}

extension UTType {
    static let nifti = UTType(importedAs: "gov.nih.nifti-1")
}

/// A reference document so the raw bytes can be dropped once decoded (a whole-body scan is
/// 100–250 MB, memory the segmentation models would rather have).
final class MRIDocument: ReferenceFileDocument {
    // ponytail: .nii.gz has no type of its own (the system sees only ".gz"), so every
    // gzip is openable and non-NIfTI ones fail with the reader's error in DocumentView.
    static let readableContentTypes: [UTType] = [.nifti, .gzip]
    /// Raw file bytes until DocumentView has decoded them. Decoding happens there, not
    /// here: the system shows nothing until this initializer returns, so a slow init
    /// looks like the pick was ignored.
    var data: Data?

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func snapshot(contentType: UTType) throws -> Data { Data() }
    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported) // viewer only
    }
}
