//
//  clean_export_check.swift — round trip of the cleaned-scan export on real scans: the float
//  file read back is the scan, except the masked voxels, which are the background value.
//  Build & run: mkdir -p /tmp/ce && cp spike/clean_export_check.swift /tmp/ce/main.swift &&
//    swiftc -O NiiMono/Models/NIfTI.swift /tmp/ce/main.swift -o /tmp/ce/check && /tmp/ce/check <scan.nii.gz>...
//

import Foundation

for path in CommandLine.arguments.dropFirst() {
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    let v = try NIfTI.parse(NIfTI.isGzip(raw) ? NIfTI.gunzip(raw) : raw)
    let (nx, ny, nz) = v.dims
    var mask = [UInt8](repeating: 0, count: v.data.count)
    for z in nz / 3..<nz / 2 { for y in 0..<ny / 4 { for x in nx / 5..<nx / 2 { mask[x + nx * (y + ny * z)] = 1 } } }
    let file = try NIfTI.gunzip(NIfTI.floatFile(v, mask: mask, background: v.dataMin)!)
    let back = try NIfTI.parse(file)
    precondition(back.dims == v.dims, "dims")
    var bad = 0
    for i in 0..<v.data.count where back.data[i] != (mask[i] != 0 ? v.dataMin : v.data[i]) { bad += 1 }
    precondition(bad == 0, "\(bad) voxels differ")
    precondition(file[252..<344] == v.header![252..<344], "affine changed")
    precondition(back.embeddedJSON == v.embeddedJSON, "metadata extension lost")
    print(URL(fileURLWithPath: path).lastPathComponent, "perm", v.filePerm, "flip", v.fileFlip, "ok")
}
