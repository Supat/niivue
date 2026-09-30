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
            DocumentView(data: file.document.data, fileURL: file.fileURL)
        }
    }
}

extension UTType {
    static let nifti = UTType(importedAs: "gov.nih.nifti-1")
}

struct MRIDocument: FileDocument {
    // ponytail: .nii.gz has no type of its own (the system sees only ".gz"), so every
    // gzip is openable and non-NIfTI ones fail with the reader's error in DocumentView.
    static let readableContentTypes: [UTType] = [.nifti, .gzip]
    /// Raw file bytes. Decoding happens in DocumentView, not here: the system shows nothing
    /// until this initializer returns, so a slow init looks like the pick was ignored.
    /// ponytail: the bytes stay in memory beside the decoded volume; drop them via a
    /// ReferenceFileDocument if memory gets tight on huge uncompressed files.
    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported) // viewer only
    }
}
