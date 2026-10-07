//
//  mask_file_check.swift — round trip of the noise mask and scan repair exports on real
//  scans: written on the file's own grid and orientation, read back through CleanupMaskFile
//  to the same voxels; repair paint kept and other values dropped; a file of the other kind
//  refused; an empty one refused.
//  Build & run: mkdir -p /tmp/mf && cp spike/mask_file_check.swift /tmp/mf/main.swift &&
//    swiftc -O NiiMono/Models/NIfTI.swift NiiMono/Services/CleanupMaskFile.swift /tmp/mf/main.swift -o /tmp/mf/check && /tmp/mf/check <scan.nii.gz>...
//

import Foundation

func expectThrows(_ what: String, _ body: () throws -> Void) {
    do { try body() } catch { print("  refused as expected (\(what)): \(error.localizedDescription)"); return }
    preconditionFailure("\(what): not refused")
}

for path in CommandLine.arguments.dropFirst() {
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    let v = try NIfTI.parse(NIfTI.isGzip(raw) ? NIfTI.gunzip(raw) : raw)
    precondition(v.header != nil, "header not kept")
    let (nx, ny, nz) = v.dims
    let n = nx * ny * nz

    // Repair: every paint value (1–5) plus a stray 7 and 200, in a pattern that differs
    // along every axis so any transposition or flip shows.
    var repair = [UInt8](repeating: 0, count: n)
    var expectedRepair = [UInt8](repeating: 0, count: n), strays = 0, kept = 0
    for z in 0..<nz { for y in 0..<ny { for x in 0..<nx {
        let i = x + nx * (y + ny * z)
        let k = (x / 7 + 3 * (y / 5) + 11 * (z / 3)) % 9
        let value: UInt8 = k == 0 ? 0 : k <= 5 ? UInt8(k) : k == 6 ? 7 : k == 7 ? 200 : 0
        repair[i] = value
        if (1...5).contains(value) { expectedRepair[i] = value; kept += 1 } else if value != 0 { strays += 1 }
    } } }
    let repairFile = try NIfTI.gunzip(CleanupMaskFile.export(LabelVolume(dims: v.dims, data: repair, maxLabel: 200), kind: .repair, like: v))
    precondition(CleanupMaskFile.storedKind(in: repairFile) == .repair, "repair kind not stored")
    // The exported header keeps the scan's affine (sform/qform bytes 252..<344).
    precondition(repairFile[252..<344] == v.header![252..<344], "affine changed")
    let r = try CleanupMaskFile.decode(repairFile, kind: .repair, volume: v)
    precondition(r.mask.dims == v.dims, "dims \(r.mask.dims) vs \(v.dims)")
    precondition(r.mask.data == expectedRepair, "repair voxels differ")
    precondition(r.marked == kept && r.ignored == strays, "repair counts \(r.marked)/\(r.ignored) vs \(kept)/\(strays)")
    precondition(r.mask.maxLabel == 5, "repair maxLabel \(r.mask.maxLabel)")
    expectThrows("repair export imported as noise") { _ = try CleanupMaskFile.decode(repairFile, kind: .noise, volume: v) }

    // Noise: our export reads back as itself; a foreign binary mask (255s) becomes 1s.
    var noise = [UInt8](repeating: 0, count: n)
    for z in nz / 3..<nz / 2 { for y in 0..<ny / 4 { for x in nx / 5..<nx / 2 { noise[x + nx * (y + ny * z)] = 1 } } }
    let noiseFile = try NIfTI.gunzip(CleanupMaskFile.export(LabelVolume(dims: v.dims, data: noise, maxLabel: 1), kind: .noise, like: v))
    precondition(CleanupMaskFile.storedKind(in: noiseFile) == .noise, "noise kind not stored")
    let m = try CleanupMaskFile.decode(noiseFile, kind: .noise, volume: v)
    precondition(m.mask.data == noise && m.ignored == 0 && m.marked == noise.filter { $0 != 0 }.count, "noise round trip")
    expectThrows("noise export imported as repair") { _ = try CleanupMaskFile.decode(noiseFile, kind: .repair, volume: v) }
    let foreign = try NIfTI.gunzip(NIfTI.labelFile(LabelVolume(dims: v.dims, data: noise.map { $0 == 0 ? 0 : 255 }, maxLabel: 255), voxelSize: v.voxelSize))
    precondition(CleanupMaskFile.storedKind(in: foreign) == nil, "foreign file has a kind")
    let f = try CleanupMaskFile.decode(foreign, kind: .noise, volume: v)
    precondition(f.mask.data == noise && f.mask.maxLabel == 1, "foreign binary mask as noise")

    // Nothing marked, and the wrong grid, are refused.
    let empty = NIfTI.labelFile(LabelVolume(dims: v.dims, data: [UInt8](repeating: 0, count: n), maxLabel: 0), voxelSize: v.voxelSize)
    expectThrows("empty mask") { _ = try CleanupMaskFile.decode(try NIfTI.gunzip(empty), kind: .noise, volume: v) }
    let small = NIfTI.labelFile(LabelVolume(dims: (2, 2, 2), data: [1, 1, 1, 1, 1, 1, 1, 1], maxLabel: 1), voxelSize: v.voxelSize)
    expectThrows("wrong grid") { _ = try CleanupMaskFile.decode(try NIfTI.gunzip(small), kind: .repair, volume: v) }
    print(URL(fileURLWithPath: path).lastPathComponent, "perm", v.filePerm, "flip", v.fileFlip, "ok")
}
