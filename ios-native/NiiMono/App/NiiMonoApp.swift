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
