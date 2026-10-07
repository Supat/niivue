//
//  SidecarStore.swift — reads and writes a scan's sidecar folder. Beside the scan when the
//  folder is writable (documents in the app's own container), otherwise in the app's
//  Application Support, keyed by the scan's name and size.
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
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let sidecars = support.appendingPathComponent("Sidecars", isDirectory: true)
        let fallback = sidecars.appendingPathComponent(Self.key(for: scanURL), isDirectory: true)
        if Self.hasSettings(beside) {
            folder = beside; besideScan = true
        } else if Self.hasSettings(fallback) {
            folder = fallback; besideScan = false
        } else if let earlier = Self.earlierFallback(for: scanURL, in: sidecars) {
            // Keys used to include the scan's modification date, which iCloud can change
            // under an open document: the reopened scan then found no sidecar and started
            // empty. Take the newest one for this file name instead.
            folder = earlier; besideScan = false
        } else if fm.isWritableFile(atPath: scanURL.deletingLastPathComponent().path) {
            folder = beside; besideScan = true
        } else {
            folder = fallback; besideScan = false
        }
    }

    /// Name and size; not the modification date, which iCloud may change.
    private static func key(for url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return "\(url.lastPathComponent)-\(v?.fileSize ?? 0)".replacingOccurrences(of: "/", with: "_")
    }

    private static func hasSettings(_ folder: URL) -> Bool {
        let fm = FileManager.default, file = folder.appendingPathComponent(settingsFile)
        if fm.fileExists(atPath: file.path) { return true }
        // Evicted from the device by iCloud: listed as `.settings.json.icloud`.
        return fm.fileExists(atPath: folder.appendingPathComponent(".\(settingsFile).icloud").path)
    }

    /// The fallback sidecar for a scan of this name with the most saved maps (a drawing lost
    /// to a key change leaves a fresher sidecar without it), the most recent of those (older
    /// keys carried a size and date that may no longer match).
    private static func earlierFallback(for scanURL: URL, in sidecars: URL) -> URL? {
        let prefix = scanURL.lastPathComponent.replacingOccurrences(of: "/", with: "_") + "-"
        let fm = FileManager.default
        let candidates = ((try? fm.contentsOfDirectory(at: sidecars, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && hasSettings($0) }
        func saved(_ u: URL) -> Date {
            (try? u.appendingPathComponent(settingsFile).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        func maps(_ u: URL) -> Int {
            ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { $0.hasSuffix(".nii.gz") || $0.hasSuffix(".nii.gz.icloud") }.count
        }
        return candidates.max { (maps($0), saved($0)) < (maps($1), saved($1)) }
    }

    /// The file's bytes, downloading it first if iCloud has evicted it (waits up to ~30 s).
    static func read(_ url: URL) -> Data? {
        if let d = try? Data(contentsOf: url) { return d }
        guard (try? FileManager.default.startDownloadingUbiquitousItem(at: url)) != nil else { return nil }
        for _ in 0..<60 {
            Thread.sleep(forTimeInterval: 0.5)
            if let d = try? Data(contentsOf: url) { return d }
        }
        return nil
    }

    var settingsURL: URL { folder.appendingPathComponent(Self.settingsFile) }
    func mapURL(_ slot: String) -> URL { folder.appendingPathComponent("\(slot).nii.gz") }
    var exists: Bool { Self.hasSettings(folder) }

    func loadSettings() -> SidecarSettings? {
        guard let data = Self.read(settingsURL) else { return nil }
        return try? JSONDecoder().decode(SidecarSettings.self, from: data)
    }

    func save(_ settings: SidecarSettings) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: settingsURL, options: .atomic)
    }

    func saveMap(_ map: SegmentationMap?, slot: String, voxelSize: (Float, Float, Float)) throws {
        try saveLabels(map?.labels, slot: slot, voxelSize: voxelSize)
    }

    /// A label volume as `<slot>.nii.gz`; nil removes the file.
    func saveLabels(_ labels: LabelVolume?, slot: String, voxelSize: (Float, Float, Float)) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = mapURL(slot)
        guard let labels else { try? FileManager.default.removeItem(at: url); return }
        try NIfTI.labelFile(labels, voxelSize: voxelSize).write(to: url, options: .atomic)
    }

    func loadLabels(slot: String, volume: NiftiVolume) -> LabelVolume? {
        guard let data = Self.read(mapURL(slot)),
              let labels = try? NIfTI.parseLabels(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data),
              labels.dims == volume.dims else { return nil }
        return labels
    }

    func loadMap(slot: String, name: String, volume: NiftiVolume) -> SegmentationMap? {
        guard let data = Self.read(mapURL(slot)),
              let labels = try? NIfTI.parseLabels(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data),
              labels.dims == volume.dims else { return nil }
        return SegmentationMap(labels: labels, name: name, volume: volume)
    }

    /// A profile photo's bytes; nil data removes the file.
    func savePhoto(_ data: Data?, name: String) throws {
        let url = folder.appendingPathComponent(name)
        guard let data else { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func loadPhoto(_ name: String) -> Data? { Self.read(folder.appendingPathComponent(name)) }

    // MARK: Drawing backup

    /// The drawing again, with its label names inside (an export, see CustomSegmentationFile),
    /// and the one before it: a way back if the map slots are ever lost.
    var drawingBackupURL: URL { folder.appendingPathComponent("drawing.nii.gz") }

    func saveDrawingBackup(_ data: Data) throws {
        let fm = FileManager.default, prev = folder.appendingPathComponent("drawing.prev.nii.gz")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: drawingBackupURL.path) {
            try? fm.removeItem(at: prev)
            try? fm.moveItem(at: drawingBackupURL, to: prev)
        }
        try data.write(to: drawingBackupURL, options: .atomic)
    }

    func delete() { try? FileManager.default.removeItem(at: folder) }
}
