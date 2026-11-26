import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum LErr: LocalizedError {
    case badURL, badImage, http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "The phone address is not valid."
        case .badImage: return "The phone did not send a valid image."
        case .http(let code): return "The phone answered with HTTP \(code)."
        }
    }
}

struct Capture: Identifiable {
    let id: URL
    var thumb: NSImage?
    /// Opened from somewhere else (not a Lister capture): never trashed, only removed from the list.
    var external = false
    var url: URL { id }
    var isAdjusted: Bool { url.deletingPathExtension().lastPathComponent.contains("_adj") }
    var isStacked: Bool { url.deletingPathExtension().lastPathComponent.contains("_stack") }
    /// Sidebar section: the day folder ("2026-11-19"), or "Opened".
    var group: String { external ? "Opened" : url.deletingLastPathComponent().lastPathComponent }
}

/// Carries a thumbnail back from the background thread.
struct ThumbBox: @unchecked Sendable {
    let image: NSImage?
}

/// Small preview for the sidebar. Free function so it can run off the main thread.
func makeThumbnail(_ url: URL) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 240
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

// MARK: - Measurements

enum MKind: String {
    case line, angle, rect, oval, count

    var title: String {
        switch self {
        case .line: return "Length"
        case .angle: return "Angle"
        case .rect: return "Box area"
        case .oval: return "Oval area"
        case .count: return "Count"
        }
    }

    var icon: String {
        switch self {
        case .line: return "line.diagonal"
        case .angle: return "angle"
        case .rect: return "rectangle.dashed"
        case .oval: return "circle.dashed"
        case .count: return "smallcircle.filled.circle"
        }
    }
}

struct Measurement: Identifiable {
    let id: UUID
    var kind: MKind
    /// Image pixel coordinates. line: [a, b]; angle: [a, vertex, c]; rect/oval: two corners; count: every point.
    var pts: [CGPoint]
    /// Mean and standard deviation of grey value inside a box or oval.
    var mean: Double?
    var sd: Double?

    init(kind: MKind, pts: [CGPoint]) {
        self.id = UUID()
        self.kind = kind
        self.pts = pts
    }

    var a: CGPoint { pts.first ?? .zero }
    var b: CGPoint { pts.last ?? .zero }

    /// Length of a line, in pixels.
    var pixels: Double { Double(hypot(b.x - a.x, b.y - a.y)) }

    var rect: CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Area of a box or oval, in square pixels.
    var areaPx: Double {
        let r = rect
        switch kind {
        case .rect: return Double(r.width * r.height)
        case .oval: return Double.pi * Double(r.width / 2) * Double(r.height / 2)
        default: return 0
        }
    }

    /// Angle in degrees. For a line: against the horizontal, like ImageJ (counter-clockwise is positive).
    /// For an angle: the angle at the middle point.
    var angleDeg: Double {
        switch kind {
        case .line:
            return atan2(Double(a.y - b.y), Double(b.x - a.x)) * 180 / .pi
        case .angle:
            guard pts.count >= 3 else { return 0 }
            let v = pts[1]
            let a1 = atan2(Double(pts[0].y - v.y), Double(pts[0].x - v.x))
            let a2 = atan2(Double(pts[2].y - v.y), Double(pts[2].x - v.x))
            var d = abs(a1 - a2) * 180 / .pi
            if d > 180 { d = 360 - d }
            return d
        default:
            return 0
        }
    }
}

/// A saved calibration, e.g. one per microscope objective.
struct ScalePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var umPerPixel: Double
}

enum LUnit: String, CaseIterable, Identifiable {
    case um = "µm"
    case mm = "mm"
    var id: String { rawValue }
    var toMicrons: Double { self == .um ? 1 : 1000 }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    // Settings
    @Published var phoneURL: String {
        didSet { UserDefaults.standard.set(phoneURL, forKey: "phoneURL") }
    }
    @Published var photoPath: String {
        didSet { UserDefaults.standard.set(photoPath, forKey: "photoPath") }
    }
    /// Calibration: micrometres per image pixel. 0 means not calibrated.
    @Published var umPerPixel: Double {
        didSet { UserDefaults.standard.set(umPerPixel, forKey: "umPerPixel") }
    }
    @Published var presets: [ScalePreset] {
        didSet {
            if let d = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d, forKey: "scalePresets") }
        }
    }
    @Published var showScaleBar: Bool {
        didSet { UserDefaults.standard.set(showScaleBar, forKey: "showScaleBar") }
    }

    // Captures and what is on screen
    @Published var captures: [Capture] = []
    @Published var selected: URL? {
        didSet { selectionChanged() }
    }
    @Published var shownCG: CGImage? {
        didSet { rgbRep = nil; gray = nil }
    }
    @Published var shownPixels: CGSize = .zero
    @Published var fitToken = 0
    /// Changes whenever a different picture comes on screen (drives the fade).
    @Published var imageID = ""
    /// Bumped on every capture (drives the shutter flash).
    @Published var flashToken = 0

    // State
    @Published var status = "Ready"
    @Published var busy = false
    @Published var live = false {
        didSet { if live != oldValue { liveChanged() } }
    }
    @Published var toast: Toast?
    @Published var tool: Tool = .pan
    @Published var sideTab: SideTab = .camera

    // Time-lapse
    @Published var lapseOn = false
    @Published var lapseDone = 0
    @Published var lapseTotal: Double = 20
    @Published var lapseEvery: Double = 30
    private var lapseTask: Task<Void, Never>?

    // Measurements
    @Published var measByImage: [URL: [Measurement]] = [:]
    @Published var selectedID: UUID?

    /// The Arduino LEDs (switched on around each capture when Auto is on).
    weak var lights: LightController?

    /// Set just before a new capture is selected (the Adjust panel keeps the live range for it).
    var capturedURL: URL?

    private var rgbRep: NSBitmapImageRep?
    private var gray: (w: Int, h: Int, px: [UInt8])?
    private var liveTask: Task<Void, Never>?
    private var liveShowing = false
    private var toastTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        phoneURL = d.string(forKey: "phoneURL") ?? "http://192.168.1.100:8080"
        photoPath = d.string(forKey: "photoPath") ?? "/photo.jpg"
        umPerPixel = d.double(forKey: "umPerPixel")
        if let data = d.data(forKey: "scalePresets"),
           let p = try? JSONDecoder().decode([ScalePreset].self, from: data) {
            presets = p
        } else {
            presets = []
        }
        showScaleBar = d.object(forKey: "showScaleBar") as? Bool ?? true
        loadExisting()
    }

    // MARK: Messages

    func notify(_ text: String, icon: String = "checkmark.circle.fill", error: Bool = false) {
        status = text
        toast = Toast(text: text, icon: icon, isError: error)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if Task.isCancelled { return }
            self?.toast = nil
        }
    }

    // MARK: Folders

    static var root: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lister", isDirectory: true)
    }

    var sessionDir: URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return Store.root.appendingPathComponent(f.string(from: Date()), isDirectory: true)
    }

    /// Every day folder under ~/Pictures/Lister, newest first. Thumbnails load in the background.
    private func loadExisting() {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(at: Store.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var all: [URL] = []
        for d in days {
            let files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            all += files.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        captures = all.map { Capture(id: $0, thumb: nil) }
        selected = captures.first?.id
        loadThumbs(all)
    }

    private func loadThumbs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            for u in urls {
                let box = await Task.detached(priority: .utility) { ThumbBox(image: makeThumbnail(u)) }.value
                guard let self else { return }
                if let i = self.captures.firstIndex(where: { $0.id == u }) { self.captures[i].thumb = box.image }
            }
        }
    }

    // MARK: Opening other pictures

    static let openTypes: [UTType] = [.jpeg, .png, .tiff, .heic, .bmp, .gif]

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Store.openTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        openImages(panel.urls)
    }

    /// Pick a folder and load every picture inside it (sub-folders included).
    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of pictures to open in Lister"
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        openImages(panel.urls)
    }

    static func isImage(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
        return Store.openTypes.contains { t.conforms(to: $0) }
    }

    /// Pictures inside a folder (and its sub-folders), in natural file-name order.
    static func images(in folder: URL, limit: Int = 2000) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        while let u = en.nextObject() as? URL {
            if isImage(u) {
                out.append(u)
                if out.count >= limit { break }
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Adds pictures from anywhere (Finder, drag and drop, whole folders) to the list, ready to measure.
    @discardableResult
    func openImages(_ urls: [URL]) -> Bool {
        var ok: [URL] = []
        var folders: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                folders.append(u)
                ok += Store.images(in: u)
            } else if Store.isImage(u) {
                ok.append(u)
            }
        }
        guard !ok.isEmpty else {
            if folders.isEmpty {
                notify("Lister can open JPEG, PNG, TIFF, HEIC, BMP and GIF pictures.", icon: "photo", error: true)
            } else {
                notify("No pictures found in that folder.", icon: "photo", error: true)
            }
            return false
        }
        if live { live = false }
        var added: [URL] = []
        withAnimation(Theme.spring) {
            for u in ok.reversed() where !captures.contains(where: { $0.id == u }) {
                captures.insert(Capture(id: u, thumb: nil, external: true), at: 0)
                added.append(u)
            }
        }
        loadThumbs(added)
        selected = ok.first
        if urls.count == 1, folders.count == 1 {
            notify("Opened \(ok.count) picture\(ok.count == 1 ? "" : "s") from \(folders[0].lastPathComponent)", icon: "folder.fill")
        } else {
            notify(ok.count == 1 ? "Opened \(ok[0].lastPathComponent)" : "Opened \(ok.count) pictures", icon: "photo.fill")
        }
        return true
    }

    func removeFromList(_ url: URL) {
        withAnimation(Theme.spring) { captures.removeAll { $0.id == url } }
        measByImage[url] = nil
        if selected == url { selected = captures.first?.id }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(sessionDir)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func trash(_ url: URL) {
        if captures.first(where: { $0.id == url })?.external == true {
            removeFromList(url)
            return
        }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        withAnimation(Theme.spring) {
            captures.removeAll { $0.id == url }
        }
        measByImage[url] = nil
        if selected == url { selected = captures.first?.id }
        notify("Moved to Trash", icon: "trash.fill")
    }

    // MARK: Phone

    func endpoint(_ path: String) throws -> URL {
        var base = phoneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.contains("://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        let p = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + p) else { throw LErr.badURL }
        return url
    }

    func fetch(_ path: String, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: try endpoint(path))
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw LErr.http(http.statusCode)
        }
        return data
    }

    func testConnection() async -> String {
        do {
            let start = Date()
            let data = try await fetch("/shot.jpg", timeout: 8)
            guard Store.decode(data) != nil else { return "Connected, but the reply was not an image." }
            return String(format: "Connected · %ld KB in %.1f s", data.count / 1024, Date().timeIntervalSince(start))
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }

    func capture() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if live { live = false }

        // LEDs on for the photo (only if they were off; they go off again afterwards).
        var litForCapture = false
        if let l = lights, l.autoCapture, !l.isOn, l.connected || FileManager.default.fileExists(atPath: l.portPath) {
            l.lightForCapture()
            if l.connected {
                litForCapture = true
                status = "LEDs on, letting the camera adjust…"
                let wait = max(l.warmup, l.secondsUntilReady + 0.3)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        defer { if litForCapture { lights?.set(false) } }

        status = "Capturing…"
        do {
            let data = try await fetch(photoPath, timeout: 40)
            guard Store.decode(data) != nil else { throw LErr.badImage }
            let url = try save(data)
            flashToken += 1
            withAnimation(Theme.spring) {
                captures.insert(Capture(id: url, thumb: Store.thumbnail(url)), at: 0)
            }
            capturedURL = url
            selected = url
            if lapseOn {
                notify("Time-lapse \(lapseDone + 1) of \(Int(lapseTotal)) · \(url.lastPathComponent)", icon: "timer")
            } else {
                notify("Captured \(url.lastPathComponent) · \(data.count / 1024) KB", icon: "camera.fill")
            }
        } catch {
            notify("Capture failed: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", error: true)
        }
    }

    private func save(_ data: Data) throws -> URL {
        let dir = sessionDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let name = f.string(from: Date())
        var url = dir.appendingPathComponent(name + ".jpg")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent("\(name)_\(n).jpg")
        }
        try data.write(to: url)
        return url
    }

    // MARK: Time-lapse

    func startLapse() {
        guard !lapseOn else { return }
        lapseOn = true
        lapseDone = 0
        lapseTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.lapseDone < Int(self.lapseTotal) {
                let start = Date()
                await self.capture()
                if Task.isCancelled { break }
                self.lapseDone += 1
                if self.lapseDone >= Int(self.lapseTotal) { break }
                let wait = max(self.lapseEvery - Date().timeIntervalSince(start), 0.5)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard let self else { return }
            let done = self.lapseDone
            withAnimation(Theme.spring) { self.lapseOn = false }
            self.lapseTask = nil
            self.notify("Time-lapse finished · \(done) photos", icon: "timer")
        }
        notify("Time-lapse started", icon: "timer")
    }

    func stopLapse() {
        lapseTask?.cancel()
        lapseTask = nil
        withAnimation(Theme.spring) { lapseOn = false }
        notify("Time-lapse stopped · \(lapseDone) photos", icon: "stop.circle.fill")
    }

    // MARK: Live view

    private func liveChanged() {
        if live { startLive() } else { stopLive() }
    }

    private func startLive() {
        liveTask?.cancel()
        liveShowing = false
        status = "Connecting to live view…"
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let data = try await self.fetch("/shot.jpg", timeout: 5)
                    if Task.isCancelled { return }
                    if let cg = Store.decode(data) { self.showLive(cg) }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                } catch {
                    if Task.isCancelled { return }
                    self.status = "Live view: \(error.localizedDescription)"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        liveShowing = false
        loadSelected()
        status = "Ready"
    }

    private func showLive(_ cg: CGImage) {
        guard live else { return }
        if !liveShowing {
            liveShowing = true
            imageID = "live"
            fitToken += 1
        }
        shownCG = cg
        let px = CGSize(width: cg.width, height: cg.height)
        if shownPixels != px { shownPixels = px }
        if status != "Live view" { status = "Live view" }
    }

    // MARK: Selected image

    private func selectionChanged() {
        selectedID = nil
        if live { live = false } else { loadSelected() }
    }

    private func loadSelected() {
        guard let url = selected, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = Store.full(src) else {
            shownCG = nil
            shownPixels = .zero
            imageID = ""
            return
        }
        shownCG = cg
        shownPixels = CGSize(width: cg.width, height: cg.height)
        imageID = url.path
        fitToken += 1
    }

    func rgb(x: Int, y: Int) -> (Int, Int, Int)? {
        guard !live, let cg = shownCG else { return nil }
        if rgbRep == nil { rgbRep = NSBitmapImageRep(cgImage: cg) }
        guard let rep = rgbRep, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
    }

    // MARK: Image decoding

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return full(src)
    }

    /// Full-resolution image with the EXIF orientation applied.
    static func full(_ src: CGImageSource) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func thumbnail(_ url: URL) -> NSImage? { makeThumbnail(url) }

    // MARK: Grey values (for area statistics and line profiles)

    private func grayData() -> (w: Int, h: Int, px: [UInt8])? {
        if let g = gray { return g }
        guard !live, let cg = shownCG, cg.width > 0, cg.height > 0 else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let g = (w: w, h: h, px: px)
        gray = g
        return g
    }

    func grayAt(x: Int, y: Int) -> Int? {
        guard let g = grayData(), x >= 0, y >= 0, x < g.w, y < g.h else { return nil }
        return Int(g.px[y * g.w + x])
    }

    /// Mean and standard deviation of the grey values inside a box or oval.
    private func regionStats(_ m: Measurement) -> (mean: Double, sd: Double)? {
        guard m.kind == .rect || m.kind == .oval, let g = grayData() else { return nil }
        let r = m.rect
        let x0 = max(Int(r.minX.rounded(.down)), 0)
        let y0 = max(Int(r.minY.rounded(.down)), 0)
        let x1 = min(Int(r.maxX.rounded(.up)), g.w)
        let y1 = min(Int(r.maxY.rounded(.up)), g.h)
        guard x1 > x0, y1 > y0 else { return nil }
        let step = (x1 - x0) * (y1 - y0) > 4_000_000 ? 2 : 1
        let cx = Double(r.midX), cy = Double(r.midY)
        let rx = max(Double(r.width) / 2, 0.5), ry = max(Double(r.height) / 2, 0.5)
        let oval = m.kind == .oval
        var n = 0.0, sum = 0.0, sum2 = 0.0
        g.px.withUnsafeBufferPointer { p in
            var y = y0
            while y < y1 {
                var x = x0
                while x < x1 {
                    var inside = true
                    if oval {
                        let dx = (Double(x) + 0.5 - cx) / rx
                        let dy = (Double(y) + 0.5 - cy) / ry
                        inside = dx * dx + dy * dy <= 1
                    }
                    if inside {
                        let v = Double(p[y * g.w + x])
                        n += 1
                        sum += v
                        sum2 += v * v
                    }
                    x += step
                }
                y += step
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return (mean, max(sum2 / n - mean * mean, 0).squareRoot())
    }

    /// Grey values sampled along a line (ImageJ "Plot Profile").
    func profile(_ m: Measurement) -> [Double] {
        guard m.kind == .line, let g = grayData() else { return [] }
        let n = max(2, min(Int(m.pixels.rounded()), 1500))
        var out: [Double] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let x = Int((Double(m.a.x) + (Double(m.b.x) - Double(m.a.x)) * t).rounded(.down))
            let y = Int((Double(m.a.y) + (Double(m.b.y) - Double(m.a.y)) * t).rounded(.down))
            if x >= 0, y >= 0, x < g.w, y < g.h { out.append(Double(g.px[y * g.w + x])) }
        }
        return out
    }

    // MARK: Measurements

    var measurements: [Measurement] {
        guard let u = selected else { return [] }
        return measByImage[u] ?? []
    }

    var selectedMeasurement: Measurement? {
        guard let id = selectedID else { return nil }
        return measurements.first { $0.id == id }
    }

    var canMeasure: Bool { !live && shownCG != nil && selected != nil }

    func add(kind: MKind, pts: [CGPoint]) {
        guard let u = selected, canMeasure else { return }
        var m = Measurement(kind: kind, pts: pts)
        if let s = regionStats(m) {
            m.mean = s.mean
            m.sd = s.sd
        }
        measByImage[u, default: []].append(m)
        selectedID = m.id
    }

    /// Count tool: every click adds a point to this picture's counter.
    func addCountPoint(_ p: CGPoint) {
        guard let u = selected, canMeasure else { return }
        guard p.x >= 0, p.y >= 0, p.x <= shownPixels.width, p.y <= shownPixels.height else { return }
        var list = measByImage[u] ?? []
        if let i = list.lastIndex(where: { $0.kind == .count }) {
            list[i].pts.append(p)
            selectedID = list[i].id
        } else {
            let m = Measurement(kind: .count, pts: [p])
            list.append(m)
            selectedID = m.id
        }
        measByImage[u] = list
    }

    func deleteSelected() {
        guard let u = selected, let id = selectedID else { return }
        withAnimation(Theme.spring) {
            measByImage[u]?.removeAll { $0.id == id }
            selectedID = nil
        }
    }

    func clearMeasurements() {
        guard let u = selected else { return }
        withAnimation(Theme.spring) {
            measByImage[u] = []
            selectedID = nil
        }
    }

    /// Removes the last thing added (the last counted point, or the last measurement).
    func undoLast() {
        guard let u = selected, var list = measByImage[u], let last = list.last else { return }
        withAnimation(Theme.spring) {
            if last.kind == .count, last.pts.count > 1 {
                list[list.count - 1].pts.removeLast()
            } else {
                list.removeLast()
                if selectedID == last.id { selectedID = nil }
            }
            measByImage[u] = list
        }
    }

    // MARK: Scale

    func calibrate(known: Double, unit: LUnit) {
        guard let m = selectedMeasurement, m.kind == .line, m.pixels > 0, known > 0 else {
            notify("Select a length line and type its real length first.", icon: "ruler", error: true)
            return
        }
        umPerPixel = known * unit.toMicrons / m.pixels
        notify(String(format: "Scale set · 1 px = %.4f µm", umPerPixel), icon: "ruler.fill")
    }

    func savePreset(name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard umPerPixel > 0, !n.isEmpty else { return }
        if let i = presets.firstIndex(where: { $0.name.lowercased() == n.lowercased() }) {
            presets[i].umPerPixel = umPerPixel
        } else {
            withAnimation(Theme.spring) { presets.append(ScalePreset(name: n, umPerPixel: umPerPixel)) }
        }
        notify("Saved scale “\(n)”", icon: "bookmark.fill")
    }

    func applyPreset(_ p: ScalePreset) {
        withAnimation(Theme.spring) { umPerPixel = p.umPerPixel }
        notify("Using scale “\(p.name)”", icon: "ruler.fill")
    }

    func deletePreset(_ p: ScalePreset) {
        withAnimation(Theme.spring) { presets.removeAll { $0.id == p.id } }
    }

    var activePreset: ScalePreset? {
        guard umPerPixel > 0 else { return nil }
        return presets.first { abs($0.umPerPixel - umPerPixel) < 1e-9 }
    }

    // MARK: Text

    func lengthText(_ px: Double) -> String {
        guard umPerPixel > 0 else { return String(format: "%.1f px", px) }
        let um = px * umPerPixel
        return um >= 1000 ? String(format: "%.3f mm", um / 1000) : String(format: "%.1f µm", um)
    }

    func areaText(_ px2: Double) -> String {
        guard umPerPixel > 0 else { return String(format: "%.0f px²", px2) }
        let um2 = px2 * umPerPixel * umPerPixel
        return um2 >= 1_000_000 ? String(format: "%.4f mm²", um2 / 1_000_000) : String(format: "%.1f µm²", um2)
    }

    func primaryText(_ m: Measurement) -> String {
        switch m.kind {
        case .line: return lengthText(m.pixels)
        case .angle: return String(format: "%.1f°", m.angleDeg)
        case .rect, .oval: return areaText(m.areaPx)
        case .count: return "\(m.pts.count)"
        }
    }

    func secondaryText(_ m: Measurement) -> String {
        switch m.kind {
        case .line: return String(format: "%.0f px · %.1f°", m.pixels, m.angleDeg)
        case .angle: return "between the two arms"
        case .rect, .oval:
            if let mean = m.mean, let sd = m.sd { return String(format: "mean %.1f ± %.1f", mean, sd) }
            return ""
        case .count: return m.pts.count == 1 ? "point" : "points"
        }
    }

    /// n, mean, SD, min, max of one kind of measurement on this picture.
    func summary(_ kind: MKind) -> (n: Int, mean: Double, sd: Double, lo: Double, hi: Double)? {
        let vals: [Double] = measurements.filter { $0.kind == kind }.map {
            switch kind {
            case .line: return $0.pixels
            case .angle: return $0.angleDeg
            default: return $0.areaPx
            }
        }
        guard vals.count >= 2 else { return nil }
        let n = Double(vals.count)
        let mean = vals.reduce(0, +) / n
        let v = vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
        return (vals.count, mean, v.squareRoot(), vals.min() ?? 0, vals.max() ?? 0)
    }

    func summaryValueText(_ kind: MKind, _ v: Double) -> String {
        switch kind {
        case .line: return lengthText(v)
        case .angle: return String(format: "%.1f°", v)
        default: return areaText(v)
        }
    }

    static func niceLength(_ target: Double) -> Double {
        guard target > 0, target.isFinite else { return 0 }
        let base = pow(10, floor(log10(target)))
        let f = target / base
        let n: Double = f < 1.5 ? 1 : (f < 3.5 ? 2 : (f < 7.5 ? 5 : 10))
        return n * base
    }

    static func micronText(_ um: Double) -> String {
        um >= 1000 ? String(format: "%g mm", um / 1000) : String(format: "%g µm", um)
    }

    var imageInfo: String {
        guard shownPixels.width > 0 else { return "" }
        return "\(Int(shownPixels.width)) × \(Int(shownPixels.height))"
    }

    // MARK: Results out

    private func rows() -> [[String]] {
        guard let u = selected else { return [] }
        let cal = umPerPixel > 0
        func f(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }
        var out: [[String]] = [["image", "index", "type", "value", "unit", "length_px", "angle_deg",
                                "area_px2", "mean", "sd", "points", "x1", "y1", "x2", "y2"]]
        for (i, m) in measurements.enumerated() {
            var value = "", unit = "", len = "", ang = "", area = "", mean = "", sd = ""
            switch m.kind {
            case .line:
                value = cal ? f(m.pixels * umPerPixel) : f(m.pixels)
                unit = cal ? "um" : "px"
                len = f(m.pixels)
                ang = f(m.angleDeg)
            case .angle:
                value = f(m.angleDeg)
                unit = "deg"
                ang = f(m.angleDeg)
            case .rect, .oval:
                value = cal ? f(m.areaPx * umPerPixel * umPerPixel) : f(m.areaPx, 0)
                unit = cal ? "um2" : "px2"
                area = f(m.areaPx, 0)
                mean = m.mean.map { f($0) } ?? ""
                sd = m.sd.map { f($0) } ?? ""
            case .count:
                value = "\(m.pts.count)"
                unit = "count"
            }
            let p2 = m.pts.count > 1 ? m.pts[m.pts.count - 1] : m.a
            out.append([u.lastPathComponent, "\(i + 1)", m.kind.rawValue, value, unit, len, ang, area, mean, sd,
                        "\(m.pts.count)", f(Double(m.a.x)), f(Double(m.a.y)), f(Double(p2.x)), f(Double(p2.y))])
        }
        return out
    }

    func copyResults() {
        let r = rows()
        guard r.count > 1 else { return }
        let text = r.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify("Results copied — paste into Excel or Numbers", icon: "doc.on.doc.fill")
    }

    func exportCSV() {
        guard let u = selected, !measurements.isEmpty else {
            notify("No measurements to export.", icon: "tablecells", error: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = u.deletingPathExtension().lastPathComponent + "_measurements.csv"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let s = rows().map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
        do {
            try s.write(to: dest, atomically: true, encoding: .utf8)
            notify("Exported \(dest.lastPathComponent)", icon: "tablecells.fill")
        } catch {
            notify("Export failed: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill", error: true)
        }
    }
}
