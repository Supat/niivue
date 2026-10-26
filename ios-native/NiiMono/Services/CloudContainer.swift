//
//  CloudContainer.swift — Makes "iCloud Drive › NiiMono" exist. Files lists an app's
//  container only once its Documents folder holds something, and this app never writes
//  there on its own (it reads scans where it finds them and puts sidecars beside them), so
//  a fresh container would stay invisible forever. On launch, an empty or missing Documents
//  folder gets a short text file explaining what the folder is for.
//

import Foundation

enum CloudContainer {
    static let placeholderName = "Put scans here.txt"
    private static let placeholderText = """
        This folder belongs to NiiMono.

        Scans (.nii, .nii.gz) kept here open from the app's document browser and sync \
        across your devices through iCloud Drive. NiiMono writes each scan's settings in a \
        small sidecar file next to it, so keep a scan and its sidecar together.

        This file can be deleted once there is a scan in the folder.
        """

    /// Creates the container's Documents folder and a placeholder in it when the folder is
    /// missing or empty. Runs off the main thread: the container lookup can block while the
    /// system sets the container up on first use. Does nothing when iCloud is signed out.
    static func seedIfEmpty() {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let container = fm.url(forUbiquityContainerIdentifier: nil) else {
                MemoryLog.log.notice("icloud container: unavailable (signed out or not provisioned)")
                return
            }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            do {
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
                // Evicted files are listed as `.name.icloud`, so a folder of them is not empty.
                let contents = try fm.contentsOfDirectory(atPath: documents.path)
                guard contents.isEmpty else { return }
                try placeholderText.write(to: documents.appendingPathComponent(placeholderName),
                                          atomically: true, encoding: .utf8)
                MemoryLog.log.notice("icloud container: wrote placeholder")
            } catch {
                MemoryLog.log.notice("icloud container: seed failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
