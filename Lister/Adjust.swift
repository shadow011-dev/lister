import SwiftUI
import AppKit
import Combine
import Accelerate
import ImageIO
import UniformTypeIdentifiers
import CoreImage

/// Black-and-white mode. Bright field: dark objects on a light background become
/// pure black on white. Dark field: the result is inverted, so bright objects on a
/// dark background also come out black on white.
enum ThreshMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case bright = "Bright field"
    case dark = "Dark field"
    var id: String { rawValue }
}

// MARK: - Controller
//
// ImageJ-style Brightness/Contrast ("Image > Adjust > Brightness/Contrast").
//
// The display range is a Minimum and a Maximum on the 0-255 scale. Pixels at or
// below Minimum are shown black, pixels at or above Maximum are shown white and
// everything in between is stretched linearly. Brightness and Contrast are just
// two other ways of moving the same two numbers (same maths as ImageJ).
//
// This is display only: the file on disk is never touched. "Save copy" writes
// the adjusted picture as a new capture next to the original.

@MainActor
final class AdjustControl: ObservableObject {
    /// Top of the 0...255 scale.
    static let top: Double = 255
    /// Slider scale used for Brightness and Contrast (same as ImageJ).
    static let scale: Double = 256

    @Published private(set) var minV: Double = 0
    @Published private(set) var maxV: Double = 255
    @Published private(set) var histogram: [Int] = Array(repeating: 0, count: 256)
    /// The adjusted picture. nil means "show the original" (no change, or Preview is off).
    @Published private(set) var displayCG: CGImage?
    /// Turn off to compare with the original.
    @Published var enabled = true {
        didSet { if enabled != oldValue { render() } }
    }
    /// ImageJ "Invert" (display only, like everything here).
    @Published var invert = false {
        didSet { render() }
    }
    /// Shows the picture in grey levels (ImageJ "8-bit" look).
    @Published var grayscale = false {
        didSet { render() }
    }

    // Enhance (Core Image, on this Mac, no AI: nothing is invented).
    /// Unsharp mask strength, 0…2.
    @Published var sharpen: Double = 0 { didSet { render() } }
    /// Noise reduction, 0…1.
    @Published var denoise: Double = 0 { didSet { render() } }
    /// Large-radius unsharp mask: brings out faint detail, 0…1.
    @Published var localContrast: Double = 0 { didSet { render() } }

    // Black & white (threshold)
    @Published var threshMode: ThreshMode = .off {
        didSet { render() }
    }
    /// Grey level 0…255: everything at or below this counts as dark.
    @Published var threshold: Double = 110 { didSet { render() } }
    /// Share of the picture shown black (0…1), while black & white is on.
    @Published private(set) var blackFraction: Double?

    var hasEnhance: Bool { sharpen > 0.01 || denoise > 0.01 || localContrast > 0.01 }

    /// Rendering runs in the background; only the newest settings are drawn.
    private var renderTask: Task<Void, Never>?
    private var renderGen = 0
    private var dirty = false
    private var sourceID = 0
    private var lastBase: BaseBuffer?

    private weak var store: Store?
    private var bag = Set<AnyCancellable>()
    private var source: CGImage?
    private var currentURL: URL?
    private var rangeByImage: [URL: (Double, Double)] = [:]
    private var autoThreshold = 0
    private var lastHistogram = Date.distantPast

    var isIdentity: Bool { abs(minV) <= 0.001 && abs(maxV - Self.top) <= 0.001 }
    /// Nothing changed at all: the original is shown as it is.
    var isNeutral: Bool { isIdentity && !invert && !grayscale && !hasEnhance && threshMode == .off }

    // MARK: Wiring

    func attach(_ s: Store) {
        guard store == nil else { return }
        store = s
        s.$selected
            .sink { [weak self] url in self?.selectionChanged(to: url) }
            .store(in: &bag)
        s.$shownCG
            .sink { [weak self] cg in self?.sourceChanged(cg) }
            .store(in: &bag)
    }

    private func selectionChanged(to new: URL?) {
        if let old = currentURL { rangeByImage[old] = (minV, maxV) }
        currentURL = new
        autoThreshold = 0
        guard let new else {
            minV = 0
            maxV = Self.top
            return
        }
        if let r = rangeByImage[new] {
            minV = r.0
            maxV = r.1
        } else if new != store?.capturedURL {
            // A freshly captured picture keeps the range you were using on the live view.
            minV = 0
            maxV = Self.top
        }
    }

    private func sourceChanged(_ cg: CGImage?) {
        source = cg
        sourceID += 1
        if let cg {
            let isLive = store?.live == true
            let now = Date()
            if !isLive || now.timeIntervalSince(lastHistogram) > 0.4 {
                histogram = Self.histogram(of: cg)
                lastHistogram = now
            }
        } else {
            histogram = Array(repeating: 0, count: 256)
        }
        if store?.live != true {
            // A different picture: drop anything still being drawn for the old one.
            renderGen += 1
            renderTask?.cancel()
            renderTask = nil
            dirty = false
            displayCG = nil
            lastBase = nil
        }
        render()
    }

    // MARK: Changing the range

    func setMin(_ v: Double) {
        guard v.isFinite else { return }
        let a = min(max(v, 0), Self.top - 1)
        minV = a
        if maxV < a + 1 { maxV = a + 1 }
        render()
    }

    func setMax(_ v: Double) {
        guard v.isFinite else { return }
        let b = min(max(v, 1), Self.top)
        maxV = b
        if minV > b - 1 { minV = b - 1 }
        render()
    }

    /// Brightness slider position (0...256). Middle = window centred on the scale.
    var brightness: Double {
        let center = (minV + maxV) / 2
        return Self.scale - (center / Self.top) * Self.scale
    }

    func setBrightness(_ v: Double) {
        guard v.isFinite else { return }
        let center = Self.top * (Self.scale - v) / Self.scale
        let width = maxV - minV
        place(center: center, width: width)
    }

    /// Contrast slider position. 128 = no stretch, 256 = maximum stretch.
    var contrast: Double {
        let slope = Self.top / max(maxV - minV, 1)
        let mid = Self.scale / 2
        return slope <= 1 ? slope * mid : Self.scale - mid / slope
    }

    /// How many times the grey levels are stretched (1.0 = none).
    var stretch: Double { Self.top / max(maxV - minV, 1) }

    func setContrast(_ v: Double) {
        guard v.isFinite else { return }
        let mid = Self.scale / 2
        let slope: Double = v <= mid ? v / mid : mid / (Self.scale - v)
        guard slope > 0.0001 else { return }
        let center = (minV + maxV) / 2
        place(center: center, width: Self.top / slope)
    }

    /// Puts a window of the given width around a centre. Like ImageJ, the window may
    /// slide past 0 or 255 (that is what makes the picture brighter or darker).
    private func place(center: Double, width: Double) {
        let w = min(max(width, 1), Self.top * 8)
        let c = min(max(center, 0), Self.top)
        minV = c - w / 2
        maxV = c + w / 2
        render()
    }

    func reset() {
        autoThreshold = 0
        minV = 0
        maxV = Self.top
        invert = false
        grayscale = false
        threshMode = .off
        sharpen = 0
        denoise = 0
        localContrast = 0
        render()
    }

    /// ImageJ-style automatic threshold (Otsu's method) for black & white.
    func autoBlackWhite() {
        let h = (lastBase?.hist.isEmpty ?? true) ? histogram : (lastBase?.hist ?? histogram)
        let total = h.reduce(0, +)
        guard total > 0 else { return }
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i) * Double(h[i]) }
        var sumB = 0.0, wB = 0.0, best = 0.0, bestT = 128
        for t in 0..<256 {
            wB += Double(h[t])
            if wB == 0 { continue }
            let wF = Double(total) - wB
            if wF == 0 { break }
            sumB += Double(t) * Double(h[t])
            let mB = sumB / wB
            let mF = (sumAll - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; bestT = t }
        }
        threshold = Double(bestT)
        if threshMode == .off { threshMode = .bright }
    }

    /// ImageJ's Auto: clips a small fraction of the darkest and brightest pixels.
    /// Pressing it again clips a little more each time.
    func auto() {
        let hist = histogram
        let total = hist.reduce(0, +)
        guard total > 0 else { return }
        let limit = total / 10
        if autoThreshold < 10 { autoThreshold = 5000 } else { autoThreshold /= 2 }
        let threshold = total / autoThreshold

        var i = -1
        var count = 0
        var found = false
        repeat {
            i += 1
            count = hist[i]
            if count > limit { count = 0 }
            found = count > threshold
        } while !found && i < 255
        let hmin = i

        i = 256
        repeat {
            i -= 1
            count = hist[i]
            if count > limit { count = 0 }
            found = count > threshold
        } while !found && i > 0
        let hmax = i

        if hmax > hmin {
            minV = Double(hmin)
            maxV = Double(hmax)
        } else {
            minV = 0
            maxV = Self.top
        }
        render()
    }

    // MARK: Statistics

    var stats: (mean: Double, std: Double, lo: Int, hi: Int)? {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        var sum = 0.0
        var sum2 = 0.0
        var lo = -1
        var hi = 0
        for (i, c) in histogram.enumerated() where c > 0 {
            let d = Double(c)
            sum += Double(i) * d
            sum2 += Double(i) * Double(i) * d
            if lo < 0 { lo = i }
            hi = i
        }
        let n = Double(total)
        let mean = sum / n
        let variance = max(sum2 / n - mean * mean, 0)
        return (mean, variance.squareRoot(), max(lo, 0), hi)
    }

    // MARK: Saving

    /// Writes the adjusted picture as a new capture. The original is left alone.
    func saveCopy() {
        guard let store, !store.live, !isNeutral, enabled, let out = displayCG else { return }
        store.saveAdjusted(out)
    }

    // MARK: Rendering

    private func render() {
        guard source != nil, enabled, !isNeutral else {
            renderGen += 1
            renderTask?.cancel()
            renderTask = nil
            dirty = false
            displayCG = nil
            blackFraction = nil
            return
        }
        dirty = true
        guard renderTask == nil else { return }
        let gen = renderGen
        renderTask = Task { [weak self] in
            while let self, self.dirty, gen == self.renderGen, !Task.isCancelled {
                self.dirty = false
                guard let job = self.makeJob() else { break }
                let out = await Task.detached(priority: .userInitiated) { job.run() }.value
                guard gen == self.renderGen, !Task.isCancelled else { return }
                self.lastBase = out.base
                if self.enabled, !self.isNeutral {
                    self.displayCG = out.image
                    self.blackFraction = out.blackFraction
                }
            }
            if let self, gen == self.renderGen { self.renderTask = nil }
        }
    }

    private func makeJob() -> RenderJob? {
        guard let src = source else { return nil }
        let job = RenderJob(src: src, sourceID: sourceID, minV: minV, maxV: maxV, invert: invert,
                            grayscale: grayscale, thresh: threshMode, threshold: threshold,
                            sharpen: sharpen, denoise: denoise, local: localContrast, cached: nil)
        return RenderJob(src: src, sourceID: sourceID, minV: minV, maxV: maxV, invert: invert,
                         grayscale: grayscale, thresh: threshMode, threshold: threshold,
                         sharpen: sharpen, denoise: denoise, local: localContrast,
                         cached: lastBase?.key == job.baseKey ? lastBase : nil)
    }

    // MARK: Histogram

    /// 256-bin grey-level histogram. Large pictures are shrunk first; the shape stays the same.
    static func histogram(of cg: CGImage) -> [Int] {
        var counts = [Int](repeating: 0, count: 256)
        guard cg.width > 0, cg.height > 0 else { return counts }
        let k = min(1.0, 512.0 / Double(cg.width))
        let w = max(1, Int(Double(cg.width) * k))
        let h = max(1, Int(Double(cg.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = ctx.data else { return counts }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = raw.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0..<(w * h) { counts[Int(p[i])] += 1 }
        return counts
    }
}

// MARK: - Saving an adjusted copy

extension Store {
    func saveAdjusted(_ cg: CGImage) {
        guard let base = selected else {
            status = "Nothing to save."
            return
        }
        let dir = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent(stem + "_adj.jpg")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent("\(stem)_adj\(n).jpg")
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            status = "Could not create the file."
            return
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            status = "Could not save the adjusted copy."
            return
        }
        withAnimation(Theme.spring) {
            captures.insert(Capture(id: url, thumb: Store.thumbnail(url)), at: 0)
        }
        selected = url
        notify("Saved adjusted copy \(url.lastPathComponent)", icon: "square.and.arrow.down.fill")
    }
}

// MARK: - Panel

struct AdjustPanel: View {
    @EnvironmentObject var adj: AdjustControl
    @EnvironmentObject var store: Store
    @State private var logScale = false
    @State private var comparing = false
    @State private var showStack = false

    private var hasImage: Bool { store.shownCG != nil }

    var body: some View {
        PanelScroll {
            VStack(alignment: .leading, spacing: 14) {
            // LEDs work with or without a picture, so they sit outside the disabled part.
            LEDControlCard()

            VStack(alignment: .leading, spacing: 14) {
                Card(title: "Histogram", icon: "chart.bar.fill") {
                    HistogramView(counts: adj.histogram, lo: adj.minV, hi: adj.maxV, logScale: logScale,
                                  cut: adj.threshMode == .off ? nil : adj.threshold)
                    HStack {
                        if let s = adj.stats {
                            Text(String(format: "Mean %.1f · SD %.1f · %ld–%ld", s.mean, s.std, s.lo, s.hi))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        Spacer()
                        Button(logScale ? "Log" : "Linear") {
                            withAnimation(Theme.spring) { logScale.toggle() }
                        }
                        .buttonStyle(PillStyle())
                        .controlSize(.small)
                        .help("Switch the histogram between linear and log height")
                    }
                }

                Card(title: adj.threshMode == .off ? "Brightness & contrast" : "Brightness & contrast · off in black & white",
                     icon: "sun.max.fill") {
                    numberRow("Minimum", Binding(get: { adj.minV }, set: { adj.setMin($0) }))
                    numberRow("Maximum", Binding(get: { adj.maxV }, set: { adj.setMax($0) }))
                    SliderRow(title: "Brightness", value: "\(Int(adj.brightness.rounded()))",
                              v: Binding(get: { adj.brightness }, set: { adj.setBrightness($0) }),
                              range: 0...AdjustControl.scale, origin: AdjustControl.scale / 2)
                    SliderRow(title: "Contrast", value: String(format: "%.1f×", adj.stretch),
                              v: Binding(get: { adj.contrast }, set: { adj.setContrast($0) }),
                              range: 2...AdjustControl.scale, origin: AdjustControl.scale / 2)
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(Theme.spring) { adj.auto() }
                        } label: {
                            Label("Auto", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(PillStyle(prominent: true))
                        .help("Stretch the range automatically. Press again to clip a little more.")
                        Button {
                            withAnimation(Theme.spring) { adj.reset() }
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(PillStyle())
                        Spacer()
                    }
                }
                .disabled(adj.threshMode != .off)
                .opacity(adj.threshMode != .off ? 0.5 : 1)

                Card(title: "Enhance", icon: "sparkles") {
                    SliderRow(title: "Sharpen", value: pct(adj.sharpen / 2),
                              v: $adj.sharpen, range: 0...2)
                    SliderRow(title: "Denoise", value: pct(adj.denoise),
                              v: $adj.denoise, range: 0...1)
                    SliderRow(title: "Local contrast", value: pct(adj.localContrast),
                              v: $adj.localContrast, range: 0...1, note: "faint detail")
                    Button {
                        showStack = true
                    } label: {
                        Label("Focus stack…", systemImage: "square.stack.3d.up.fill")
                    }
                    .buttonStyle(PillStyle())
                    .help("Merge several photos focused at different depths into one sharp picture")
                    Text("Runs on this Mac. No AI, so nothing is invented and measurements stay valid.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card(title: "Black & white", icon: "circle.lefthalf.filled") {
                    Picker("", selection: Binding(get: { adj.threshMode },
                                                  set: { m in withAnimation(Theme.spring) { adj.threshMode = m } })) {
                        ForEach(ThreshMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if adj.threshMode != .off {
                        VStack(alignment: .leading, spacing: 12) {
                            SliderRow(title: "Black level", value: "\(Int(adj.threshold))",
                                      v: $adj.threshold, range: 0...255, step: 1)
                            HStack {
                                Button {
                                    withAnimation(Theme.spring) { adj.autoBlackWhite() }
                                } label: {
                                    Label("Auto", systemImage: "wand.and.stars")
                                }
                                .buttonStyle(PillStyle(prominent: true))
                                .help("Pick the level automatically (Otsu, as in ImageJ)")
                                Spacer()
                                if let f = adj.blackFraction {
                                    Text(String(format: "Black %.1f%%", f * 100))
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            Text(adj.threshMode == .bright
                                 ? "Everything darker than the black level becomes pure black, the rest pure white."
                                 : "Inverted for dark field: everything darker than the level becomes white, brighter parts become black.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                HStack(spacing: 8) {
                    Tile(title: "Invert", icon: "circle.righthalf.filled", on: adj.invert, height: 56) {
                        adj.invert.toggle()
                    }
                    Tile(title: "Grayscale", icon: "circle.lefthalf.filled", on: adj.grayscale, height: 56) {
                        adj.grayscale.toggle()
                    }
                }

                HStack(spacing: 8) {
                    Label(comparing ? "Showing original" : "Hold to compare", systemImage: comparing ? "eye.fill" : "eye")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: 132, height: 28)
                        .background(Capsule().fill(Theme.ink.opacity(comparing ? 0.16 : 0.08)))
                        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.07), lineWidth: 1))
                        .scaleEffect(comparing ? 0.96 : 1)
                        .opacity(adj.isNeutral ? 0.4 : 1)
                        .onLongPressGesture(minimumDuration: 0, maximumDistance: 200, perform: {}, onPressingChanged: { p in
                            guard !adj.isNeutral else { return }
                            withAnimation(Theme.quick) { comparing = p }
                            adj.enabled = !p
                        })
                        .help("Press and hold to see the original picture")
                    Spacer()
                    Button {
                        adj.saveCopy()
                    } label: {
                        Label("Save copy", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PillStyle(prominent: true))
                    .disabled(store.live || adj.isNeutral)
                }

                Text("Changes only what you see. Save copy writes the adjusted picture as a new capture; the original file is never touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!hasImage)
            .opacity(hasImage ? 1 : 0.6)
            .animation(Theme.spring, value: hasImage)
            .animation(Theme.spring, value: adj.threshMode)
            }
        }
        .sheet(isPresented: $showStack) { FocusStackSheet() }
    }

    private func pct(_ v: Double) -> String { v <= 0.005 ? "Off" : "\(Int((v * 100).rounded()))%" }

    // MARK: Pieces

    private func numberRow(_ title: String, _ binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                TextField("", value: binding, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(width: 58, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.well))
            }
            LSlider(value: binding, range: 0...AdjustControl.top, step: 1)
        }
    }
}

// MARK: - Histogram with the ImageJ-style mapping line

struct HistogramView: View {
    let counts: [Int]
    let lo: Double
    let hi: Double
    let logScale: Bool
    /// Black & white level, drawn as a marker.
    var cut: Double? = nil

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let n = counts.count
                guard n > 2, size.width > 0, size.height > 0 else { return }

                // Scale to the tallest bar, ignoring the two end bins (pure black / pure white
                // pile up there and would flatten everything else).
                var ceiling = 0
                for i in 1..<(n - 1) { ceiling = max(ceiling, counts[i]) }
                if ceiling == 0 { ceiling = counts.max() ?? 1 }
                let c = Double(max(ceiling, 1))

                let bw = size.width / Double(n)
                var bars = Path()
                for i in 0..<n {
                    let v = Double(counts[i])
                    let f = logScale ? log(1 + v) / log(1 + c) : v / c
                    let h = min(f, 1) * size.height
                    if h > 0 {
                        bars.addRect(CGRect(x: Double(i) * bw, y: size.height - h,
                                            width: bw + 0.3, height: h))
                    }
                }
                ctx.fill(bars, with: .linearGradient(Gradient(colors: [Theme.ink.opacity(0.75), Theme.ink.opacity(0.25)]),
                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                // The mapping: flat at black below Minimum, a ramp up to Maximum, flat at white after.
                let x0 = lo / AdjustControl.top * size.width
                let x1 = hi / AdjustControl.top * size.width
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height))
                line.addLine(to: CGPoint(x: x0, y: size.height))
                line.addLine(to: CGPoint(x: x1, y: 0))
                line.addLine(to: CGPoint(x: size.width, y: 0))
                if let cut {
                    let x = min(max(cut / AdjustControl.top, 0), 1) * size.width
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: x, height: size.height)),
                             with: .color(Theme.accent.opacity(0.18)))
                    var m = Path()
                    m.move(to: CGPoint(x: x, y: 0))
                    m.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(m, with: .color(Theme.accent2), lineWidth: 2)
                } else {
                    ctx.stroke(line, with: .color(Theme.accent), lineWidth: 2)
                }
            }
            .frame(height: 100)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
            .animation(Theme.spring, value: logScale)

            // How the grey scale is being used.
            LinearGradient(
                stops: [
                    Gradient.Stop(color: .black, location: min(max(lo / AdjustControl.top, 0), 1)),
                    Gradient.Stop(color: .white, location: min(max(hi / AdjustControl.top, 0), 1))
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            HStack {
                Text("0")
                Spacer()
                Text("255")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}


// MARK: - Background render pipeline
//
// Nothing here touches the UI, so it runs off the main thread. The "base" (the
// picture after Enhance, as plain bytes) is kept between slider moves, so moving
// Brightness, Contrast or Black level only re-runs a 256-entry table.

final class BaseBuffer: @unchecked Sendable {
    let key: String
    let ctx: CGContext
    let hist: [Int]
    init(key: String, ctx: CGContext, hist: [Int]) {
        self.key = key
        self.ctx = ctx
        self.hist = hist
    }
}

struct RenderOut: @unchecked Sendable {
    let image: CGImage?
    let base: BaseBuffer?
    let blackFraction: Double?
}

enum Pipeline {
    static let ci = CIContext(options: [.cacheIntermediates: false])
}

struct RenderJob: @unchecked Sendable {
    let src: CGImage
    let sourceID: Int
    let minV: Double
    let maxV: Double
    let invert: Bool
    let grayscale: Bool
    let thresh: ThreshMode
    let threshold: Double
    let sharpen: Double
    let denoise: Double
    let local: Double
    let cached: BaseBuffer?

    var hasEnhance: Bool { sharpen > 0.01 || denoise > 0.01 || local > 0.01 }
    var needsGrey: Bool { grayscale || thresh != .off }
    var baseKey: String {
        String(format: "%ld|%ld|%.3f|%.3f|%.3f", sourceID, needsGrey ? 1 : 0,
               hasEnhance ? sharpen : 0, hasEnhance ? denoise : 0, hasEnhance ? local : 0)
    }

    func run() -> RenderOut {
        guard let b = cached ?? makeBase() else { return RenderOut(image: nil, base: nil, blackFraction: nil) }
        return RenderOut(image: applyLUT(b.ctx), base: b, blackFraction: blackFraction(b.hist))
    }

    private func lut() -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 256)
        if thresh != .off {
            let cut = Int(threshold.rounded())
            for i in 0..<256 {
                var v: UInt8 = i <= cut ? 0 : 255
                if thresh == .dark { v = 255 - v }
                t[i] = invert ? 255 - v : v
            }
            return t
        }
        let span = max(maxV - minV, 1)
        for i in 0..<256 {
            let v = UInt8(min(max(((Double(i) - minV) / span * 255).rounded(), 0), 255))
            t[i] = invert ? 255 - v : v
        }
        return t
    }

    private func blackFraction(_ hist: [Int]) -> Double? {
        guard thresh != .off, hist.count == 256 else { return nil }
        let total = hist.reduce(0, +)
        guard total > 0 else { return nil }
        let cut = min(max(Int(threshold.rounded()), 0), 255)
        let dark = Double(hist[0...cut].reduce(0, +)) / Double(total)
        var black = thresh == .dark ? 1 - dark : dark
        if invert { black = 1 - black }
        return black
    }

    /// Sharpen / denoise / local contrast with Core Image.
    private func enhanced(_ cg: CGImage) -> CGImage? {
        var img = CIImage(cgImage: cg)
        let ext = img.extent
        let long = max(ext.width, ext.height)
        if denoise > 0.01 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.005 + denoise * 0.06,
                "inputSharpness": 0.4
            ])
        }
        if local > 0.01 {
            img = img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(long / 40, 10),
                kCIInputIntensityKey: local * 0.9
            ]).cropped(to: ext)
        }
        if sharpen > 0.01 {
            img = img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(long / 1600, 1.2),
                kCIInputIntensityKey: sharpen
            ]).cropped(to: ext)
        }
        return Pipeline.ci.createCGImage(img.cropped(to: ext), from: ext,
                                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The picture (after Enhance) as plain sRGB bytes; grey levels if needed.
    private func makeBase() -> BaseBuffer? {
        let pic = hasEnhance ? (enhanced(src) ?? src) : src
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: pic.width, height: pic.height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.draw(pic, in: CGRect(x: 0, y: 0, width: pic.width, height: pic.height))
        var hist: [Int] = []
        if needsGrey, let d = c.data {
            // R, G, B, X bytes -> the same luma in all three.
            var h = [Int](repeating: 0, count: 256)
            let bpr = c.bytesPerRow
            let p = d.bindMemory(to: UInt8.self, capacity: bpr * c.height)
            h.withUnsafeMutableBufferPointer { hp in
                for y in 0..<c.height {
                    var i = y * bpr
                    for _ in 0..<c.width {
                        let l = UInt8((UInt32(p[i]) * 77 + UInt32(p[i + 1]) * 150 + UInt32(p[i + 2]) * 29) >> 8)
                        p[i] = l
                        p[i + 1] = l
                        p[i + 2] = l
                        hp[Int(l)] += 1
                        i += 4
                    }
                }
            }
            hist = h
        }
        return BaseBuffer(key: baseKey, ctx: c, hist: hist)
    }

    private func applyLUT(_ b: CGContext) -> CGImage? {
        guard let sdata = b.data,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let d = CGContext(data: nil, width: b.width, height: b.height, bitsPerComponent: 8,
                                bytesPerRow: b.bytesPerRow, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let ddata = d.data else { return nil }
        var sb = vImage_Buffer(data: sdata, height: vImagePixelCount(b.height),
                               width: vImagePixelCount(b.width), rowBytes: b.bytesPerRow)
        var db = vImage_Buffer(data: ddata, height: vImagePixelCount(d.height),
                               width: vImagePixelCount(d.width), rowBytes: d.bytesPerRow)
        let table = lut()
        let err: vImage_Error = table.withUnsafeBufferPointer { p -> vImage_Error in
            guard let t = p.baseAddress else { return -1 }
            return vImageTableLookUp_ARGB8888(&sb, &db, t, t, t, t, vImage_Flags(kvImageNoFlags))
        }
        guard err == 0 else { return nil }
        return d.makeImage()
    }
}
