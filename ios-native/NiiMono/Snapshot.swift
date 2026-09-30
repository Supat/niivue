//
//  Snapshot.swift — capture what the canvas shows (all visible panes, no chrome) at
//  screen resolution, save it as a PNG and hand it to the share sheet.
//

import SwiftUI
import UIKit

/// A pane that can draw itself into an image: slice views and the 3D host.
protocol SnapshotPane: UIView {
    func snapshotImage() -> UIImage?
}

enum SnapshotPanes {
    private static let panes = NSHashTable<UIView>.weakObjects()

    static func register(_ pane: SnapshotPane) { panes.add(pane) }

    /// Composite of every pane currently on screen, in their on-screen arrangement,
    /// on black. Nil if nothing is showing.
    static func capture() -> UIImage? {
        let live = panes.allObjects.compactMap { $0 as? SnapshotPane }.filter { $0.window != nil && !$0.bounds.isEmpty }
        guard let window = live.first?.window else { return nil }
        let frames = live.map { $0.convert($0.bounds, to: window) }
        let region = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = window.screen.scale
        return UIGraphicsImageRenderer(size: region.size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: region.size))
            for (pane, frame) in zip(live, frames) {
                pane.snapshotImage()?.draw(in: frame.offsetBy(dx: -region.minX, dy: -region.minY))
            }
        }
    }

    /// Capture, write a PNG named after the document, and present the share sheet.
    /// A plain file URL is shared so receivers get the exact bytes and the file name.
    @MainActor static func captureAndShare(documentName: String) {
        guard let image = capture(), let png = image.pngData() else { return }
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day().hour().minute().second())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(documentName) \(stamp).png")
        do { try png.write(to: url) } catch { return }

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow, var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad needs an anchor; the snapshot button sits near the top trailing corner.
        sheet.popoverPresentationController?.sourceView = window
        sheet.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.width - 150, y: 60, width: 1, height: 1)
        top.present(sheet, animated: true)
    }
}
