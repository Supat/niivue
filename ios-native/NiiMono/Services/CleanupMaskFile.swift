//
//  CleanupMaskFile.swift — import and export of the hand-painted noise mask and scan repair:
//  a uint8 NIfTI on the scan's own grid and orientation (its voxels in the file's index order
//  under a copy of the scan's header), so the same marks can be applied to another image of
//  the acquisition — the Dixon water, fat, in-phase or opposed-phase variant shares the grid.
//  What the file is travels as JSON in a header extension ({"niimono": "noise" | "repair"}),
//  so a noise mask can't be imported as a repair by mistake.
//

import Accelerate
import Foundation

enum CleanupMaskFile {
    enum Kind: String, Codable, Hashable {
        case noise, repair
        var title: String { self == .noise ? "noise mask" : "scan repair" }
    }
    private struct Payload: Codable { var niimono: Kind }

    /// The value every noise voxel takes (the editor's single "Noise" label).
    static let noiseValue: UInt8 = 1
    /// The repair paints kept on import: 1 band, 2–4 blemish by plane, 5 cut (ScanRepair).
    static let repairValues: ClosedRange<UInt8> = 1...5

    enum Error: LocalizedError {
        case wrongKind(Kind), empty
        var errorDescription: String? {
            switch self {
            case .wrongKind(let k): return "this file is a \(k.title) export, not a \((k == .noise ? Kind.repair : .noise).title)"
            case .empty: return "no marked voxels in the file"
            }
        }
    }

    /// The .nii.gz bytes for `mask` on `volume`'s file grid, tagged with its kind.
    static func export(_ mask: LabelVolume, kind: Kind, like volume: NiftiVolume) -> Data {
        NIfTI.labelFile(mask, like: volume, json: try? JSONEncoder().encode(Payload(niimono: kind)))
    }

    struct Imported {
        var mask: LabelVolume
        /// Voxels marked after normalising, and nonzero voxels dropped for not being a repair paint.
        var marked: Int, ignored: Int
    }

    /// A mask file on `volume`'s grid, read through a security scope when `scoped`.
    static func read(from url: URL, scoped: Bool, kind: Kind, volume: NiftiVolume) throws -> Imported {
        let accessed = scoped && url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let raw = try Data(contentsOf: url)
        return try decode(NIfTI.isGzip(raw) ? try NIfTI.gunzip(raw) : raw, kind: kind, volume: volume)
    }

    /// A label file's bytes as a `kind` mask on `volume`'s grid. Noise: every nonzero voxel is
    /// noise. Repair: the paint values are kept, any other nonzero value is dropped (counted
    /// in `ignored`). A file our export tagged as the other kind, or one with nothing marked,
    /// is refused.
    static func decode(_ d: Data, kind: Kind, volume: NiftiVolume) throws -> Imported {
        let grid = try NIfTI.parseLabels(d)
        guard grid.dims == volume.dims else { throw NiftiError.gridMismatch(grid.dims, volume.dims) }
        if let stated = storedKind(in: d), stated != kind { throw Error.wrongKind(stated) }
        // One vImage pass each: a histogram for the counts, a 256-entry table for the remap.
        var table = [UInt8](repeating: 0, count: 256)
        switch kind {
        case .noise: for v in 1...255 { table[v] = noiseValue }
        case .repair: for v in repairValues { table[Int(v)] = v }
        }
        var hist = [vImagePixelCount](repeating: 0, count: 256)
        var data = grid.data
        data.withUnsafeMutableBytes { p in
            var b = vImage_Buffer(data: p.baseAddress, height: 1, width: vImagePixelCount(p.count), rowBytes: p.count)
            hist.withUnsafeMutableBufferPointer { h in _ = vImageHistogramCalculation_Planar8(&b, h.baseAddress!, 0) }
            _ = vImageTableLookUp_Planar8(&b, &b, table, 0)
        }
        var marked = 0, ignored = 0, maxLabel = 0
        for v in 1...255 where hist[v] > 0 {
            if table[v] != 0 { marked += Int(hist[v]); maxLabel = max(maxLabel, Int(table[v])) } else { ignored += Int(hist[v]) }
        }
        guard marked > 0 else { throw Error.empty }
        return Imported(mask: LabelVolume(dims: grid.dims, data: data, maxLabel: maxLabel), marked: marked, ignored: ignored)
    }

    /// The kind our export wrote into the header extension; nil for any other file.
    static func storedKind(in d: Data) -> Kind? {
        guard d.count >= 352 else { return nil }
        let voxOffset = d.withUnsafeBytes { Int(Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 108, as: UInt32.self)))) }
        guard let json = NIfTI.embeddedJSON(in: d, voxOffset: voxOffset) else { return nil }
        return (try? JSONDecoder().decode(Payload.self, from: json))?.niimono
    }
}
