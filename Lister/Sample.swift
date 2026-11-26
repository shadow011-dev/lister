import SwiftUI
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

// MARK: - Sample detection (controller)
//
// Whenever a still picture comes on screen, Lister looks at it and works out
// whether it shows an onion peel, a leaf or a metal piece. It then measures what
// matters for that sample (see SampleCore.swift) and draws the findings on the
// picture. You can always override the guess with the Auto / Onion / Leaf / Metal
// switch. The file on disk is never touched.

/// Draws a CGImage into plain RGBA bytes, at most `maxSide` pixels on the long side.
func sampleBuffer(_ cg: CGImage, maxSide: Int) -> SImage? {
    let long = max(cg.width, cg.height)
    guard long > 0 else { return nil }
    let f = min(1.0, Double(maxSide) / Double(long))
    let w = max(Int((Double(cg.width) * f).rounded()), 1)
    let h = max(Int((Double(cg.height) * f).rounded()), 1)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
        guard let base = buf.baseAddress,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? SImage(w: w, h: h, rgba: px) : nil
}

/// The marks of one analysis as a transparent picture (same shape as the analysed picture).
func sampleOverlayImage(_ r: SResult) -> CGImage? {
    guard r.w > 0, r.h > 0, r.overlay.count == r.w * r.h * 4,
          let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(r.overlay) as CFData) else { return nil }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    return CGImage(width: r.w, height: r.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.w * 4,
                   space: cs, bitmapInfo: info, provider: provider, decode: nil,
                   shouldInterpolate: true, intent: .defaultIntent)
}

@MainActor
final class SampleControl: ObservableObject {
    /// Look at every new picture automatically.
    @Published var autoDetect: Bool {
        didSet {
            UserDefaults.standard.set(autoDetect, forKey: "sampleAuto")
            if autoDetect && result == nil { analyzeNow() }
        }
    }
    /// Apply the matching enhancement (contrast, sharpness) right after detection.
    @Published var autoEnhance: Bool {
        didSet { UserDefaults.standard.set(autoEnhance, forKey: "sampleEnhance") }
    }
    @Published var showOverlay = true

    /// What you picked by hand for this picture (nil = automatic).
    @Published private(set) var choice: SampleKind?
    @Published private(set) var detection: SDetection?
    @Published private(set) var result: SResult?
    @Published private(set) var overlay: CGImage?
    @Published private(set) var working = false

    private weak var store: Store?
    private weak var adj: AdjustControl?
    private var bag = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var choices: [URL: SampleKind] = [:]

    init() {
        let d = UserDefaults.standard
        autoDetect = d.object(forKey: "sampleAuto") as? Bool ?? true
        autoEnhance = d.object(forKey: "sampleEnhance") as? Bool ?? false
    }

    var activeKind: SampleKind? { choice ?? detection?.kind }

    // MARK: Wiring

    func attach(_ s: Store, _ a: AdjustControl) {
        guard store == nil else { return }
        store = s
        adj = a
        s.$shownCG
            .sink { [weak self] cg in self?.imageChanged(cg) }
            .store(in: &bag)
        s.$umPerPixel
            .dropFirst()
            .sink { [weak self] _ in self?.scaleChanged() }
            .store(in: &bag)
    }

    private func clear() {
        if detection != nil { detection = nil }
        if result != nil { result = nil }
        if overlay != nil { overlay = nil }
        if working { working = false }
    }

    private func imageChanged(_ cg: CGImage?) {
        // Live view sends a new frame many times a second: leave it alone.
        if store?.live == true {
            task?.cancel()
            task = nil
            clear()
            return
        }
        task?.cancel()
        task = nil
        clear()
        choice = store?.selected.flatMap { choices[$0] }
        guard let cg, autoDetect else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.run(cg)
        }
    }

    private func scaleChanged() {
        if result != nil { analyzeNow() }
    }

    // MARK: Running

    func analyzeNow() {
        guard let cg = store?.shownCG, store?.live != true else { return }
        task?.cancel()
        task = Task { [weak self] in await self?.run(cg) }
    }

    /// Pick the sample type by hand (nil goes back to automatic).
    func choose(_ k: SampleKind?) {
        choice = k
        if let u = store?.selected {
            if let k { choices[u] = k } else { choices[u] = nil }
        }
        analyzeNow()
    }

    private func run(_ cg: CGImage) async {
        guard let store else { return }
        working = true
        let umPerPx = store.umPerPixel
        let forced = choice
        guard let img = sampleBuffer(cg, maxSide: 1400) else {
            working = false
            return
        }
        let units = SUnits(scale: Double(cg.width) / Double(img.w), umPerFullPx: umPerPx)
        let out = await Task.detached(priority: .userInitiated) { runSampleEngine(img, units, forced) }.value
        guard !Task.isCancelled, store.shownCG === cg, !store.live else { return }
        detection = out.detection
        result = out.result
        if let r = out.result {
            overlay = sampleOverlayImage(r)
        } else {
            overlay = nil
        }
        working = false
        if let k = forced ?? out.detection.kind {
            store.status = forced == nil
                ? "Sample: \(k.title) · \(Int((out.detection.confidence * 100).rounded()))% sure"
                : "Sample: \(k.title) (chosen by you)"
            if autoEnhance { applyEnhancement(k) }
        } else {
            store.status = "Could not tell the sample type. Pick one in the Sample tab."
        }
    }

    // MARK: Enhancement

    /// Sets Adjust to settings that suit the sample (display only, like everything in Adjust).
    func applyEnhancement(_ k: SampleKind? = nil) {
        guard let adj, let kind = k ?? activeKind else { return }
        adj.reset()
        adj.auto()
        switch kind {
        case .onion:
            // See-through cells: lift faint walls and nuclei.
            adj.localContrast = 0.55
            adj.sharpen = 0.35
            adj.denoise = 0.15
        case .leaf:
            adj.localContrast = 0.35
            adj.sharpen = 0.50
            adj.denoise = 0.10
        case .metal:
            // Grain boundaries and scratches are fine lines: sharpen more.
            adj.localContrast = 0.25
            adj.sharpen = 0.75
            adj.denoise = 0.10
        }
        store?.notify("Enhanced for \(kind.title.lowercased())", icon: "wand.and.stars")
    }

    // MARK: Results out

    func copyResults() {
        guard let r = result else { return }
        var s = "Lister · \(r.kind.title)\n"
        for row in r.rows { s += "\(row.label)\t\(row.value)\n" }
        for note in r.notes { s += "Note: \(note)\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        store?.notify("Results copied", icon: "doc.on.doc.fill")
    }

    func savePicture() {
        guard let store, let base = store.shownCG, let ov = overlay else { return }
        store.saveSamplePicture(base: adj?.displayCG ?? base, overlay: ov)
    }
}

// MARK: - Saving the picture with its marks

extension Store {
    func saveSamplePicture(base: CGImage, overlay: CGImage) {
        guard let src = selected else {
            status = "Nothing to save."
            return
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            status = "Could not draw the picture."
            return
        }
        let rect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        ctx.draw(base, in: rect)
        ctx.interpolationQuality = .high
        ctx.draw(overlay, in: rect)
        guard let out = ctx.makeImage() else {
            status = "Could not draw the picture."
            return
        }
        let dir = src.deletingLastPathComponent()
        let writable = FileManager.default.isWritableFile(atPath: dir.path)
        let folder = writable ? dir : sessionDir
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = src.deletingPathExtension().lastPathComponent
        var url = folder.appendingPathComponent(stem + "_sample.jpg")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent("\(stem)_sample\(n).jpg")
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            status = "Could not create the file."
            return
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, out, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            status = "Could not save the picture."
            return
        }
        withAnimation(Theme.spring) {
            captures.insert(Capture(id: url, thumb: Store.thumbnail(url)), at: 0)
        }
        selected = url
        notify("Saved picture with marks · \(url.lastPathComponent)", icon: "square.and.arrow.down.fill")
    }
}

// MARK: - Panel

struct SamplePanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var sampler: SampleControl

    private var hasPicture: Bool { store.shownCG != nil && !store.live }

    var body: some View {
        PanelScroll {
            VStack(alignment: .leading, spacing: 14) {
                detectCard
                if let r = sampler.result {
                    resultCard(r)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
                autoCard
            }
            .animation(Theme.spring, value: sampler.result?.rows.count)
            .animation(Theme.spring, value: sampler.working)
        }
    }

    // MARK: Detect

    private var title: String {
        if sampler.working { return "Looking…" }
        if let k = sampler.activeKind { return k.title }
        if sampler.detection != nil { return "Can't tell" }
        return "Not analysed yet"
    }

    private var subtitle: String {
        if sampler.working { return "Reading colour, texture and structure" }
        if sampler.choice != nil { return "Chosen by you" }
        if let d = sampler.detection {
            if d.kind != nil { return "Detected automatically · \(Int((d.confidence * 100).rounded()))% sure" }
            return "Pick the sample type below"
        }
        return "Press Analyze"
    }

    private var detectCard: some View {
        Card(title: "Sample", icon: "sparkle.magnifyingglass") {
            if !hasPicture {
                Text(store.live
                     ? "Stop live view or take a picture. Lister then works out what the sample is."
                     : "Capture or open a picture. Lister works out by itself whether it is an onion peel, a leaf or a metal piece.")
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.gradient).frame(width: 42, height: 42)
                        if sampler.working {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: sampler.activeKind?.icon ?? "questionmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.onAccent)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 16, weight: .semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let d = sampler.detection {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(d.reasons, id: \.self) { why in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.accent)
                                Text(why)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    VStack(spacing: 5) {
                        ForEach(SampleKind.allCases) { k in
                            HStack(spacing: 8) {
                                Text(k.short)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 44, alignment: .leading)
                                ProgressView(value: min(max(d.scores[k] ?? 0, 0), 1))
                                    .progressViewStyle(.linear)
                                Text("\(Int(((d.scores[k] ?? 0) * 100).rounded()))")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                            }
                        }
                    }
                }

                Picker("", selection: Binding(get: { sampler.choice },
                                              set: { sampler.choose($0) })) {
                    Text("Auto").tag(SampleKind?.none)
                    ForEach(SampleKind.allCases) { k in
                        Text(k.short).tag(Optional(k))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 8) {
                    Button {
                        sampler.analyzeNow()
                    } label: {
                        Label("Analyze", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(PillStyle(prominent: true))
                    .disabled(!store.canMeasure || sampler.working)
                    .help("Detect the sample and measure it (⌘K)")

                    Button {
                        withAnimation(Theme.spring) { sampler.applyEnhancement() }
                    } label: {
                        Label("Enhance", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(PillStyle())
                    .disabled(sampler.activeKind == nil)
                    .help("Set contrast and sharpness that suit this sample")
                }
            }
        }
    }

    // MARK: Results

    private func resultCard(_ r: SResult) -> some View {
        Card(title: "\(r.kind.short) results", icon: "list.bullet.clipboard") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(r.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(row.value)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !r.notes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(r.notes, id: \.self) { note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !store.calibratedForSample {
                Button {
                    withAnimation(Theme.spring) { store.sideTab = .measure }
                } label: {
                    Label("Calibrate scale", systemImage: "ruler")
                }
                .buttonStyle(PillStyle())
            }
            HStack(spacing: 8) {
                Button {
                    sampler.copyResults()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(PillStyle())

                Button {
                    sampler.savePicture()
                } label: {
                    Label("Save picture", systemImage: "photo.badge.arrow.down")
                }
                .buttonStyle(PillStyle(prominent: true))
                .disabled(sampler.overlay == nil)
                .help("Save a copy of the picture with the marks drawn on it")
            }
        }
    }

    // MARK: Automatic

    private var autoCard: some View {
        Card(title: "Automatic", icon: "bolt.fill") {
            Toggle("Detect the sample when a picture opens", isOn: $sampler.autoDetect)
                .toggleStyle(.switch)
                .font(.system(size: 13))
            Toggle("Enhance automatically for the sample", isOn: $sampler.autoEnhance)
                .toggleStyle(.switch)
                .font(.system(size: 13))
            Toggle("Show the marks on the picture", isOn: $sampler.showOverlay)
                .toggleStyle(.switch)
                .font(.system(size: 13))
            Text("Cells are outlined in yellow, nuclei in pink, stomata ringed in red, grain boundaries in cyan and long scratches in red. Marks are drawn on screen only: the file on disk is never changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Store {
    /// True once the microscope scale is set (results are then in µm instead of pixels).
    var calibratedForSample: Bool { umPerPixel > 0 }
}
