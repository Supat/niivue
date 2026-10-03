//
//  label_export_check.swift — round trip of the label export on real scans: written on the
//  file's own grid and orientation, read back through parseLabels to the same RAS labels,
//  with the JSON extension intact.
//  Build & run: mkdir -p /tmp/le && cp spike/label_export_check.swift /tmp/le/main.swift &&
//    swiftc -O NiiMono/Models/NIfTI.swift /tmp/le/main.swift -o /tmp/le/check && /tmp/le/check <scan.nii.gz>...
//

import Foundation

for path in CommandLine.arguments.dropFirst() {
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    let v = try NIfTI.parse(NIfTI.isGzip(raw) ? NIfTI.gunzip(raw) : raw)
    precondition(v.header != nil, "header not kept")
    // A pattern that differs along every axis, so any transposition or flip shows.
    let (nx, ny, nz) = v.dims
    var data = [UInt8](repeating: 0, count: nx * ny * nz)
    for z in 0..<nz { for y in 0..<ny { for x in 0..<nx { data[x + nx * (y + ny * z)] = UInt8((x / 7 + 3 * (y / 5) + 11 * (z / 3)) % 251 + 1) } } }
    let labels = LabelVolume(dims: v.dims, data: data, maxLabel: 251)
    let json = Data(#"{"labels":[{"id":1,"name":"Test","color":[1,0,0]}]}"#.utf8)
    let file = try NIfTI.gunzip(NIfTI.labelFile(labels, like: v, json: json))
    let back = try NIfTI.parseLabels(file)
    precondition(back.dims == v.dims, "dims \(back.dims) vs \(v.dims)")
    precondition(back.data == data, "voxels differ")
    let off = file.withUnsafeBytes { Int(Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 108, as: UInt32.self)))) }
    precondition(off % 16 == 0 && NIfTI.embeddedJSON(in: file, voxOffset: off) == json, "extension")
    // The exported header keeps the scan's affine (sform/qform bytes 252..<344).
    precondition(file[252..<344] == v.header![252..<344], "affine changed")
    print(URL(fileURLWithPath: path).lastPathComponent, "perm", v.filePerm, "flip", v.fileFlip, "ok")
}
