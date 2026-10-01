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
        // The launch screen in front of the system document browser. The browser's content
        // is out of process on iPadOS 26 and its folder can't be steered (revealDocument(at:)
        // was tried), so the way back to the last scan is a one-tap action here.
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
            Button("Open \(LastLocation.name ?? url.lastPathComponent)", systemImage: "clock.arrow.circlepath") {
                DocumentOpener.open(url)
            }
            .task { // `-openLast YES` for checks, once the browser is up
                guard UserDefaults.standard.bool(forKey: "openLast"), !DocumentOpener.checked else { return }
                DocumentOpener.checked = true // the launch screen builds its actions more than once
                try? await Task.sleep(for: .seconds(3))
                DocumentOpener.open(url)
            }
        } else {
            // An actions block with nothing in it falls back to a "Create Document" button,
            // which a viewer has no use for.
            Text("Open a scan from the browser below").foregroundStyle(.secondary)
        }
    }
}

/// Opens a file in this app's DocumentGroup. SwiftUI's openDocument action is macOS-only, and
/// UIApplication.open(_:) refuses file URLs on a device (LSApplicationWorkspaceErrorDomain 115;
/// it only works in the simulator), so the URL is handed to the launch screen's document
/// browser delegate, exactly as the browser does when a file is picked in it.
@MainActor
enum DocumentOpener {
    static var checked = false

    static func open(_ url: URL) {
        let roots = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).compactMap(\.rootViewController)
        let found = roots.lazy.compactMap(browser(in:)).first
        guard let browser = found, let delegate = browser.delegate else {
            MemoryLog.log.notice("open last scan: \(found == nil ? "no document browser" : "browser has no delegate", privacy: .public)")
            return
        }
        // A bookmarked file outside the app's containers is only readable inside its security
        // scope. ponytail: the scope is never released (the document reads the file, its
        // sidecar and companions for as long as it's open); one kernel extension per tap.
        _ = url.startAccessingSecurityScopedResource()
        delegate.documentBrowser?(browser, didPickDocumentsAt: [url])
    }

    private static func browser(in controller: UIViewController) -> UIDocumentBrowserViewController? {
        if let browser = controller as? UIDocumentBrowserViewController { return browser }
        let next = controller.children + (controller.presentedViewController.map { [$0] } ?? [])
        return next.lazy.compactMap(browser(in:)).first
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
