import SwiftUI
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Focus stacking (like Fiji's "Extended Depth of Field")
//
// Take a few photos of the same spot at slightly different focus. For every
// pixel Lister keeps the photo where that spot is sharpest (strongest local
// detail), giving one picture that is sharp all the way through.
// The phone must not move between shots; pictures must be the same size.

struct StackBox: @unchecked Sendable {
    let image: CGImage?
    let error: String?
}

/// Runs off the main thread.
func focusStack(_ urls: [URL]) -> StackBox {
    let ctx = CIContext(options: [.cacheIntermediates: false])
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return StackBox(image: nil, error: "No colour space.") }

    // 1. Load every picture (EXIF rotation applied).
    var images: [CGImage] = []
    for u in urls {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { continue }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { images.append(cg) }
    }
    guard images.count >= 2 else { return StackBox(image: nil, error: "Pick at least two pictures.") }
    let w = images[0].width, h = images[0].height
    guard images.allSatisfy({ $0.width == w && $0.height == h }) else {
        return StackBox(image: nil, error: "The pictures are not all the same size.")
    }

    let n = w * h
    let gray = CGColorSpaceCreateDeviceGray()
    var best = [UInt8](repeating: 0, count: n)       // sharpness of the current winner
    var colour = [UInt8](repeating: 0, count: n * 4)  // output RGBA

    for (index, cg) in images.enumerated() {
        let first = index == 0
        // 2. Sharpness map: Laplacian squared, then softened so whole regions switch together.
        let base = CIImage(cgImage: cg)
        let ext = base.extent
        let grey = base.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let lap = grey.clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [
            "inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9),
            "inputBias": 0
        ])
        let energy = lap.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: lap])
        let soft = energy.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(Double(max(w, h)) / 500, 3)])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 150, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 150, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 150, w: 0)
            ])
            .cropped(to: ext)
        guard let mapCG = ctx.createCGImage(soft, from: ext) else { continue }

        // Draw both into plain buffers (top row first, like every other buffer in Lister).
        var map = [UInt8](repeating: 0, count: n)
        var rgba = [UInt8](repeating: 0, count: n * 4)
        let okMap: Bool = map.withUnsafeMutableBytes { b in
            guard let p = b.baseAddress,
                  let c = CGContext(data: p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: gray,
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            c.draw(mapCG, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        let okRGB: Bool = rgba.withUnsafeMutableBytes { b in
            guard let p = b.baseAddress,
                  let c = CGContext(data: p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard okMap, okRGB else { continue }

        // 3. Keep the sharper pixel.
        map.withUnsafeBufferPointer { m in
            rgba.withUnsafeBufferPointer { s in
                best.withUnsafeMutableBufferPointer { bp in
                    colour.withUnsafeMutableBufferPointer { o in
                        for i in 0..<n where first || m[i] > bp[i] {
                            bp[i] = m[i]
                            let j = i * 4
                            o[j] = s[j]
                            o[j + 1] = s[j + 1]
                            o[j + 2] = s[j + 2]
                            o[j + 3] = 255
                        }
                    }
                }
            }
        }
    }

    let out: CGImage? = colour.withUnsafeMutableBytes { b in
        guard let p = b.baseAddress,
              let c = CGContext(data: p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        return c.makeImage()
    }
    return StackBox(image: out, error: out == nil ? "Could not build the picture." : nil)
}

extension Store {
    func runFocusStack(_ urls: [URL]) async {
        guard urls.count >= 2, !busy else { return }
        busy = true
        status = "Focus stacking \(urls.count) pictures…"
        let box = await Task.detached(priority: .userInitiated) { focusStack(urls) }.value
        busy = false
        guard let cg = box.image, let first = urls.first else {
            notify(box.error ?? "Focus stack failed.", icon: "exclamationmark.triangle.fill", error: true)
            return
        }
        let dir = first.deletingLastPathComponent()
        let writable = FileManager.default.isWritableFile(atPath: dir.path)
        let folder = writable ? dir : sessionDir
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = first.deletingPathExtension().lastPathComponent
        var url = folder.appendingPathComponent(stem + "_stack.jpg")
        var k = 1
        while FileManager.default.fileExists(atPath: url.path) {
            k += 1
            url = folder.appendingPathComponent("\(stem)_stack\(k).jpg")
        }
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            notify("Could not create the file.", icon: "exclamationmark.triangle.fill", error: true)
            return
        }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(d) else {
            notify("Could not save the stacked picture.", icon: "exclamationmark.triangle.fill", error: true)
            return
        }
        flashToken += 1
        withAnimation(Theme.spring) {
            captures.insert(Capture(id: url, thumb: Store.thumbnail(url)), at: 0)
        }
        selected = url
        notify("Focus stack saved · \(url.lastPathComponent)", icon: "square.stack.3d.up.fill")
    }
}

// MARK: - Picker sheet

struct FocusStackSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [URL] = []

    /// Pictures from the same day as the one on screen (or all, if none is selected).
    private var choices: [Capture] {
        guard let sel = store.captures.first(where: { $0.id == store.selected }) else { return store.captures }
        return store.captures.filter { $0.group == sel.group }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.gradient).frame(width: 32, height: 32)
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.onAccent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Focus stack").font(.system(size: 16, weight: .bold))
                    Text("Pick 2–10 photos of the same spot, each focused a little differently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(choices) { c in
                        cell(c)
                    }
                }
                .padding(2)
                .frame(width: 476, alignment: .top)
            }
            .frame(width: 476, height: 300)

            Text("Keep the phone still between shots and change only the fine focus. The result is saved as a new picture; the originals stay as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("\(picked.count) selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    let urls = picked
                    dismiss()
                    Task { await store.runFocusStack(urls) }
                } label: {
                    Label("Merge", systemImage: "square.stack.3d.up.fill")
                }
                .buttonStyle(PillStyle(prominent: true))
                .disabled(picked.count < 2 || store.busy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.window)
        .animation(Theme.spring, value: picked)
    }

    private func cell(_ c: Capture) -> some View {
        let n = picked.firstIndex(of: c.id)
        return Button {
            if let n { picked.remove(at: n) } else if picked.count < 10 { picked.append(c.id) }
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = c.thumb {
                        Image(nsImage: t).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 104, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(n != nil ? Theme.accent : Theme.ink.opacity(0.08), lineWidth: n != nil ? 2.5 : 1))
                .opacity(n == nil && picked.count >= 10 ? 0.4 : 1)

                if let n {
                    Text("\(n + 1)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.gradient))
                        .padding(5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(n != nil ? 0.96 : 1)
        }
        .buttonStyle(PressStyle())
        .help(c.url.lastPathComponent)
    }
}
