//
//  DocumentView.swift — opens immediately with a progress indicator, decodes the volume
//  off the main thread, then swaps in the viewer (or the reader's error).
//

import SwiftUI
import UIKit

struct DocumentView: View {
    let document: MRIDocument
    let fileURL: URL?
    /// The decoded scan's view model, made once: built inline in `body`, a throwaway one was
    /// made (reading the BIDS JSON beside the scan) at every re-evaluation, ViewerView's
    /// @State keeping only the first.
    @State private var result: Result<ViewerViewModel, Error>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch result {
            case .success(let model):
                ViewerView(model: model)
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
        // The 3D textures kept for the next 3D view (see RenderCache) belong to this scan.
        .onDisappear { RenderCache.clear() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in RenderCache.clear() }
        .task {
            guard result == nil, let data = document.data else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                Result { try NIfTI.parse(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data) }
            }.value
            result = decoded.map { ViewerViewModel(volume: $0, fileURL: fileURL) }
            document.data = nil // decoded: the file's bytes are no longer needed
        }
    }
}
