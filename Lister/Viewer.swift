import SwiftUI
import AppKit

// MARK: - Tools (ImageJ-style: Line, Angle, Rectangle, Oval, Multi-point)

enum Tool: String, CaseIterable, Identifiable {
    case pan, line, angle, rect, oval, count
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pan: return "Move"
        case .line: return "Length"
        case .angle: return "Angle"
        case .rect: return "Box"
        case .oval: return "Oval"
        case .count: return "Count"
        }
    }

    var icon: String {
        switch self {
        case .pan: return "hand.raised.fill"
        case .line: return "line.diagonal"
        case .angle: return "angle"
        case .rect: return "rectangle.dashed"
        case .oval: return "circle.dashed"
        case .count: return "smallcircle.filled.circle"
        }
    }

    var hint: String {
        switch self {
        case .pan: return "Drag to move · pinch or ⌘-scroll to zoom · click a mark to select it"
        case .line: return "Drag across something to measure its length"
        case .angle: return "Drag the first arm, then click where the second arm ends"
        case .rect: return "Drag a box to measure area and mean brightness"
        case .oval: return "Drag an oval to measure area and mean brightness"
        case .count: return "Click each object to count it · drag to move"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .pan: return "1"
        case .line: return "2"
        case .angle: return "3"
        case .rect: return "4"
        case .oval: return "5"
        case .count: return "6"
        }
    }

    var kind: MKind? {
        switch self {
        case .pan: return nil
        case .line: return .line
        case .angle: return .angle
        case .rect: return .rect
        case .oval: return .oval
        case .count: return .count
        }
    }
}

private struct Draft {
    var kind: MKind
    var pts: [CGPoint]
}

struct ViewerView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var adj: AdjustControl
    @EnvironmentObject var sampler: SampleControl
    @Namespace private var ns

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var size: CGSize = .zero
    @State private var hover: CGPoint?
    @State private var panStart: CGSize?
    @State private var draft: Draft?
    /// First arm of an angle (image coordinates), waiting for the third click.
    @State private var arm: [CGPoint]?
    @State private var lastMag: CGFloat = 1
    @State private var monitor: Any?
    @State private var imageOpacity: Double = 1
    @State private var flash: Double = 0

    private var pw: CGFloat { store.shownPixels.width }
    private var ph: CGFloat { store.shownPixels.height }

    /// Measuring needs a still picture; on live view everything is Move.
    private var tool: Tool { store.canMeasure ? store.tool : .pan }

    // MARK: Coordinates

    private func viewPt(_ q: CGPoint, _ sz: CGSize) -> CGPoint {
        CGPoint(x: sz.width / 2 + offset.width + (q.x - pw / 2) * scale,
                y: sz.height / 2 + offset.height + (q.y - ph / 2) * scale)
    }

    private func imagePt(_ p: CGPoint, _ sz: CGSize) -> CGPoint {
        CGPoint(x: (p.x - sz.width / 2 - offset.width) / scale + pw / 2,
                y: (p.y - sz.height / 2 - offset.height) / scale + ph / 2)
    }

    /// Only the visible part of the image is drawn, so deep zoom stays fast.
    private func visibleCrop(_ cg: CGImage, _ sz: CGSize) -> (image: CGImage, rect: CGRect)? {
        guard scale.isFinite, scale > 0, sz.width > 0, sz.height > 0 else { return nil }
        let p1 = imagePt(.zero, sz)
        let p2 = imagePt(CGPoint(x: sz.width, y: sz.height), sz)
        guard p1.x.isFinite, p1.y.isFinite, p2.x.isFinite, p2.y.isFinite else { return nil }
        let full = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        let want = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                          width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
        let r = want.integral.intersection(full)
        guard !r.isNull, r.width >= 1, r.height >= 1, let sub = cg.cropping(to: r) else { return nil }
        let o = viewPt(r.origin, sz)
        let vr = CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
        guard vr.origin.x.isFinite, vr.origin.y.isFinite, vr.width.isFinite, vr.height.isFinite,
              vr.width < 100_000, vr.height < 100_000 else { return nil }
        return (sub, vr)
    }

    // MARK: Zoom

    private func fit() {
        guard pw > 0, ph > 0, size.width > 0, size.height > 0 else { return }
        let s = min(size.width / pw, size.height / ph) * 0.94
        guard s.isFinite, s > 0 else { return }
        scale = s
        offset = .zero
    }

    private func zoom(about p: CGPoint, factor: CGFloat) {
        guard scale.isFinite, scale > 0, factor.isFinite, factor > 0,
              p.x.isFinite, p.y.isFinite else { return }
        let ns = min(max(scale * min(max(factor, 0.5), 2), 0.02), 40)
        let f = ns / scale
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let ox = (p.x - c.x) - ((p.x - c.x) - offset.width) * f
        let oy = (p.y - c.y) - ((p.y - c.y) - offset.height) * f
        guard ox.isFinite, oy.isFinite else { return }
        let limit: CGFloat = 200_000
        offset = CGSize(width: min(max(ox, -limit), limit), height: min(max(oy, -limit), limit))
        scale = ns
    }

    private var centre: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let h = hover else { return event }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard dx.isFinite, dy.isFinite else { return nil }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                let k: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
                let e = min(max(dy * k, -0.5), 0.5)
                zoom(about: h, factor: CGFloat(exp(Double(e))))
            } else {
                let limit: CGFloat = 200_000
                offset = CGSize(width: min(max(offset.width + dx, -limit), limit),
                                height: min(max(offset.height + dy, -limit), limit))
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    // MARK: Hit testing

    private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func hitDistance(_ m: Measurement, _ p: CGPoint) -> CGFloat {
        let v = m.pts.map { viewPt($0, size) }
        switch m.kind {
        case .line:
            return v.count >= 2 ? segmentDistance(p, v[0], v[1]) : .infinity
        case .angle:
            return v.count >= 3 ? min(segmentDistance(p, v[0], v[1]), segmentDistance(p, v[1], v[2])) : .infinity
        case .rect, .oval:
            guard v.count >= 2 else { return .infinity }
            let r = CGRect(x: min(v[0].x, v[1].x), y: min(v[0].y, v[1].y),
                           width: abs(v[1].x - v[0].x), height: abs(v[1].y - v[0].y))
            return r.insetBy(dx: -6, dy: -6).contains(p) ? 5 : .infinity
        case .count:
            return v.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? .infinity
        }
    }

    private func selectNearest(_ p: CGPoint) {
        var best: UUID?
        var bestD: CGFloat = 9
        for m in store.measurements {
            let d = hitDistance(m, p)
            if d < bestD { bestD = d; best = m.id }
        }
        withAnimation(Theme.spring) { store.selectedID = best }
    }

    // MARK: Drawing

    private func label(_ ctx: GraphicsContext, _ s: String, at p: CGPoint, _ color: Color) {
        let txt = ctx.resolve(Text(s).font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundColor(.white))
        let ts = txt.measure(in: CGSize(width: 600, height: 60))
        let r = CGRect(x: p.x - ts.width / 2 - 8, y: p.y - ts.height / 2 - 3,
                       width: ts.width + 16, height: ts.height + 6)
        let shape = Path(roundedRect: r, cornerRadius: r.height / 2)
        ctx.fill(shape, with: .color(.black.opacity(0.66)))
        ctx.stroke(shape, with: .color(color.opacity(0.9)), lineWidth: 1)
        ctx.draw(txt, at: p)
    }

    private func shapePath(_ kind: MKind, _ v: [CGPoint]) -> Path {
        var p = Path()
        switch kind {
        case .line:
            guard v.count >= 2 else { return p }
            p.move(to: v[0])
            p.addLine(to: v[1])
        case .angle:
            guard v.count >= 2 else { return p }
            p.move(to: v[0])
            for q in v.dropFirst() { p.addLine(to: q) }
        case .rect, .oval:
            guard v.count >= 2 else { return p }
            let r = CGRect(x: min(v[0].x, v[1].x), y: min(v[0].y, v[1].y),
                           width: abs(v[1].x - v[0].x), height: abs(v[1].y - v[0].y))
            if kind == .rect { p.addRect(r) } else { p.addEllipse(in: r) }
        case .count:
            break
        }
        return p
    }

    private func drawMark(_ ctx: GraphicsContext, kind: MKind, view v: [CGPoint], text: String?,
                          color: Color, selected: Bool, dashed: Bool, t: Double) {
        guard !v.isEmpty else { return }
        let path = shapePath(kind, v)

        if selected {
            let pulse = 0.5 + 0.5 * sin(t * 4)
            ctx.stroke(path, with: .color(color.opacity(0.18 + 0.14 * pulse)),
                       style: StrokeStyle(lineWidth: 7 + 3 * pulse, lineCap: .round, lineJoin: .round))
        }

        if kind == .rect || kind == .oval {
            ctx.fill(path, with: .color(color.opacity(selected ? 0.12 : 0.06)))
        }

        let style = StrokeStyle(lineWidth: selected ? 2 : 1.6, lineCap: .round, lineJoin: .round,
                                dash: dashed ? [6, 4] : [], dashPhase: dashed ? CGFloat(-t * 24) : 0)
        ctx.stroke(path, with: .color(color), style: style)

        switch kind {
        case .line, .angle:
            for e in v {
                let d: CGFloat = selected ? 7 : 6
                let dot = Path(ellipseIn: CGRect(x: e.x - d / 2, y: e.y - d / 2, width: d, height: d))
                ctx.fill(dot, with: .color(color))
                ctx.stroke(dot, with: .color(.black.opacity(0.5)), lineWidth: 1)
            }
            if kind == .angle, v.count >= 3 {
                // Arc at the vertex.
                let c = v[1]
                let a1 = atan2(Double(v[0].y - c.y), Double(v[0].x - c.x))
                let a2 = atan2(Double(v[2].y - c.y), Double(v[2].x - c.x))
                var d = a2 - a1
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                let r = 22.0
                var arc = Path()
                for i in 0...20 {
                    let a = a1 + d * Double(i) / 20
                    let q = CGPoint(x: c.x + CGFloat(cos(a) * r), y: c.y + CGFloat(sin(a) * r))
                    if i == 0 { arc.move(to: q) } else { arc.addLine(to: q) }
                }
                ctx.stroke(arc, with: .color(color.opacity(0.9)), lineWidth: 1.4)
                if let text {
                    let mid = a1 + d / 2
                    label(ctx, text, at: CGPoint(x: c.x + CGFloat(cos(mid) * 44), y: c.y + CGFloat(sin(mid) * 44)), color)
                }
                return
            }
        case .count:
            for (i, e) in v.enumerated() {
                let d: CGFloat = selected ? 11 : 10
                let dot = Path(ellipseIn: CGRect(x: e.x - d / 2, y: e.y - d / 2, width: d, height: d))
                ctx.fill(dot, with: .color(color))
                ctx.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1.2)
                if v.count <= 150 {
                    let n = ctx.resolve(Text("\(i + 1)").font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(color))
                    ctx.draw(n, at: CGPoint(x: e.x + 8, y: e.y - 8), anchor: .bottomLeading)
                }
            }
            return
        default:
            break
        }

        guard let text, v.count >= 2 else { return }
        if kind == .line {
            let mid = CGPoint(x: (v[0].x + v[1].x) / 2, y: (v[0].y + v[1].y) / 2 - 16)
            label(ctx, text, at: mid, color)
        } else {
            let r = path.boundingRect
            label(ctx, text, at: CGPoint(x: r.midX, y: r.minY - 14), color)
        }
    }

    private func draftText(_ d: Draft) -> String {
        let m = Measurement(kind: d.kind, pts: d.pts)
        return store.primaryText(m)
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let dist = hypot(v.translation.width, v.translation.height)
                switch tool {
                case .pan, .count:
                    guard dist > 3 || panStart != nil else { return }
                    if panStart == nil { panStart = offset }
                    let s = panStart ?? .zero
                    offset = CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height)
                case .line, .rect, .oval:
                    guard dist > 2 else { return }
                    draft = Draft(kind: tool.kind ?? .line, pts: [imagePt(v.startLocation, size), imagePt(v.location, size)])
                case .angle:
                    guard arm == nil, dist > 2 else { return }
                    draft = Draft(kind: .angle, pts: [imagePt(v.startLocation, size), imagePt(v.location, size)])
                }
            }
            .onEnded { v in
                let dist = hypot(v.translation.width, v.translation.height)
                if panStart != nil {
                    panStart = nil
                    return
                }
                let p = imagePt(v.location, size)
                switch tool {
                case .pan:
                    if dist <= 3 { selectNearest(v.location) }
                case .count:
                    withAnimation(Theme.spring) { store.addCountPoint(p) }
                case .line, .rect, .oval:
                    if let d = draft, dist > 4 {
                        withAnimation(Theme.spring) { store.add(kind: d.kind, pts: d.pts) }
                    } else {
                        selectNearest(v.location)
                    }
                    draft = nil
                case .angle:
                    if let a = arm, a.count == 2 {
                        withAnimation(Theme.spring) { store.add(kind: .angle, pts: [a[0], a[1], p]) }
                        arm = nil
                    } else if let d = draft, dist > 4 {
                        arm = d.pts
                    } else {
                        selectNearest(v.location)
                    }
                    draft = nil
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let m = v.magnification
                guard m.isFinite, m > 0, lastMag.isFinite, lastMag > 0 else { lastMag = 1; return }
                let f = m / lastMag
                lastMag = m
                zoom(about: v.startLocation, factor: f)
            }
            .onEnded { _ in lastMag = 1 }
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if Theme.glass {
                    Color.black.opacity(0.35)
                } else {
                    LinearGradient(colors: Theme.dark ? [Color(white: 0.07), Color(white: 0.03)]
                                                      : [Color(white: 0.90), Color(white: 0.83)],
                                   startPoint: .top, endPoint: .bottom)
                }

                if let cg = adj.displayCG ?? store.shownCG {
                    if let crop = visibleCrop(cg, geo.size) {
                        Image(decorative: crop.image, scale: 1)
                            .resizable()
                            .interpolation(scale >= 3 ? Image.Interpolation.none : Image.Interpolation.high)
                            .frame(width: crop.rect.width, height: crop.rect.height)
                            .position(x: crop.rect.midX, y: crop.rect.midY)
                            .shadow(color: .black.opacity(0.5), radius: 18)
                            .opacity(imageOpacity)
                    }
                } else {
                    emptyState
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                marks

                Color.white
                    .opacity(flash)
                    .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .dropDestination(for: URL.self) { urls, _ in store.openImages(urls) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hover = p
                    if tool == .pan { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
                case .ended:
                    hover = nil
                    NSCursor.arrow.set()
                }
            }
            .overlay(alignment: .leading) { palette }
            .overlay(alignment: .topTrailing) { zoomControls }
            .overlay(alignment: .topLeading) { liveBadge }
            .overlay(alignment: .bottomLeading) { readout.allowsHitTesting(false) }
            .overlay(alignment: .bottomTrailing) { scaleBar.allowsHitTesting(false) }
            .overlay(alignment: .bottom) { hintBar.allowsHitTesting(false) }
            .overlay(alignment: .top) { toastArea.allowsHitTesting(false) }
            .onAppear {
                size = geo.size
                fit()
                installMonitor()
            }
            .onDisappear { removeMonitor() }
            .onChange(of: geo.size) { _, n in size = n }
            .onChange(of: store.fitToken) { _, _ in
                size = geo.size
                fit()
            }
            .onChange(of: store.imageID) { _, _ in
                draft = nil
                arm = nil
                imageOpacity = 0
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.35)) { imageOpacity = 1 }
                }
            }
            .onChange(of: store.flashToken) { _, _ in
                flash = 0.85
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.5)) { flash = 0 }
                }
            }
            .onChange(of: store.tool) { _, _ in
                draft = nil
                arm = nil
            }
            .animation(Theme.spring, value: store.shownCG == nil)
        }
    }

    // MARK: Layers

    private var marks: some View {
        let list = store.measurements
        let selectedID = store.selectedID
        let currentDraft = draft
        let currentArm = arm
        let hoverPt = hover
        let sampleOv: CGImage? = (sampler.showOverlay && !store.live) ? sampler.overlay : nil
        let animating = selectedID != nil || currentDraft != nil || currentArm != nil
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, sz in
                if let ov = sampleOv {
                    let tl = viewPt(.zero, sz)
                    let br = viewPt(CGPoint(x: pw, y: ph), sz)
                    let rect = CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
                    ctx.draw(ctx.resolve(Image(decorative: ov, scale: 1)), in: rect)
                }
                for m in list {
                    let sel = m.id == selectedID
                    drawMark(ctx, kind: m.kind, view: m.pts.map { viewPt($0, sz) }, text: store.primaryText(m),
                             color: sel ? Theme.markSelected : Theme.mark, selected: sel, dashed: false, t: t)
                }
                if let d = currentDraft {
                    drawMark(ctx, kind: d.kind, view: d.pts.map { viewPt($0, sz) },
                             text: d.kind == .angle ? nil : draftText(d),
                             color: Theme.accent2, selected: false, dashed: true, t: t)
                }
                if let a = currentArm, a.count == 2 {
                    var pts = a
                    if let h = hoverPt { pts.append(imagePt(h, sz)) }
                    let text: String? = pts.count == 3 ? store.primaryText(Measurement(kind: .angle, pts: pts)) : nil
                    drawMark(ctx, kind: .angle, view: pts.map { viewPt($0, sz) }, text: text,
                             color: Theme.accent2, selected: false, dashed: true, t: t)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
            Text("Nothing on screen yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Press ⌘R to capture a photo, or ⌘L for live view")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("You can also drop any picture here, or open one with ⌘O")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .allowsHitTesting(false)
    }

    private var palette: some View {
        VStack(spacing: 3) {
            ForEach(Tool.allCases) { t in
                let on = store.tool == t
                Button {
                    withAnimation(Theme.spring) { store.tool = t }
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(on ? Theme.onAccent : Theme.ink.opacity(0.72))
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Theme.gradient)
                                    .matchedGeometryEffect(id: "tool", in: ns)
                                    .shadow(color: Theme.accent.opacity(0.5), radius: 8, y: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("\(t.title)  ⌘\(t.key.character)\n\(t.hint)")
                if t == .pan {
                    Rectangle().fill(Theme.ink.opacity(0.1)).frame(width: 22, height: 1).padding(.vertical, 3)
                }
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.ink.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .opacity(store.canMeasure ? 1 : 0.5)
        .padding(12)
        .animation(Theme.spring, value: store.canMeasure)
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            roundButton("minus", "Zoom out") { zoom(about: centre, factor: 0.8) }
            Text("\(Int((min(max(scale, 0), 1000) * 100).rounded()))%")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .frame(minWidth: 48)
            roundButton("plus", "Zoom in") { zoom(about: centre, factor: 1.25) }
            Rectangle().fill(Theme.ink.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 4)
            roundButton("arrow.up.left.and.arrow.down.right", "Fit to window") { fit() }
            roundButton("1.magnifyingglass", "Actual pixels (100%)") { zoom(about: centre, factor: 1 / max(scale, 0.0001)) }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(12)
        .opacity(store.shownCG == nil ? 0 : 1)
    }

    private func roundButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }

    @ViewBuilder
    private var liveBadge: some View {
        if store.live {
            HStack(spacing: 6) {
                LiveDot(active: true)
                Text("LIVE").font(.system(size: 11, weight: .heavy)).tracking(1.2)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.red.opacity(0.5), lineWidth: 1))
            .padding(.leading, 64)
            .padding(.top, 14)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    private var readout: some View {
        var text = ""
        if let h = hover, scale > 0, pw > 0, ph > 0 {
            let q = imagePt(h, size)
            if q.x.isFinite, q.y.isFinite, q.x >= 0, q.y >= 0, q.x < pw, q.y < ph {
                let ix = Int(q.x), iy = Int(q.y)
                text = "x \(ix)  y \(iy)"
                if store.umPerPixel > 0 {
                    text += String(format: "  (%.1f, %.1f µm)", Double(ix) * store.umPerPixel, Double(iy) * store.umPerPixel)
                }
                if let c = store.rgb(x: ix, y: iy) { text += "   R \(c.0) G \(c.1) B \(c.2)" }
            }
        }
        return Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
            .opacity(text.isEmpty ? 0 : 1)
            .animation(Theme.quick, value: text.isEmpty)
    }

    @ViewBuilder
    private var scaleBar: some View {
        let u = store.umPerPixel
        if store.showScaleBar, u > 0, scale > 0, store.shownCG != nil {
            let nice = Store.niceLength(110 / Double(scale) * u)
            let w = CGFloat(nice / u) * scale
            if nice > 0, w.isFinite, w > 4 {
                VStack(spacing: 5) {
                    Text(Store.micronText(nice))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.ink)
                        .frame(width: w, height: 5)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(12)
                .animation(Theme.spring, value: nice)
                .transition(.opacity)
            }
        }
    }

    private var hintText: String {
        if store.shownCG == nil { return "" }
        if !store.canMeasure && store.tool != .pan { return "Capture a photo to measure it" }
        if arm != nil { return "Now click where the second arm ends" }
        return tool.hint
    }

    private var hintBar: some View {
        let h = hintText
        return ZStack {
            if !h.isEmpty {
                Text(h)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .id(h)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.bottom, 12)
        .animation(Theme.spring, value: h)
    }

    private var toastArea: some View {
        ZStack {
            if let t = store.toast {
                ToastView(toast: t)
                    .id(t.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 14)
        .animation(Theme.spring, value: store.toast)
    }
}
