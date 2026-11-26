import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Measure panel
//
// Results (ImageJ "Analyze > Measure" + "Summarize"), line profile
// ("Plot Profile"), Set Scale with saved scales per objective, and a scale bar
// that can be burned into an exported picture ("Flatten").

struct MeasurePanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var adj: AdjustControl
    @State private var known = "100"
    @State private var unit: LUnit = .um
    @State private var presetName = ""

    private var list: [Measurement] { store.measurements }

    var body: some View {
        PanelScroll {
            VStack(alignment: .leading, spacing: 14) {
                if list.isEmpty {
                    startCard
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else {
                    resultsCard
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }

                if let m = store.selectedMeasurement, m.kind == .line {
                    let values = store.profile(m)
                    if values.count > 1 {
                        Card(title: "Profile along line", icon: "chart.xyaxis.line") {
                            ProfileView(values: values)
                            HStack {
                                Text("grey value along the selected line")
                                Spacer()
                                Text(String(format: "%.0f–%.0f", values.min() ?? 0, values.max() ?? 0))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .id(m.id)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                scaleCard

                Card(title: "Export", icon: "square.and.arrow.up") {
                    Text("Save the picture with your measurements and the scale bar drawn on it, ready for reports.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if let cg = adj.displayCG ?? store.shownCG { store.exportAnnotated(cg) }
                    } label: {
                        Label("Export annotated image…", systemImage: "photo.badge.arrow.down")
                    }
                    .buttonStyle(PillStyle(prominent: true))
                    .disabled(!store.canMeasure)
                }
            }
            .animation(Theme.spring, value: list.isEmpty)
            .animation(Theme.spring, value: store.selectedID)
        }
    }

    // MARK: Start

    private var startCard: some View {
        Card(title: "Measure", icon: "ruler") {
            Text(store.canMeasure ? "Pick a tool, then work on the picture."
                                  : "Capture or select a photo, then pick a tool.")
                .font(.system(size: 13, weight: .medium))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Tool.allCases.filter { $0 != .pan }) { t in
                    toolChoice(t)
                }
            }
            Text("Tip: calibrate once with a stage micrometer (Scale below) and every result is shown in µm.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolChoice(_ t: Tool) -> some View {
        let on = store.tool == t
        return Button {
            withAnimation(Theme.spring) { store.tool = t }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: t.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.ink.opacity(0.08))))
                    .foregroundStyle(on ? Theme.onAccent : Color.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.system(size: 12.5, weight: .semibold))
                    Text("⌘\(String(t.key.character))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Theme.ink.opacity(0.09) : Theme.raised()))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Theme.accent.opacity(0.6) : Theme.line(0.05), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(t.hint)
    }

    // MARK: Results

    private var resultsCard: some View {
        Card(title: "Results · \(list.count)", icon: "list.bullet.rectangle") {
            VStack(spacing: 4) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                    resultRow(i, m)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity))
                }
            }

            ForEach([MKind.line, .angle, .rect, .oval], id: \.self) { k in
                if let s = store.summary(k) {
                    summaryRow(k, s)
                }
            }

            HStack(spacing: 6) {
                Button { store.undoLast() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo last (⌥⌘Z)")
                Button { store.deleteSelected() } label: { Image(systemName: "trash") }
                    .disabled(store.selectedID == nil)
                    .help("Delete selected (⌘⌫)")
                Spacer()
                Button { store.copyResults() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy results as a table for Excel or Numbers")
                Button { store.exportCSV() } label: { Label("CSV", systemImage: "tablecells") }
            }
            .buttonStyle(PillStyle())

            Button("Clear all on this picture", role: .destructive) { store.clearMeasurements() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func resultRow(_ i: Int, _ m: Measurement) -> some View {
        let sel = store.selectedID == m.id
        return HStack(spacing: 10) {
            Image(systemName: m.kind.icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(sel ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.ink.opacity(0.08))))
                .foregroundStyle(sel ? Theme.onAccent : Color.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.primaryText(m))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                let sub = store.secondaryText(m)
                Text(sub.isEmpty ? m.kind.title : "\(m.kind.title) · \(sub)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(i + 1)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(sel ? Theme.accent.opacity(0.14) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(sel ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.spring) { store.selectedID = sel ? nil : m.id }
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                store.selectedID = m.id
                store.deleteSelected()
            }
        }
    }

    private func summaryRow(_ k: MKind, _ s: (n: Int, mean: Double, sd: Double, lo: Double, hi: Double)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(k.title) · n = \(s.n)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("mean \(store.summaryValueText(k, s.mean))  ±  \(store.summaryValueText(k, s.sd))")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text("range \(store.summaryValueText(k, s.lo)) – \(store.summaryValueText(k, s.hi))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
    }

    // MARK: Scale

    private var lineSelected: Bool { store.selectedMeasurement?.kind == .line }

    private var scaleCard: some View {
        Card(title: "Scale", icon: "ruler.fill") {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.umPerPixel > 0 ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.umPerPixel > 0 ? String(format: "1 px = %.4f µm", store.umPerPixel) : "Not calibrated")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(store.activePreset.map { "Using “\($0.name)”" }
                         ?? (store.umPerPixel > 0 ? "Custom scale" : "Results are in pixels"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.umPerPixel > 0 {
                    Button("Clear") { withAnimation(Theme.spring) { store.umPerPixel = 0 } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if !store.presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.presets) { p in
                            let on = store.activePreset?.id == p.id
                            Button(p.name) { store.applyPreset(p) }
                                .buttonStyle(PillStyle(prominent: on))
                                .contextMenu {
                                    Button("Delete “\(p.name)”", role: .destructive) { store.deletePreset(p) }
                                }
                                .help(String(format: "1 px = %.4f µm", p.umPerPixel))
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(lineSelected ? "The selected line is really:" : "Draw a Length line over a ruler or stage micrometer and select it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TextField("Length", text: $known)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .frame(width: 62, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))
                    Picker("", selection: $unit) {
                        ForEach(LUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 78)
                    Spacer(minLength: 0)
                    Button("Set scale") {
                        let v = Double(known.replacingOccurrences(of: ",", with: ".")) ?? 0
                        withAnimation(Theme.spring) { store.calibrate(known: v, unit: unit) }
                    }
                    .buttonStyle(PillStyle(prominent: lineSelected))
                    .disabled(!lineSelected)
                }
            }

            if store.umPerPixel > 0 && store.activePreset == nil {
                HStack(spacing: 6) {
                    TextField("Name, e.g. 10× objective", text: $presetName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))
                        .onSubmit { save() }
                    Button("Save") { save() }
                        .buttonStyle(PillStyle())
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Toggle("Show scale bar on picture", isOn: $store.showScaleBar)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5, weight: .medium))
                .disabled(store.umPerPixel <= 0)
        }
        .animation(Theme.spring, value: store.umPerPixel > 0)
        .animation(Theme.spring, value: store.activePreset)
        .animation(Theme.spring, value: store.presets)
    }

    private func save() {
        withAnimation(Theme.spring) { store.savePreset(name: presetName) }
        presetName = ""
    }
}

// MARK: - Profile plot

struct ProfileView: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, s in
            guard values.count > 1, s.width > 0, s.height > 0 else { return }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 255
            let span = max(hi - lo, 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) / CGFloat(values.count - 1) * s.width
                let y = s.height - 4 - CGFloat((v - lo) / span) * (s.height - 8)
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: s.width, y: s.height))
            fill.addLine(to: CGPoint(x: 0, y: s.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.4), Theme.accent.opacity(0)]),
                                                startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))
            ctx.stroke(line, with: .color(Theme.accent2), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .frame(height: 90)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
    }
}

// MARK: - Export with annotations ("Flatten")

extension Store {
    func exportAnnotated(_ cg: CGImage) {
        guard let base = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = base.deletingPathExtension().lastPathComponent + "_annotated.png"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        var bar: (px: Double, text: String)?
        if showScaleBar, umPerPixel > 0 {
            let um = Store.niceLength(Double(cg.width) / 5 * umPerPixel)
            if um > 0 { bar = (um / umPerPixel, Store.micronText(um)) }
        }
        guard let out = Store.flatten(cg, measurements, label: { self.primaryText($0) }, bar: bar) else {
            notify("Could not draw the annotations.", icon: "exclamationmark.triangle.fill", error: true)
            return
        }
        let isJPEG = dest.pathExtension.lowercased() == "jpg" || dest.pathExtension.lowercased() == "jpeg"
        let type = isJPEG ? UTType.jpeg : UTType.png
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else {
            notify("Could not create the file.", icon: "exclamationmark.triangle.fill", error: true)
            return
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(d, out, opts as CFDictionary)
        if CGImageDestinationFinalize(d) {
            notify("Exported \(dest.lastPathComponent)", icon: "photo.fill")
        } else {
            notify("Could not save the image.", icon: "exclamationmark.triangle.fill", error: true)
        }
    }

    static func flatten(_ cg: CGImage, _ list: [Measurement], label: (Measurement) -> String,
                        bar: (px: Double, text: String)?) -> CGImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // From here on y runs downwards, like image pixel coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let k = max(CGFloat(max(w, h)) / 1400, 1)
        let yellow = NSColor(red: 1, green: 0.84, blue: 0.3, alpha: 1)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3 * k
        shadow.shadowOffset = .zero

        func text(_ s: String, centre p: CGPoint, size: CGFloat, color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * k, weight: .semibold),
                .foregroundColor: color,
                .shadow: shadow
            ]
            let a = NSAttributedString(string: s, attributes: attrs)
            let sz = a.size()
            a.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for m in list {
            ctx.setStrokeColor(yellow.cgColor)
            ctx.setFillColor(yellow.cgColor)
            ctx.setLineWidth(2 * k)
            switch m.kind {
            case .line:
                ctx.move(to: m.a)
                ctx.addLine(to: m.b)
                ctx.strokePath()
                for e in [m.a, m.b] {
                    ctx.fillEllipse(in: CGRect(x: e.x - 3 * k, y: e.y - 3 * k, width: 6 * k, height: 6 * k))
                }
                text(label(m), centre: CGPoint(x: (m.a.x + m.b.x) / 2, y: (m.a.y + m.b.y) / 2 - 16 * k),
                     size: 15, color: yellow)
            case .angle:
                guard m.pts.count >= 3 else { continue }
                ctx.move(to: m.pts[0])
                ctx.addLine(to: m.pts[1])
                ctx.addLine(to: m.pts[2])
                ctx.strokePath()
                text(label(m), centre: CGPoint(x: m.pts[1].x, y: m.pts[1].y - 22 * k), size: 15, color: yellow)
            case .rect, .oval:
                let r = m.rect
                if m.kind == .rect { ctx.stroke(r) } else { ctx.strokeEllipse(in: r) }
                text(label(m), centre: CGPoint(x: r.midX, y: r.minY - 14 * k), size: 15, color: yellow)
            case .count:
                for (i, e) in m.pts.enumerated() {
                    ctx.fillEllipse(in: CGRect(x: e.x - 5 * k, y: e.y - 5 * k, width: 10 * k, height: 10 * k))
                    text("\(i + 1)", centre: CGPoint(x: e.x + 12 * k, y: e.y - 10 * k), size: 11, color: yellow)
                }
            }
        }

        if let bar, bar.px > 0 {
            let margin = 24 * k
            let barH = 8 * k
            let x1 = CGFloat(w) - margin
            let x0 = x1 - CGFloat(bar.px)
            let y = CGFloat(h) - margin - barH
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            let boxH = 46 * k
            let back = CGRect(x: x0 - 12 * k, y: y - boxH + barH + 6 * k, width: CGFloat(bar.px) + 24 * k, height: boxH)
            ctx.addPath(CGPath(roundedRect: back, cornerWidth: 8 * k, cornerHeight: 8 * k, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: x0, y: y, width: CGFloat(bar.px), height: barH))
            text(bar.text, centre: CGPoint(x: (x0 + x1) / 2, y: y - 14 * k), size: 16, color: .white)
        }

        return ctx.makeImage()
    }
}
