//
//  ProfileAlignment.swift — where a profile photo goes beside a slice so the same anatomy
//  sits at the same place in both panes. Shoulder and hip joints are matched when both the
//  scan (segmented bones) and the photo (Vision's body pose) have them; otherwise the body
//  outlines are; otherwise the photo is simply fitted to the slice.
//

import CoreGraphics
import Vision

/// Landmarks of the scan, in mm from the volume's first voxel (x → right, y → anterior, z → superior).
struct ScanLandmarks: Sendable {
    /// Midpoints between the two shoulder joints and the two hip joints (segmented bones only).
    var shoulder: SIMD3<Float>?, hip: SIMD3<Float>?
    /// Extent of everything brighter than background.
    var bodyMin: SIMD3<Float>, bodyMax: SIMD3<Float>
}

/// Landmarks of a photo, as fractions of its size (x right, y down).
struct PhotoLandmarks: Sendable {
    var shoulder: CGPoint?, hip: CGPoint?
    var body: CGRect?
    var hasBody: Bool { body != nil || (shoulder != nil && hip != nil) }
}

enum ProfileAlignment {
    /// Length of bone below its top end taken as the joint (humeral / femoral head), mm.
    private static let jointSpan: Float = 40

    // MARK: Scan

    /// One pass over the volume (strided) and two over each bone map; run off the main thread.
    static func scanLandmarks(volume: NiftiVolume, maps: [SegmentationMap]) -> ScanLandmarks {
        let (nx, ny, nz) = volume.dims
        let size = SIMD3(volume.voxelSize.0, volume.voxelSize.1, volume.voxelSize.2)
        // Body extent: voxels clearly above the background, every third one along each axis.
        let threshold = volume.displayMin + 0.15 * (volume.displayMax - volume.displayMin)
        var lo = SIMD3<Int>(nx, ny, nz), hi = SIMD3<Int>(-1, -1, -1)
        volume.data.withUnsafeBufferPointer { d in
            for z in stride(from: 0, to: nz, by: 3) { for y in stride(from: 0, to: ny, by: 3) {
                let row = nx * (y + ny * z)
                for x in stride(from: 0, to: nx, by: 3) where d[row + x] > threshold {
                    let p = SIMD3(x, y, z)
                    lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p)
                }
            } }
        }
        if hi.x < 0 { lo = .zero; hi = SIMD3(nx - 1, ny - 1, nz - 1) }
        var result = ScanLandmarks(bodyMin: SIMD3<Float>(lo) * size, bodyMax: SIMD3<Float>(hi &+ 1) * size)

        // Joints from the first map that names the bones (TotalSegmentator's total_mr).
        for map in maps where map.labels.dims == volume.dims {
            func id(_ name: String) -> Int? { map.table.names.first { $0.value == name }?.key }
            let bones = ["humerus left", "humerus right", "femur left", "femur right"].map(id)
            guard bones.contains(where: { $0 != nil }) else { continue }
            let tops = boneTops(map.labels, ids: bones, spanVoxels: max(1, Int(jointSpan / size.z)))
            let mid = (result.bodyMin.x + result.bodyMax.x) / 2
            func joint(_ a: SIMD3<Float>?, _ b: SIMD3<Float>?) -> SIMD3<Float>? {
                if let a, let b { return (a + b) / 2 * size }
                guard var one = a ?? b else { return nil }
                one *= size
                one.x = mid // one side only: the midline is the best guess for between the two
                return one
            }
            result.shoulder = joint(tops[0], tops[1])
            result.hip = joint(tops[2], tops[3])
            break
        }
        return result
    }

    /// Centroid (voxel coordinates) of the topmost `spanVoxels` layers of each label.
    private static func boneTops(_ labels: LabelVolume, ids: [Int?], spanVoxels: Int) -> [SIMD3<Float>?] {
        let (nx, ny, nz) = labels.dims
        var slot = [Int](repeating: -1, count: 256)
        for (i, id) in ids.enumerated() { if let id, id < 256 { slot[id] = i } }
        var top = [Int](repeating: -1, count: ids.count)
        var sum = [SIMD3<Float>](repeating: .zero, count: ids.count), n = [Float](repeating: 0, count: ids.count)
        labels.data.withUnsafeBufferPointer { l in
            for z in 0..<nz { // z ascends, so the last slice seen is the top
                let base = nx * ny * z
                for i in 0..<(nx * ny) where l[base + i] != 0 {
                    let s = slot[Int(l[base + i])]
                    if s >= 0 { top[s] = z }
                }
            }
            guard let lowest = top.filter({ $0 >= 0 }).min() else { return }
            for z in max(0, lowest - spanVoxels + 1)..<nz { for y in 0..<ny {
                let row = nx * (y + ny * z)
                for x in 0..<nx where l[row + x] != 0 {
                    let s = slot[Int(l[row + x])]
                    if s >= 0, z > top[s] - spanVoxels { sum[s] += SIMD3(Float(x), Float(y), Float(z)); n[s] += 1 }
                }
            } }
        }
        return zip(sum, n).map { $1 > 0 ? $0 / $1 : nil }
    }

    // MARK: Photo

    /// The person in a photo: shoulder and hip midpoints from the body pose, and the body's
    /// outline. Nil if Vision can't run (the simulator) or sees nobody.
    static func photoLandmarks(_ image: CGImage) -> PhotoLandmarks? {
        let human = VNDetectHumanRectanglesRequest()
        human.upperBodyOnly = true // a torso is enough; the scan rarely shows head to toe
        let pose = VNDetectHumanBodyPoseRequest()
        // One at a time, so a request that can't run doesn't take the other down with it.
        let handler = VNImageRequestHandler(cgImage: image)
        for request in [human, pose] as [VNRequest] {
            do { try handler.perform([request]) } catch {
                MemoryLog.log.notice("profile: body detection failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        var marks = PhotoLandmarks()
        // Vision's origin is bottom-left; the app's is top-left.
        if let box = human.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })?.boundingBox {
            marks.body = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
        if let person = pose.results?.first {
            // Confidence-weighted centre of the joints that mark one level of the trunk. The bar
            // is low on purpose: from the side Vision is unsure of the hips (0.1–0.25) yet puts
            // them in the right place, and without them the fit falls back to the outline.
            func centre(_ joints: [VNHumanBodyPoseObservation.JointName]) -> CGPoint? {
                let found = joints.compactMap { try? person.recognizedPoint($0) }.filter { $0.confidence > 0.1 }
                let weight = found.map { CGFloat($0.confidence) }.reduce(0, +)
                guard weight > 0 else { return nil }
                return CGPoint(x: found.map { $0.location.x * CGFloat($0.confidence) }.reduce(0, +) / weight,
                               y: 1 - found.map { $0.location.y * CGFloat($0.confidence) }.reduce(0, +) / weight)
            }
            marks.shoulder = centre([.leftShoulder, .rightShoulder, .neck])
            marks.hip = centre([.leftHip, .rightHip, .root])
        }
        return marks.hasBody ? marks : nil
    }

    // MARK: Placement

    /// The photo's frame in units of the displayed slice (0...1 across its width and height,
    /// x right, y down), for the slice perpendicular to `axis` whose physical size is `extent` mm.
    static func photoFrame(axis: Int, mirrored: Bool, extent: CGSize, photoSize: CGSize,
                           scan: ScanLandmarks?, photo: PhotoLandmarks?) -> CGRect {
        guard extent.width > 0, extent.height > 0, photoSize.width > 0, photoSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        // Scan mm → slice mm, matching NiftiVolume.slice and the mirror toggle.
        func onSlice(_ p: SIMD3<Float>) -> CGPoint {
            let u = CGFloat(axis == 0 ? p.y : p.x), v = CGFloat(axis == 2 ? p.y : p.z)
            return CGPoint(x: mirrored ? extent.width - u : u, y: extent.height - v)
        }
        func onPhoto(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * photoSize.width, y: p.y * photoSize.height) }

        // (mm per photo pixel, a point of the slice in mm, the same point in the photo in pixels)
        var fit: (scale: CGFloat, slice: CGPoint, photo: CGPoint)?
        // 1. Joints: the shoulder-to-hip distance sets the scale. Not for axial slices, which
        // look along that line.
        if axis != 2, let s = scan?.shoulder, let h = scan?.hip, let ps = photo?.shoulder, let ph = photo?.hip {
            let a = onSlice(s), b = onSlice(h), pa = onPhoto(ps), pb = onPhoto(ph)
            if pb.y - pa.y > 0.02 * photoSize.height, b.y - a.y > 1 {
                fit = ((b.y - a.y) / (pb.y - pa.y),
                       CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2))
            }
        }
        // 2. Outlines: match the body's width and centre.
        if fit == nil, let scan, let body = photo?.body, body.width > 0 {
            let a = onSlice(scan.bodyMin), b = onSlice(scan.bodyMax)
            let box = onPhoto(CGPoint(x: body.midX, y: body.midY))
            fit = (abs(b.x - a.x) / (body.width * photoSize.width), CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), box)
        }
        // 3. Nothing to go by: fit the whole photo to the slice.
        let f = fit ?? (min(extent.width / photoSize.width, extent.height / photoSize.height),
                        CGPoint(x: extent.width / 2, y: extent.height / 2), CGPoint(x: photoSize.width / 2, y: photoSize.height / 2))
        return CGRect(x: (f.slice.x - f.photo.x * f.scale) / extent.width, y: (f.slice.y - f.photo.y * f.scale) / extent.height,
                      width: photoSize.width * f.scale / extent.width, height: photoSize.height * f.scale / extent.height)
    }
}

private func pointwiseMin(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> SIMD3<Int> { SIMD3(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)) }
private func pointwiseMax(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> SIMD3<Int> { SIMD3(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)) }
