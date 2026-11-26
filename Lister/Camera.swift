import SwiftUI

// MARK: - Controller

/// Controls the phone camera (IP Webcam) from inside the app, so the phone's
/// web page is never needed. Every change shows instantly on screen and is sent
/// to the phone in the background; sliders are debounced.
///
/// Notes on the IP Webcam API (v005 fixes):
/// - `/ptz?zoom=P` takes a PERCENT of the zoom range (0…100). v004 sent the zoom
///   ratio ×100 (100…800), which the phone clamps to maximum: the slider seemed dead.
/// - The phone answers HTTP 200 even when it refuses a setting; success is "Ok"
///   in the reply body, so that is what we check now.
/// - `curvals.zoom` is the zoom ratio ×100 (100 = 1×) and lags a second or two.
@MainActor
final class CameraControl: ObservableObject {
    /// 0…100 % of the phone's zoom range.
    @Published var zoom: Double = 0
    /// What the phone reports back, e.g. 2.4 (×). nil until known.
    @Published var zoomRatio: Double?
    @Published var exposure: Double = 0
    @Published var exposureRange: ClosedRange<Double> = -4...4
    @Published var hasExposure = true
    @Published var quality: Double = 50
    @Published var cropX: Double = 50
    @Published var cropY: Double = 50
    @Published var torch = false
    @Published var focusHold = false
    @Published var night = false
    @Published var front = false
    @Published var focusMode = ""
    @Published var focusModes: [String] = []
    @Published var whiteBalance = ""
    @Published var whiteBalances: [String] = []
    @Published var photoSize = ""
    @Published var photoSizes: [String] = []
    /// nil = not tried yet.
    @Published var online: Bool?
    @Published var syncing = false
    @Published var error: String?

    private weak var store: Store?
    private var pending: [String: Task<Void, Never>] = [:]
    private var verifyTask: Task<Void, Never>?

    func attach(_ s: Store) {
        store = s
        let d = UserDefaults.standard
        if d.object(forKey: "camZoom") != nil { zoom = d.double(forKey: "camZoom") }
    }

    // MARK: Sending

    private func send(_ key: String, _ path: String, delay: UInt64 = 0, verify: Bool = false) {
        pending[key]?.cancel()
        pending[key] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if Task.isCancelled { return }
            guard let self, let store = self.store else { return }
            do {
                let data = try await store.fetch(path, timeout: 6)
                if Task.isCancelled { return }
                self.online = true
                self.error = nil
                let body = String(decoding: data, as: UTF8.self).lowercased()
                if path.hasPrefix("/settings/"), !body.isEmpty, !body.contains("ok") {
                    store.notify("The phone did not accept \(key.replacingOccurrences(of: "_", with: " ")).",
                                 icon: "exclamationmark.triangle.fill", error: true)
                }
                if verify { self.scheduleVerify() }
            } catch {
                if Task.isCancelled { return }
                self.online = false
                self.error = "Phone not reachable. Check the address in Settings."
            }
        }
    }

    private func setting(_ name: String, _ value: String, delay: UInt64 = 0, verify: Bool = false) {
        let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        send(name, "/settings/\(name)?set=\(v)", delay: delay, verify: verify)
    }

    private func onOff(_ b: Bool) -> String { b ? "on" : "off" }

    /// Camera settings only make sense on the live picture, so switch it on.
    private func showLive() {
        guard let store, !store.live, !store.busy else { return }
        store.live = true
        store.notify("Live view on, so you can see the change", icon: "video.fill")
    }

    // MARK: Actions

    func setZoom(_ v: Double) {
        zoom = min(max(v, 0), 100).rounded()
        UserDefaults.standard.set(zoom, forKey: "camZoom")
        showLive()
        send("zoom", "/ptz?zoom=\(Int(zoom))", delay: 120_000_000, verify: true)
    }

    func setExposure(_ v: Double) {
        exposure = min(max(v, exposureRange.lowerBound), exposureRange.upperBound).rounded()
        showLive()
        setting("exposure", "\(Int(exposure))", delay: 150_000_000)
    }

    func setQuality(_ v: Double) {
        quality = min(max(v, 1), 100).rounded()
        showLive()
        setting("quality", "\(Int(quality))", delay: 250_000_000)
    }

    func setCrop(x: Double, y: Double) {
        cropX = min(max(x, 0), 100).rounded()
        cropY = min(max(y, 0), 100).rounded()
        showLive()
        setting("crop_x", "\(Int(cropX))", delay: 120_000_000)
        setting("crop_y", "\(Int(cropY))", delay: 120_000_000)
    }

    func toggleTorch() {
        torch.toggle()
        showLive()
        send("torch", torch ? "/enabletorch" : "/disabletorch")
    }

    func toggleFocusHold() {
        focusHold.toggle()
        showLive()
        send("focus", focusHold ? "/focus" : "/nofocus")
    }

    func toggleNight() {
        night.toggle()
        showLive()
        setting("night_vision", onOff(night))
    }

    func setFront(_ on: Bool) {
        front = on
        setting("ffc", onOff(on))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await self?.refresh()
        }
    }

    func setFocusMode(_ m: String) {
        focusMode = m
        setting("focusmode", m)
    }

    func setWhiteBalance(_ m: String) {
        whiteBalance = m
        showLive()
        setting("whitebalance", m)
    }

    func setPhotoSize(_ s: String) {
        photoSize = s
        setting("photo_size", s)
        store?.notify("Captures will be \(s.replacingOccurrences(of: "x", with: " × "))", icon: "photo.fill")
    }

    func resetView() {
        setZoom(0)
        setCrop(x: 50, y: 50)
        if hasExposure { setExposure(0) }
    }

    // MARK: Reading the phone's current state

    private func readStatus() async throws -> (cur: [String: Any], avail: [String: Any]) {
        guard let store else { return ([:], [:]) }
        let data = try await store.fetch("/status.json?show_avail=1", timeout: 6)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([:], [:]) }
        return (root["curvals"] as? [String: Any] ?? [:], root["avail"] as? [String: Any] ?? [:])
    }

    private static func str(_ d: [String: Any], _ k: String) -> String? {
        if let s = d[k] as? String { return s }
        if let n = d[k] as? NSNumber { return n.stringValue }
        return nil
    }

    private static func num(_ d: [String: Any], _ k: String) -> Double? { str(d, k).flatMap { Double($0) } }

    private static func flag(_ d: [String: Any], _ k: String) -> Bool? {
        guard let s = str(d, k)?.lowercased() else { return nil }
        return s == "on" || s == "true" || s == "1"
    }

    private static func strings(_ d: [String: Any], _ k: String) -> [String] {
        guard let a = d[k] as? [Any] else { return [] }
        return a.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
    }

    private func readZoomRatio(_ cur: [String: Any]) {
        // curvals.zoom is the ratio ×100 (100 = 1×). Anything below 100 is not a ratio.
        if let z = Self.num(cur, "zoom"), z >= 100 {
            withAnimation(Theme.quick) { zoomRatio = z / 100 }
        }
    }

    /// The phone reports the new zoom a little late; read it twice.
    private func scheduleVerify() {
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            for wait in [UInt64(900_000_000), UInt64(2_000_000_000)] {
                try? await Task.sleep(nanoseconds: wait)
                if Task.isCancelled { return }
                guard let self else { return }
                if let s = try? await self.readStatus() { self.readZoomRatio(s.cur) }
            }
        }
    }

    func refresh() async {
        guard store != nil else { return }
        syncing = true
        defer { syncing = false }
        do {
            let (cur, avail) = try await readStatus()

            readZoomRatio(cur)
            if let v = Self.num(cur, "quality") { quality = v }
            if let v = Self.num(cur, "crop_x") { cropX = v }
            if let v = Self.num(cur, "crop_y") { cropY = v }
            if let v = Self.flag(cur, "night_vision") { night = v }
            if let v = Self.flag(cur, "torch") { torch = v }
            if let v = Self.flag(cur, "ffc") { front = v }

            hasExposure = cur["exposure"] != nil
            let evs = Self.strings(avail, "exposure").compactMap { Double($0) }
            if let lo = evs.min(), let hi = evs.max(), hi > lo { exposureRange = lo...hi }
            if let v = Self.num(cur, "exposure") {
                if v < exposureRange.lowerBound || v > exposureRange.upperBound {
                    exposureRange = min(v, exposureRange.lowerBound)...max(v, exposureRange.upperBound)
                }
                exposure = v
            }

            if let f = Self.str(cur, "focusmode") { focusMode = f }
            focusModes = Self.strings(avail, "focusmode")
            if let w = Self.str(cur, "whitebalance") { whiteBalance = w }
            whiteBalances = Self.strings(avail, "whitebalance")
            if let p = Self.str(cur, "photo_size") { photoSize = p }
            photoSizes = Self.strings(avail, "photo_size").sorted { Self.pixelCount($0) > Self.pixelCount($1) }

            // The phone's text overlay gets burned into pictures; Lister keeps it off.
            if Self.flag(cur, "overlay") == true { setting("overlay", "off") }

            withAnimation(Theme.spring) {
                online = true
                error = nil
            }
        } catch {
            withAnimation(Theme.spring) {
                online = false
                self.error = "Phone not reachable. Check the address in Settings."
            }
        }
    }

    static func pixelCount(_ s: String) -> Int {
        let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
        return p.count == 2 ? p[0] * p[1] : 0
    }

    static func sizeLabel(_ s: String) -> String {
        let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
        guard p.count == 2 else { return s }
        let mp = Double(p[0] * p[1]) / 1_000_000
        return String(format: "%ld × %ld  (%.1f MP)", p[0], p[1], mp)
    }
}

// MARK: - Camera panel

struct CameraPanel: View {
    @EnvironmentObject var cam: CameraControl
    @EnvironmentObject var store: Store
    @State private var showMore = false

    private var zoomText: String {
        let pct = cam.zoom <= 0 ? "Off" : "\(Int(cam.zoom))%"
        if let r = cam.zoomRatio { return pct + String(format: " · %.1f×", r) }
        return pct
    }

    private var exposureText: String {
        let v = Int(cam.exposure)
        return v > 0 ? "+\(v)" : "\(v)"
    }

    var body: some View {
        PanelScroll {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let e = cam.error {
                    banner(e)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Card(title: "Picture", icon: "camera.aperture") {
                    SliderRow(title: "Zoom", value: zoomText,
                              v: Binding(get: { cam.zoom }, set: { cam.setZoom($0) }),
                              range: 0...100, step: 1)
                    if cam.hasExposure {
                        SliderRow(title: "Exposure", value: exposureText,
                                  v: Binding(get: { cam.exposure }, set: { cam.setExposure($0) }),
                                  range: cam.exposureRange, step: 1, origin: 0)
                    }
                }

                HStack(spacing: 8) {
                    Tile(title: "Light", icon: "flashlight.on.fill", on: cam.torch) { cam.toggleTorch() }
                    Tile(title: "Focus lock", icon: "scope", on: cam.focusHold) { cam.toggleFocusHold() }
                    Tile(title: "Night", icon: "moon.fill", on: cam.night) { cam.toggleNight() }
                }

                if cam.zoom > 0 {
                    Card(title: "Move zoomed area", icon: "arrow.up.and.down.and.arrow.left.and.right") {
                        PanPad(x: cam.cropX, y: cam.cropY) { x, y in cam.setCrop(x: x, y: y) }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }

                Card {
                    Reveal(title: "More camera settings", open: $showMore) {
                        if !cam.photoSizes.isEmpty {
                            MenuRow(title: "Photo size", options: cam.photoSizes, selection: cam.photoSize,
                                    label: { CameraControl.sizeLabel($0) },
                                    onPick: { cam.setPhotoSize($0) })
                        }
                        if !cam.whiteBalances.isEmpty {
                            MenuRow(title: "White balance", options: cam.whiteBalances,
                                    selection: cam.whiteBalance,
                                    onPick: { cam.setWhiteBalance($0) })
                        }
                        if !cam.focusModes.isEmpty {
                            MenuRow(title: "Focus mode", options: cam.focusModes,
                                    selection: cam.focusMode,
                                    onPick: { cam.setFocusMode($0) })
                        }
                        SliderRow(title: "Live quality", value: "\(Int(cam.quality))%",
                                  v: Binding(get: { cam.quality }, set: { cam.setQuality($0) }),
                                  range: 1...100, step: 1,
                                  note: "preview only")
                        Text("Live quality only changes the live preview. Captures always use full photo quality; pick their resolution with Photo size.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                lapseCard

                HStack {
                    Button {
                        withAnimation(Theme.spring) { cam.resetView() }
                    } label: {
                        Label("Reset picture", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(PillStyle())
                    Spacer()
                }
            }
            .animation(Theme.spring, value: cam.zoom > 0)
            .animation(Theme.spring, value: cam.error)
            .animation(Theme.spring, value: cam.hasExposure)
        }
    }

    // MARK: Time-lapse

    private static let everyOptions = ["5", "10", "30", "60", "120", "300", "600", "1800"]

    private static func everyLabel(_ s: String) -> String {
        let v = Int(s) ?? 0
        if v < 60 { return "\(v) s" }
        return v % 60 == 0 ? "\(v / 60) min" : "\(v / 60) min \(v % 60) s"
    }

    private var lapseLength: String {
        let t = Int((store.lapseTotal - 1) * store.lapseEvery)
        if t < 60 { return "about \(t) s" }
        if t < 3600 { return "about \(t / 60) min" }
        return String(format: "about %.1f h", Double(t) / 3600)
    }

    private var lapseCard: some View {
        Card(title: "Time-lapse", icon: "timer") {
            Group {
                MenuRow(title: "Take a photo every", options: Self.everyOptions,
                        selection: "\(Int(store.lapseEvery))",
                        label: { Self.everyLabel($0) },
                        onPick: { store.lapseEvery = Double($0) ?? 30 })
                SliderRow(title: "Photos", value: "\(Int(store.lapseTotal))",
                          v: $store.lapseTotal, range: 2...200, step: 1)
            }
            .disabled(store.lapseOn)

            if store.lapseOn {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.ink.opacity(0.08))
                            Capsule().fill(Theme.gradient)
                                .frame(width: g.size.width * CGFloat(store.lapseDone) / CGFloat(max(Int(store.lapseTotal), 1)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(store.lapseDone) of \(Int(store.lapseTotal)) taken")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Text(store.lapseOn ? "Running… keep Lister open" : "Takes \(lapseLength)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Button {
                    if store.lapseOn { store.stopLapse() } else { store.startLapse() }
                } label: {
                    Label(store.lapseOn ? "Stop" : "Start", systemImage: store.lapseOn ? "stop.fill" : "play.fill")
                }
                .buttonStyle(PillStyle(prominent: !store.lapseOn))
            }
        }
        .animation(Theme.spring, value: store.lapseOn)
        .animation(Theme.spring, value: store.lapseDone)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(cam.online == true ? Color.green : (cam.online == false ? Color.orange : Color.secondary))
                .frame(width: 7, height: 7)
                .shadow(color: cam.online == true ? .green.opacity(0.7) : .clear, radius: 4)
            Text(cam.online == true ? "Phone connected" : (cam.online == false ? "Phone offline" : "Connecting…"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            Spacer()
            Button {
                Task { await cam.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(cam.syncing ? 360 : 0))
                    .animation(cam.syncing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: cam.syncing)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.ink.opacity(0.07)))
            }
            .buttonStyle(PressStyle())
            .help("Read the current settings from the phone")
        }
        .animation(Theme.quick, value: cam.online)
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            Text(text).font(.caption)
            Spacer(minLength: 0)
            Button("Retry") { Task { await cam.refresh() } }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

/// Drag the dot to choose which part of the picture the phone zooms into.
struct PanPad: View {
    let x: Double
    let y: Double
    let onChange: (Double, Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let inset: CGFloat = 12
            let w = max(g.size.width - inset * 2, 1)
            let h = max(g.size.height - inset * 2, 1)
            let px = inset + CGFloat(x / 100) * w
            let py = inset + CGFloat(y / 100) * h
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.well)
                Path { p in
                    p.move(to: CGPoint(x: g.size.width / 2, y: inset))
                    p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height - inset))
                    p.move(to: CGPoint(x: inset, y: g.size.height / 2))
                    p.addLine(to: CGPoint(x: g.size.width - inset, y: g.size.height / 2))
                }
                .stroke(Theme.ink.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Circle()
                    .fill(Theme.gradient)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Theme.ink.opacity(0.85), lineWidth: 2))
                    .shadow(color: Theme.accent.opacity(0.5), radius: dragging ? 10 : 5)
                    .scaleEffect(dragging ? 1.2 : 1)
                    .position(x: px, y: py)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true }
                        let nx = min(max((v.location.x - inset) / w, 0), 1) * 100
                        let ny = min(max((v.location.y - inset) / h, 0), 1) * 100
                        onChange(Double(nx), Double(ny))
                    }
                    .onEnded { _ in dragging = false }
            )
            .onTapGesture(count: 2) { onChange(50, 50) }
        }
        .frame(height: 110)
        .animation(Theme.bouncy, value: dragging)
        .help("Drag to move the zoomed area. Double-click to centre.")
    }
}
