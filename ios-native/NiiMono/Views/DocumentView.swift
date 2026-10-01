//
//  DocumentView.swift — opens immediately with a progress indicator, decodes the volume
//  off the main thread, then swaps in the viewer (or the reader's error).
//

import SwiftUI

struct DocumentView: View {
    let document: MRIDocument
    let fileURL: URL?
    @State private var result: Result<NiftiVolume, Error>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch result {
            case .success(let volume):
                ViewerView(model: ViewerViewModel(volume: volume, fileURL: fileURL))
            case .failure(let error):
                ContentUnavailableView("Can’t Open File", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            case nil:
                ProgressView("Opening…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .toolbarColorScheme(.dark, for: .navigationBar)
            }
        }
        .environment(\.colorScheme, result == nil ? .dark : colorScheme)
        .task {
            guard result == nil, let data = document.data else { return }
            result = await Task.detached(priority: .userInitiated) {
                Result { try NIfTI.parse(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data) }
            }.value
            document.data = nil // decoded: the file's bytes are no longer needed
        }
    }
}
