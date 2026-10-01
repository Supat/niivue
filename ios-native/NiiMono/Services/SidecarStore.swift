//
//  SidecarStore.swift — reads and writes a scan's sidecar folder. Beside the scan when the
//  folder is writable (documents in the app's own container), otherwise in the app's
//  Application Support, keyed by the scan's name, size and modification date.
//

import Foundation

struct SidecarStore {
    let folder: URL
    let besideScan: Bool

    static let settingsFile = "settings.json"

    /// The place for `scanURL`'s sidecar: an existing one wherever it is, else beside the
    /// scan if that directory is writable, else the app's own fallback.
    init(for scanURL: URL) {
        let fm = FileManager.default
        let beside = scanURL.deletingLastPathComponent()
            .appendingPathComponent(SegmentationPipeline.tags(of: scanURL)[0] + ".niimono", isDirectory: true) // strips .nii / .nii.gz
        let key = Self.key(for: scanURL)
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let fallback = support.appendingPathComponent("Sidecars", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        if fm.fileExists(atPath: beside.appendingPathComponent(Self.settingsFile).path) {
            folder = beside; besideScan = true
        } else if fm.fileExists(atPath: fallback.appendingPathComponent(Self.settingsFile).path) {
            folder = fallback; besideScan = false
        } else if fm.isWritableFile(atPath: scanURL.deletingLastPathComponent().path) {
            folder = beside; besideScan = true
        } else {
            folder = fallback; besideScan = false
        }
    }

    private static func key(for url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(url.lastPathComponent)-\(v?.fileSize ?? 0)-\(stamp)".replacingOccurrences(of: "/", with: "_")
    }

    var settingsURL: URL { folder.appendingPathComponent(Self.settingsFile) }
    func mapURL(_ slot: String) -> URL { folder.appendingPathComponent("\(slot).nii.gz") }
    var exists: Bool { FileManager.default.fileExists(atPath: settingsURL.path) }

    func loadSettings() -> SidecarSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(SidecarSettings.self, from: data)
    }

    func save(_ settings: SidecarSettings) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: settingsURL, options: .atomic)
    }

    func saveMap(_ map: SegmentationMap?, slot: String, voxelSize: (Float, Float, Float)) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = mapURL(slot)
        guard let map else { try? FileManager.default.removeItem(at: url); return }
        try NIfTI.labelFile(map.labels, voxelSize: voxelSize).write(to: url, options: .atomic)
    }

    func loadMap(slot: String, name: String, volume: NiftiVolume) -> SegmentationMap? {
        guard let data = try? Data(contentsOf: mapURL(slot)),
              let labels = try? NIfTI.parseLabels(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data),
              labels.dims == volume.dims else { return nil }
        return SegmentationMap(labels: labels, name: name, volume: volume)
    }

    func delete() { try? FileManager.default.removeItem(at: folder) }
}
