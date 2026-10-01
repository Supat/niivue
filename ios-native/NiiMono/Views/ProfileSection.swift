//
//  ProfileSection.swift — the subject's photos from the top, bottom, front, back, left and
//  right, picked from the photo library or Files and remembered in the sidecar.
//

import PhotosUI
import SwiftUI

struct ProfileSection: View {
    let model: ProfileViewModel

    var body: some View {
        Section("Profile") {
            ForEach(ProfileView.allCases) { view in
                ProfilePhotoRow(model: model, view: view)
            }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Text("Photos of the subject from each side. They are saved in the sidecar with the scan's other settings.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct ProfilePhotoRow: View {
    let model: ProfileViewModel
    let view: ProfileView
    @State private var picked: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var choosingFile = false

    var body: some View {
        let photo = model.photos[view]
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                HStack(spacing: 14) {
                    if photo != nil {
                        Button("Remove", role: .destructive) { Task { await model.set(nil, for: view) } }
                    }
                    Menu(photo == nil ? "Choose…" : "Change…") {
                        Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                        Button("Files", systemImage: "folder") { choosingFile = true }
                    }
                }
                .buttonStyle(.borderless) // separate tap targets inside one form row
            } label: {
                HStack(spacing: 6) {
                    Text(view.rawValue)
                    if model.landmarks[view]?.hasBody == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityLabel("Body detected")
                    }
                }
            }
            if let photo {
                Image(uiImage: photo)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel("\(view.rawValue) photo")
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $picked, matching: .images)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                Task {
                    // Read off the main thread, inside the picked file's security scope.
                    let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try? Data(contentsOf: url)
                    }.value
                    await use(data, source: "file")
                }
            case .failure(let error): model.setError(error.localizedDescription)
            }
        }
        .onChange(of: picked) {
            guard let item = picked else { return }
            picked = nil // so the same photo can be picked again after a removal
            Task { await use(try? await item.loadTransferable(type: Data.self), source: "photo") }
        }
    }

    private func use(_ data: Data?, source: String) async {
        guard let data, let image = UIImage(data: data) else {
            model.setError("Couldn't read that \(source).")
            return
        }
        await model.set(image, for: view)
    }
}
