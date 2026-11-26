import Foundation

// MARK: - Sample detection and analysis (core)
//
// Everything in this file works on plain arrays, so it can run on a background
// thread and has no UI in it. Nothing here is AI: it is classical image analysis
// (colour statistics, thresholding, distance transform, seeded region growing,
// line intercepts) that anyone can check against ImageJ.
//
//  1. detectSample  looks at colour, brightness and texture and decides whether the
//                   picture is an onion peel, a leaf or a metal piece.
//  2. analyzeOnion  cells, cell size, nuclei, stain colour.
//  3. analyzeLeaf   cells, stomata, stomatal density and index, green coverage.
//  4. analyzeMetal  grain size (ASTM E112 line intercept), phases, pores, scratches.

enum SampleKind: String, CaseIterable, Identifiable {
    case onion, leaf, metal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onion: return "Onion peel"
        case .leaf: return "Leaf"
        case .metal: return "Metal piece"
        }
    }

    var short: String {
        switch self {
        case .onion: return "Onion"
        case .leaf: return "Leaf"
        case .metal: return "Metal"
        }
    }

    var icon: String {
        switch self {
        case .onion: return "circle.grid.3x3.fill"
        case .leaf: return "leaf.fill"
        case .metal: return "hammer.fill"
        }
    }
}

struct SImage {
    let w: Int
    let h: Int
    /// RGBA bytes, top row first.
    let rgba: [UInt8]
}

struct SRow: Identifiable {
    let id = UUID()
    var label: String
    var value: String
}

struct SDetection {
    /// nil means "could not tell".
    var kind: SampleKind?
    /// 0...1
    var confidence: Double
    var scores: [SampleKind: Double]
    var reasons: [String]
}

struct SResult {
    var kind: SampleKind
    var rows: [SRow]
    var notes: [String]
    /// RGBA, same size as the analysed picture (w x h). Transparent where nothing is marked.
    var overlay: [UInt8]
    var w: Int
    var h: Int
}

struct SOutput {
    var detection: SDetection
    var result: SResult?
}

/// Turns analysed-picture pixels into real units (when the microscope is calibrated).
struct SUnits {
    /// Full-resolution pixels per analysed pixel.
    let scale: Double
    /// Micrometres per full-resolution pixel. 0 = not calibrated.
    let umPerFullPx: Double

    var calibrated: Bool { umPerFullPx > 0 }

    func um(_ anaPx: Double) -> Double { anaPx * scale * umPerFullPx }

    func length(_ anaPx: Double) -> String {
        if calibrated {
            let u = um(anaPx)
            return u >= 1000 ? String(format: "%.3f mm", u / 1000) : String(format: "%.1f µm", u)
        }
        return String(format: "%.0f px", anaPx * scale)
    }

    func area(_ anaPx2: Double) -> String {
        if calibrated {
            let u2 = anaPx2 * scale * scale * umPerFullPx * umPerFullPx
            return u2 >= 1_000_000 ? String(format: "%.4f mm²", u2 / 1_000_000) : String(format: "%.0f µm²", u2)
        }
        return String(format: "%.0f px²", anaPx2 * scale * scale)
    }

    /// Area in mm² of `anaPx2` analysed pixels (0 if not calibrated).
    func mm2(_ anaPx2: Double) -> Double {
        guard calibrated else { return 0 }
        return anaPx2 * scale * scale * umPerFullPx * umPerFullPx / 1_000_000
    }
}

// MARK: - Small helpers

func clamp01(_ x: Double) -> Double { x < 0 ? 0 : (x > 1 ? 1 : x) }

func meanStd(_ v: [Float]) -> (mean: Float, sd: Float) {
    guard !v.isEmpty else { return (0, 0) }
    var s = 0.0
    var s2 = 0.0
    for x in v {
        let d = Double(x)
        s += d
        s2 += d * d
    }
    let n = Double(v.count)
    let m = s / n
    return (Float(m), Float(max(s2 / n - m * m, 0).squareRoot()))
}

func grayFloat(_ img: SImage) -> [Float] {
    let n = img.w * img.h
    var g = [Float](repeating: 0, count: n)
    img.rgba.withUnsafeBufferPointer { p in
        for i in 0..<n {
            let j = i * 4
            g[i] = 0.299 * Float(p[j]) + 0.587 * Float(p[j + 1]) + 0.114 * Float(p[j + 2])
        }
    }
    return g
}

/// Average blocks of k x k pixels so the picture is at most `maxSide` on its long side.
func shrink(_ img: SImage, maxSide: Int) -> SImage {
    let long = max(img.w, img.h)
    if long <= maxSide { return img }
    let k = Int((Double(long) / Double(maxSide)).rounded(.up))
    let w = img.w / k
    let h = img.h / k
    guard w > 0, h > 0 else { return img }
    var out = [UInt8](repeating: 255, count: w * h * 4)
    let div = k * k
    img.rgba.withUnsafeBufferPointer { p in
        for y in 0..<h {
            for x in 0..<w {
                var r = 0
                var g = 0
                var b = 0
                for yy in 0..<k {
                    var j = ((y * k + yy) * img.w + x * k) * 4
                    for _ in 0..<k {
                        r += Int(p[j])
                        g += Int(p[j + 1])
                        b += Int(p[j + 2])
                        j += 4
                    }
                }
                let o = (y * w + x) * 4
                out[o] = UInt8(r / div)
                out[o + 1] = UInt8(g / div)
                out[o + 2] = UInt8(b / div)
                out[o + 3] = 255
            }
        }
    }
    return SImage(w: w, h: h, rgba: out)
}

/// Box blur with clamped edges, O(n) for any radius.
func boxBlur(_ src: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
    if r <= 0 { return src }
    var tmp = [Float](repeating: 0, count: w * h)
    var out = [Float](repeating: 0, count: w * h)
    let k = Float(2 * r + 1)
    for y in 0..<h {
        let row = y * w
        var sum: Float = 0
        for i in -r...r { sum += src[row + min(max(i, 0), w - 1)] }
        for x in 0..<w {
            tmp[row + x] = sum / k
            let add = min(x + r + 1, w - 1)
            let sub = max(x - r, 0)
            sum += src[row + add] - src[row + sub]
        }
    }
    for x in 0..<w {
        var sum: Float = 0
        for i in -r...r { sum += tmp[min(max(i, 0), h - 1) * w + x] }
        for y in 0..<h {
            out[y * w + x] = sum / k
            let add = min(y + r + 1, h - 1)
            let sub = max(y - r, 0)
            sum += tmp[add * w + x] - tmp[sub * w + x]
        }
    }
    return out
}

/// Grey-level minimum or maximum filter with a (2r+1) square window (separable).
func morph(_ src: [Float], _ w: Int, _ h: Int, _ r: Int, wantMax: Bool) -> [Float] {
    var tmp = src
    var out = src
    for y in 0..<h {
        let row = y * w
        for x in 0..<w {
            var m = src[row + x]
            let a = max(x - r, 0)
            let b = min(x + r, w - 1)
            var xx = a
            while xx <= b {
                let v = src[row + xx]
                if (wantMax && v > m) || (!wantMax && v < m) { m = v }
                xx += 1
            }
            tmp[row + x] = m
        }
    }
    for x in 0..<w {
        for y in 0..<h {
            var m = tmp[y * w + x]
            let a = max(y - r, 0)
            let b = min(y + r, h - 1)
            var yy = a
            while yy <= b {
                let v = tmp[yy * w + x]
                if (wantMax && v > m) || (!wantMax && v < m) { m = v }
                yy += 1
            }
            out[y * w + x] = m
        }
    }
    return out
}

/// Otsu threshold of float values between lo and hi. `eta` is how two-humped the data is (0...1).
func otsuFloat(_ v: [Float], lo: Float, hi: Float) -> (t: Float, eta: Float) {
    let bins = 256
    guard hi > lo, !v.isEmpty else { return (lo, 0) }
    var hist = [Double](repeating: 0, count: bins)
    let k = Float(bins) / (hi - lo)
    for x in v {
        var b = Int((x - lo) * k)
        if b < 0 { b = 0 } else if b >= bins { b = bins - 1 }
        hist[b] += 1
    }
    let total = hist.reduce(0, +)
    guard total > 0 else { return (lo, 0) }
    var sumAll = 0.0
    for i in 0..<bins { sumAll += Double(i) * hist[i] }
    let mean = sumAll / total
    var varT = 0.0
    for i in 0..<bins {
        let d = Double(i) - mean
        varT += hist[i] * d * d
    }
    varT /= total
    var wB = 0.0
    var sumB = 0.0
    var best = 0.0
    var bestI = 0
    for i in 0..<bins {
        wB += hist[i]
        if wB == 0 { continue }
        let wF = total - wB
        if wF == 0 { break }
        sumB += Double(i) * hist[i]
        let mB = sumB / wB
        let mF = (sumAll - sumB) / wF
        let between = wB * wF * (mB - mF) * (mB - mF) / (total * total)
        if between > best {
            best = between
            bestI = i
        }
    }
    let t = lo + (Float(bestI) + 1) / k
    let eta: Float = varT > 0 ? Float(min(best / varT, 1)) : 0
    return (t, eta)
}

/// Distance (in pixels) from every True pixel to the nearest False pixel. The picture edge does not count as background.
func distanceTransform(_ mask: [Bool], _ w: Int, _ h: Int) -> [Float] {
    let big: Int32 = 1 << 20
    var d = [Int32](repeating: 0, count: w * h)
    for i in 0..<(w * h) where mask[i] { d[i] = big }
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            if d[i] == 0 { continue }
            var v = d[i]
            if x > 0 { v = min(v, d[i - 1] + 3) }
            if y > 0 {
                v = min(v, d[i - w] + 3)
                if x > 0 { v = min(v, d[i - w - 1] + 4) }
                if x < w - 1 { v = min(v, d[i - w + 1] + 4) }
            }
            d[i] = v
        }
    }
    var y = h - 1
    while y >= 0 {
        var x = w - 1
        while x >= 0 {
            let i = y * w + x
            if d[i] != 0 {
                var v = d[i]
                if x < w - 1 { v = min(v, d[i + 1] + 3) }
                if y < h - 1 {
                    v = min(v, d[i + w] + 3)
                    if x < w - 1 { v = min(v, d[i + w + 1] + 4) }
                    if x > 0 { v = min(v, d[i + w - 1] + 4) }
                }
                d[i] = v
            }
            x -= 1
        }
        y -= 1
    }
    var out = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        out[i] = d[i] >= big ? 1000 : Float(d[i]) / 3
    }
    return out
}

/// Connected components. Labels start at 1; 0 is background.
func labelComponents(_ mask: [Bool], _ w: Int, _ h: Int, eight: Bool) -> (labels: [Int32], count: Int) {
    var labels = [Int32](repeating: 0, count: w * h)
    var parent: [Int32] = [0]

    func find(_ v: Int32) -> Int32 {
        var r = v
        while parent[Int(r)] != r { r = parent[Int(r)] }
        var c = v
        while parent[Int(c)] != r {
            let nx = parent[Int(c)]
            parent[Int(c)] = r
            c = nx
        }
        return r
    }

    func union(_ a: Int32, _ b: Int32) {
        let ra = find(a)
        let rb = find(b)
        if ra == rb { return }
        if ra < rb { parent[Int(rb)] = ra } else { parent[Int(ra)] = rb }
    }

    var next: Int32 = 1
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            if !mask[i] { continue }
            var a: Int32 = 0
            var b: Int32 = 0
            var c: Int32 = 0
            var d: Int32 = 0
            if x > 0 { a = labels[i - 1] }
            if y > 0 { b = labels[i - w] }
            if eight && y > 0 && x > 0 { c = labels[i - w - 1] }
            if eight && y > 0 && x < w - 1 { d = labels[i - w + 1] }
            var best: Int32 = 0
            if a != 0 { best = a }
            if b != 0 && (best == 0 || b < best) { best = b }
            if c != 0 && (best == 0 || c < best) { best = c }
            if d != 0 && (best == 0 || d < best) { best = d }
            if best == 0 {
                labels[i] = next
                parent.append(next)
                next += 1
            } else {
                labels[i] = best
                if a != 0 { union(a, best) }
                if b != 0 { union(b, best) }
                if c != 0 { union(c, best) }
                if d != 0 { union(d, best) }
            }
        }
    }
    var remap = [Int32](repeating: 0, count: parent.count)
    var count: Int32 = 0
    if parent.count > 1 {
        for l in 1..<parent.count {
            let root = Int(find(Int32(l)))
            if remap[root] == 0 {
                count += 1
                remap[root] = count
            }
            remap[l] = remap[root]
        }
    }
    for i in 0..<(w * h) where labels[i] != 0 {
        labels[i] = remap[Int(labels[i])]
    }
    return (labels, Int(count))
}

struct SRegion {
    var area = 0
    var sx = 0.0
    var sy = 0.0
    var sxx = 0.0
    var syy = 0.0
    var sxy = 0.0
    var minX = Int.max
    var minY = Int.max
    var maxX = -1
    var maxY = -1
    var touchesBorder = false

    var cx: Double { area > 0 ? sx / Double(area) : 0 }
    var cy: Double { area > 0 ? sy / Double(area) : 0 }

    /// Variances along the major and minor axis.
    var eig: (Double, Double) {
        guard area > 1 else { return (0.1, 0.1) }
        let n = Double(area)
        let mx = sx / n
        let my = sy / n
        let a = sxx / n - mx * mx + 1.0 / 12.0
        let c = syy / n - my * my + 1.0 / 12.0
        let b = sxy / n - mx * my
        let t = (a + c) / 2
        let d = ((a - c) * (a - c) / 4 + b * b).squareRoot()
        return (t + d, max(t - d, 1e-9))
    }

    var major: Double { 4 * eig.0.squareRoot() }
    var minor: Double { 4 * eig.1.squareRoot() }
    var aspect: Double { (eig.0 / eig.1).squareRoot() }
    var eqDiameter: Double { 2 * (Double(area) / Double.pi).squareRoot() }
}

func regionsOf(_ labels: [Int32], _ count: Int, _ w: Int, _ h: Int) -> [SRegion] {
    var r = [SRegion](repeating: SRegion(), count: count + 1)
    for y in 0..<h {
        for x in 0..<w {
            let l = Int(labels[y * w + x])
            if l == 0 { continue }
            let fx = Double(x)
            let fy = Double(y)
            r[l].area += 1
            r[l].sx += fx
            r[l].sy += fy
            r[l].sxx += fx * fx
            r[l].syy += fy * fy
            r[l].sxy += fx * fy
            if x < r[l].minX { r[l].minX = x }
            if x > r[l].maxX { r[l].maxX = x }
            if y < r[l].minY { r[l].minY = y }
            if y > r[l].maxY { r[l].maxY = y }
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { r[l].touchesBorder = true }
        }
    }
    return r
}

/// Grows labelled seeds outward inside a mask (breadth first, so each pixel joins its nearest seed).
func growSeeds(_ seeds: [Int32], inside: [Bool], _ w: Int, _ h: Int) -> [Int32] {
    var lab = seeds
    var queue = [Int32]()
    queue.reserveCapacity(w * h / 2)
    for i in 0..<(w * h) where seeds[i] != 0 { queue.append(Int32(i)) }
    var head = 0
    while head < queue.count {
        let i = Int(queue[head])
        head += 1
        let l = lab[i]
        let x = i % w
        let y = i / w
        if x > 0 {
            let j = i - 1
            if inside[j] && lab[j] == 0 { lab[j] = l; queue.append(Int32(j)) }
        }
        if x < w - 1 {
            let j = i + 1
            if inside[j] && lab[j] == 0 { lab[j] = l; queue.append(Int32(j)) }
        }
        if y > 0 {
            let j = i - w
            if inside[j] && lab[j] == 0 { lab[j] = l; queue.append(Int32(j)) }
        }
        if y < h - 1 {
            let j = i + w
            if inside[j] && lab[j] == 0 { lab[j] = l; queue.append(Int32(j)) }
        }
    }
    return lab
}

func dilate3(_ m: [Bool], _ w: Int, _ h: Int) -> [Bool] {
    var tmp = m
    var out = m
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            if m[i] { continue }
            if (x > 0 && m[i - 1]) || (x < w - 1 && m[i + 1]) { tmp[i] = true }
        }
    }
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            if tmp[i] { out[i] = true; continue }
            if (y > 0 && tmp[i - w]) || (y < h - 1 && tmp[i + w]) { out[i] = true }
        }
    }
    return out
}

func zeroBorder(_ a: inout [Float], _ w: Int, _ h: Int, _ m: Int) {
    for y in 0..<h {
        for x in 0..<w where x < m || y < m || x >= w - m || y >= h - m {
            a[y * w + x] = 0
        }
    }
}

// MARK: - Colour

func hsvOf(_ r: Float, _ g: Float, _ b: Float) -> (h: Float, s: Float, v: Float) {
    let mx = max(r, max(g, b))
    let mn = min(r, min(g, b))
    let d = mx - mn
    let v = mx / 255
    let s: Float = mx <= 0 ? 0 : d / mx
    var hue: Float = 0
    if d > 0 {
        if mx == r {
            var t = (g - b) / d
            if t < 0 { t += 6 }
            hue = 60 * t
        } else if mx == g {
            hue = 60 * ((b - r) / d + 2)
        } else {
            hue = 60 * ((r - g) / d + 4)
        }
        if hue < 0 { hue += 360 }
        if hue >= 360 { hue -= 360 }
    }
    return (hue, s, v)
}

func colorName(_ r: Double, _ g: Double, _ b: Double) -> String {
    let c = hsvOf(Float(r), Float(g), Float(b))
    if c.s < 0.10 { return c.v > 0.75 ? "colourless / pale" : "grey" }
    let h = Double(c.h)
    let dark = c.v < 0.55
    switch h {
    case 0..<15, 345...360: return dark ? "dark red" : "red"
    case 15..<45: return dark ? "brown" : "orange / amber"
    case 45..<70: return dark ? "olive" : "yellow"
    case 70..<170: return dark ? "dark green" : "green"
    case 170..<200: return "cyan / teal"
    case 200..<260: return dark ? "dark blue" : "blue"
    case 260..<300: return dark ? "dark purple" : "purple / violet"
    default: return dark ? "dark magenta" : "pink / magenta"
    }
}

// MARK: - Cell segmentation (onion cells, leaf cells)
//
// 1. Remove uneven lighting (subtract a very blurred copy).
// 2. Otsu threshold: cell interiors on one side, walls on the other.
// 3. Small dark islands inside cells (nuclei) are filled in and remembered.
// 4. Distance transform + one seed per rounded "core" splits touching cells.
// 5. Seeds grow back to the cell walls.

struct CellSeg {
    var labels: [Int32]
    var count: Int
    var regions: [SRegion]
    /// Pixels of nucleus-like islands (label per island, 0 elsewhere) and their regions.
    var nucLabels: [Int32]
    var nucRegions: [SRegion]
    var nucCount: Int
}

func flatField(_ gray: [Float], _ w: Int, _ h: Int) -> [Float] {
    let long = max(w, h)
    let sm = boxBlur(gray, w, h, 1)
    let bg = boxBlur(sm, w, h, max(long / 12, 8))
    var out = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { out[i] = sm[i] - bg[i] }
    return out
}

func segmentCells(_ norm: [Float], _ w: Int, _ h: Int) -> CellSeg {
    let n = w * h
    let sd = meanStd(norm).sd
    let (t, _) = otsuFloat(norm, lo: -3 * max(sd, 0.5), hi: 3 * max(sd, 0.5))
    var interior = [Bool](repeating: false, count: n)
    var wall = [Bool](repeating: false, count: n)
    for i in 0..<n {
        let inside = norm[i] > t
        interior[i] = inside
        wall[i] = !inside
    }

    // Islands of "wall" that are small and enclosed are holes (nuclei, grains of dirt): fill them.
    let (wl, nw) = labelComponents(wall, w, h, eight: true)
    let wr = regionsOf(wl, nw, w, h)
    let dtw = distanceTransform(wall, w, h)
    var maxDT = [Float](repeating: 0, count: nw + 1)
    for i in 0..<n {
        let l = Int(wl[i])
        if l != 0 && dtw[i] > maxDT[l] { maxDT[l] = dtw[i] }
    }
    let holeMax = max(30, Int(0.0004 * Double(n)))
    var isHole = [Bool](repeating: false, count: nw + 1)
    var isNuc = [Bool](repeating: false, count: nw + 1)
    if nw > 0 {
        for l in 1...nw {
            let r = wr[l]
            if r.area < holeMax && !r.touchesBorder {
                isHole[l] = true
                if maxDT[l] >= 2.5 && r.aspect <= 3 && r.area >= 12 { isNuc[l] = true }
            }
        }
    }
    var nucLab = [Int32](repeating: 0, count: n)
    var nucList = [Int32](repeating: 0, count: nw + 1)
    var nucCount: Int32 = 0
    if nw > 0 {
        for l in 1...nw where isNuc[l] {
            nucCount += 1
            nucList[l] = nucCount
        }
    }
    for i in 0..<n {
        let l = Int(wl[i])
        if l != 0 && isHole[l] {
            interior[i] = true
            if isNuc[l] { nucLab[i] = nucList[l] }
        }
    }
    let nucRegions = regionsOf(nucLab, Int(nucCount), w, h)

    // Cores: the rounded middle of every cell.
    let dt = distanceTransform(interior, w, h)
    var eroded = [Bool](repeating: false, count: n)
    for i in 0..<n { eroded[i] = dt[i] >= 2 }
    let (l2, n2) = labelComponents(eroded, w, h, eight: false)
    var peak = [Float](repeating: 0, count: n2 + 1)
    for i in 0..<n {
        let l = Int(l2[i])
        if l != 0 && dt[i] > peak[l] { peak[l] = dt[i] }
    }
    var cores = [Bool](repeating: false, count: n)
    for i in 0..<n {
        let l = Int(l2[i])
        if l != 0 && dt[i] >= max(2, 0.6 * peak[l]) { cores[i] = true }
    }
    let (seeds, ns) = labelComponents(cores, w, h, eight: false)
    let labels = growSeeds(seeds, inside: interior, w, h)
    let regions = regionsOf(labels, ns, w, h)
    return CellSeg(labels: labels, count: ns, regions: regions,
                   nucLabels: nucLab, nucRegions: nucRegions, nucCount: Int(nucCount))
}

/// How cell-like a segmentation is, 0...1, and the bits needed to compare two attempts.
func cellQuality(_ seg: CellSeg, _ n: Int) -> (quality: Double, coverage: Double, valid: Int, cv: Double) {
    var areas: [Double] = []
    var covered = 0
    let minA = max(25, n / 20000)
    let maxA = n / 3
    if seg.count > 0 {
        for l in 1...seg.count {
            let a = seg.regions[l].area
            if a >= minA && a <= maxA {
                areas.append(Double(a))
                covered += a
            }
        }
    }
    let cov = Double(covered) / Double(max(n, 1))
    guard areas.count >= 3 else { return (0, cov, areas.count, 1) }
    let m = areas.reduce(0, +) / Double(areas.count)
    var v = 0.0
    for a in areas { v += (a - m) * (a - m) }
    let sdv = (v / Double(areas.count)).squareRoot()
    let cv = m > 0 ? sdv / m : 1
    let q = clamp01((cov - 0.35) / 0.35) * clamp01((1.1 - cv) / 0.7) * clamp01(Double(areas.count) / 12)
    return (q, cov, areas.count, cv)
}

/// Tries bright interiors first (the usual case) and dark interiors if that does not look like cells.
func bestCellSegmentation(_ gray: [Float], _ w: Int, _ h: Int) -> CellSeg {
    let norm = flatField(gray, w, h)
    let a = segmentCells(norm, w, h)
    let qa = cellQuality(a, w * h)
    if qa.valid >= 10 && qa.coverage >= 0.45 { return a }
    var inv = norm
    for i in 0..<inv.count { inv[i] = -inv[i] }
    let b = segmentCells(inv, w, h)
    let qb = cellQuality(b, w * h)
    return qb.quality > qa.quality ? b : a
}

// MARK: - Overlay painting

func paint(_ ov: inout [UInt8], _ w: Int, _ h: Int, _ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
    guard x >= 0, y >= 0, x < w, y < h else { return }
    let j = (y * w + x) * 4
    ov[j] = c.0
    ov[j + 1] = c.1
    ov[j + 2] = c.2
    ov[j + 3] = 255
}

/// Draws the outline of every label for which `keep` is true.
func paintOutlines(_ labels: [Int32], keep: [Bool], _ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8), into ov: inout [UInt8]) {
    guard w > 2, h > 2 else { return }
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            let l = labels[i]
            if l == 0 || !keep[Int(l)] { continue }
            if labels[i - 1] != l || labels[i + 1] != l || labels[i - w] != l || labels[i + w] != l {
                paint(&ov, w, h, x, y, c)
                paint(&ov, w, h, x + 1, y, c)
                paint(&ov, w, h, x, y + 1, c)
            }
        }
    }
}

func paintRing(_ ov: inout [UInt8], _ w: Int, _ h: Int, cx: Double, cy: Double, radius: Double, width: Double, _ c: (UInt8, UInt8, UInt8)) {
    let r0 = radius + width
    let x0 = Int((cx - r0).rounded(.down)) - 1
    let x1 = Int((cx + r0).rounded(.up)) + 1
    let y0 = Int((cy - r0).rounded(.down)) - 1
    let y1 = Int((cy + r0).rounded(.up)) + 1
    guard x1 >= x0, y1 >= y0 else { return }
    for y in y0...y1 {
        for x in x0...x1 {
            let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
            if abs(d - radius) <= width / 2 { paint(&ov, w, h, x, y, c) }
        }
    }
}

// MARK: - 1. Detecting the sample

func detectSample(_ img: SImage) -> SDetection {
    let small = shrink(img, maxSide: 400)
    let w = small.w
    let h = small.h
    let n = w * h
    guard n > 100 else { return SDetection(kind: nil, confidence: 0, scores: [:], reasons: ["The picture is too small."]) }

    var sumS = 0.0
    var sumV = 0.0
    var green = 0
    var stain = 0
    var warm = 0
    var colored = 0
    var bright = 0
    var gray = [Float](repeating: 0, count: n)
    small.rgba.withUnsafeBufferPointer { p in
        for i in 0..<n {
            let r = Float(p[i * 4])
            let g = Float(p[i * 4 + 1])
            let b = Float(p[i * 4 + 2])
            gray[i] = 0.299 * r + 0.587 * g + 0.114 * b
            let c = hsvOf(r, g, b)
            sumS += Double(c.s)
            sumV += Double(c.v)
            let hue = c.h
            if hue > 70 && hue < 170 && c.s > 0.18 && c.v > 0.12 { green += 1 }
            if (hue >= 270 || hue <= 15) && c.s > 0.10 { stain += 1 }
            if hue > 180 && hue < 260 && c.s > 0.10 { stain += 1 }
            if hue > 15 && hue < 65 && c.s > 0.12 { warm += 1 }
            if c.s > 0.20 && c.v > 0.15 { colored += 1 }
            if c.v > 0.80 && c.s < 0.25 { bright += 1 }
        }
    }
    let fn = Double(n)
    let meanS = sumS / fn
    let meanV = sumV / fn
    let greenShare = Double(green) / fn
    let stainShare = Double(stain) / fn
    let warmShare = Double(warm) / fn
    let coloredShare = Double(colored) / fn
    _ = bright

    // Texture: how much fine edge detail, and how widely the grey values spread.
    let gs = meanStd(gray)
    let sdGray = Double(gs.sd) / 255
    var edges = 0
    for y in 0..<(h - 1) {
        for x in 0..<(w - 1) {
            let i = y * w + x
            let g = abs(gray[i + 1] - gray[i]) + abs(gray[i + w] - gray[i])
            if g > 0.06 * 255 { edges += 1 }
        }
    }
    let edgeShare = Double(edges) / fn

    // Is there a cell-like network?
    let seg = bestCellSegmentation(gray, w, h)
    let q = cellQuality(seg, n)
    let cellness = q.quality

    // Scores, each 0...1.
    let greenScore = clamp01(greenShare / 0.18)
    var leaf = 0.85 * greenScore + 0.15 * clamp01((meanS - 0.12) / 0.25) * (greenShare > 0.05 ? 1 : 0)

    let lowChroma = clamp01((0.20 - meanS) / 0.14)
    let notPale = clamp01((0.88 - meanV) / 0.25)
    let texture = 0.5 * clamp01(edgeShare / 0.08) + 0.5 * clamp01(sdGray / 0.10)
    let pale = clamp01((meanV - 0.80) / 0.12)
    var metal = 0.55 * lowChroma + 0.20 * notPale + 0.25 * texture
    metal *= (1 - 0.6 * pale)
    metal *= (1 - 0.7 * greenScore)

    let tint = clamp01((stainShare + warmShare) / 0.30)
    let brightScore = clamp01((meanV - 0.55) / 0.30)
    let midChroma = clamp01(meanS / 0.08) * clamp01((0.45 - meanS) / 0.20)
    // Stain tint and a cell-like network only count fully when the background is pale and see-through.
    let tintEff = tint * (0.4 + 0.6 * brightScore)
    let cellEff = cellness * (0.5 + 0.5 * brightScore)
    var onion = 0.20 * tintEff + 0.35 * brightScore + 0.15 * midChroma + 0.20 * cellEff
    onion *= (1 - 0.8 * greenScore)

    leaf = clamp01(leaf)
    metal = clamp01(metal)
    onion = clamp01(onion)

    let scores: [SampleKind: Double] = [.onion: onion, .leaf: leaf, .metal: metal]
    let ranked = scores.sorted { $0.value > $1.value }
    let best = ranked[0]
    let second = ranked[1]
    var reasons: [String] = []
    switch best.key {
    case .leaf:
        reasons.append(String(format: "%.0f%% of the picture is green", greenShare * 100))
        if cellness > 0.3 { reasons.append("Cell pattern found (\(q.valid) cells)") }
    case .metal:
        reasons.append(meanS < 0.08 ? "Almost no colour: grey, metallic look" : "Little colour, grey-ish look")
        if meanV < 0.80 { reasons.append("Not a pale, see-through background") }
        if texture > 0.5 { reasons.append("Fine grain / scratch texture") }
    case .onion:
        if brightScore > 0.5 { reasons.append("Pale, see-through background") }
        if tint > 0.3 { reasons.append("Stain tint (pink, purple, blue or iodine yellow)") }
        if cellness > 0.3 { reasons.append("Cell network found (\(q.valid) cells)") }
    }
    _ = coloredShare
    let confidence = clamp01((best.value - second.value) / 0.5 * 0.6 + best.value * 0.4)
    if best.value < 0.40 {
        return SDetection(kind: nil, confidence: confidence, scores: scores,
                          reasons: ["No clear match. Pick the sample type yourself."])
    }
    return SDetection(kind: best.key, confidence: confidence, scores: scores, reasons: reasons)
}

// MARK: - 2. Onion peel

func analyzeOnion(_ img: SImage, _ gray: [Float], _ u: SUnits) -> SResult {
    let w = img.w
    let h = img.h
    let n = w * h
    let seg = bestCellSegmentation(gray, w, h)
    let minA = max(25, n / 20000)
    let maxA = n / 4
    var keep = [Bool](repeating: false, count: seg.count + 1)
    var inside: [Int] = []
    var edge = 0
    if seg.count > 0 {
        for l in 1...seg.count {
            let r = seg.regions[l]
            if r.area < minA || r.area > maxA { continue }
            keep[l] = true
            if r.touchesBorder { edge += 1 } else { inside.append(l) }
        }
    }
    var rows: [SRow] = []
    var notes: [String] = []
    var ov = [UInt8](repeating: 0, count: n * 4)
    let total = inside.count + edge
    rows.append(SRow(label: "Cells counted", value: "\(total)"))
    if total < 5 {
        notes.append("Very few cells found. Check focus and lighting, or choose another sample type.")
    }

    if !inside.isEmpty {
        let areas = inside.map { Double(seg.regions[$0].area) }
        let meanA = areas.reduce(0, +) / Double(areas.count)
        var v = 0.0
        for a in areas { v += (a - meanA) * (a - meanA) }
        let sdA = areas.count > 1 ? (v / Double(areas.count - 1)).squareRoot() : 0
        var len = 0.0
        var wid = 0.0
        for l in inside {
            len += seg.regions[l].major
            wid += seg.regions[l].minor
        }
        len /= Double(inside.count)
        wid /= Double(inside.count)
        rows.append(SRow(label: "Mean cell area", value: "\(u.area(meanA)) ± \(u.area(sdA))"))
        rows.append(SRow(label: "Cell size (L × W)", value: "\(u.length(len)) × \(u.length(wid))"))
        let mm2 = u.mm2(Double(n))
        if mm2 > 0 {
            let dens = (Double(inside.count) + 0.5 * Double(edge)) / mm2
            rows.append(SRow(label: "Cell density", value: String(format: "%.0f cells/mm²", dens)))
        }
    }

    // Nuclei: dark compact islands that sit inside a cell.
    var nuc = 0
    var nucR = 0.0
    var nucG = 0.0
    var nucB = 0.0
    var nucPx = 0.0
    var nucDiam = 0.0
    var nucKeep = [Bool](repeating: false, count: seg.nucCount + 1)
    if seg.nucCount > 0 {
        for k in 1...seg.nucCount {
            let r = seg.nucRegions[k]
            let cx = min(max(Int(r.cx.rounded()), 0), w - 1)
            let cy = min(max(Int(r.cy.rounded()), 0), h - 1)
            // The island was filled, so its centre belongs to a cell now.
            var owner: Int32 = 0
            var dy = -3
            while dy <= 3 && owner == 0 {
                var dx = -3
                while dx <= 3 && owner == 0 {
                    let x = min(max(cx + dx, 0), w - 1)
                    let y = min(max(cy + dy, 0), h - 1)
                    owner = seg.labels[y * w + x]
                    dx += 1
                }
                dy += 1
            }
            if owner != 0 && keep[Int(owner)] {
                nuc += 1
                nucKeep[k] = true
                nucDiam += r.eqDiameter
            }
        }
    }
    var cellR = 0.0
    var cellG = 0.0
    var cellB = 0.0
    var cellPx = 0.0
    img.rgba.withUnsafeBufferPointer { p in
        for i in 0..<n {
            let nl = Int(seg.nucLabels[i])
            if nl != 0 && nucKeep[nl] {
                nucR += Double(p[i * 4])
                nucG += Double(p[i * 4 + 1])
                nucB += Double(p[i * 4 + 2])
                nucPx += 1
            } else {
                let l = Int(seg.labels[i])
                if l != 0 && keep[l] && (i % 7 == 0) {
                    cellR += Double(p[i * 4])
                    cellG += Double(p[i * 4 + 1])
                    cellB += Double(p[i * 4 + 2])
                    cellPx += 1
                }
            }
        }
    }
    if nuc > 0 && total > 0 {
        rows.append(SRow(label: "Nuclei", value: "\(nuc) (\(Int((Double(nuc) / Double(total) * 100).rounded(.down)))% of cells)"))
        rows.append(SRow(label: "Nucleus diameter", value: u.length(nucDiam / Double(nuc))))
    } else {
        rows.append(SRow(label: "Nuclei", value: "none found"))
        notes.append("No nuclei seen. Stain with iodine or methylene blue to make them show.")
    }
    if nucPx > 0 {
        rows.append(SRow(label: "Nucleus colour", value: colorName(nucR / nucPx, nucG / nucPx, nucB / nucPx)))
    }
    if cellPx > 0 {
        rows.append(SRow(label: "Cell colour", value: colorName(cellR / cellPx, cellG / cellPx, cellB / cellPx)))
    }
    if !u.calibrated {
        notes.append("Not calibrated: sizes are in pixels. Calibrate in the Measure tab to get µm.")
    }
    if edge > 0 { notes.append("\(edge) cells touch the edge: they are counted but left out of the size averages.") }

    paintOutlines(seg.labels, keep: keep, w, h, (255, 214, 77), into: &ov)
    for i in 0..<n {
        let nl = Int(seg.nucLabels[i])
        if nl != 0 && nucKeep[nl] { paint(&ov, w, h, i % w, i / w, (255, 64, 160)) }
    }
    return SResult(kind: .onion, rows: rows, notes: notes, overlay: ov, w: w, h: h)
}

// MARK: - 3. Leaf

func analyzeLeaf(_ img: SImage, _ gray: [Float], _ u: SUnits) -> SResult {
    let w = img.w
    let h = img.h
    let n = w * h
    let seg = bestCellSegmentation(gray, w, h)
    let minA = max(25, n / 20000)
    let maxA = n / 4

    var keep = [Bool](repeating: false, count: seg.count + 1)
    var wholeAreas: [Double] = []
    var cellList: [Int] = []
    if seg.count > 0 {
        for l in 1...seg.count {
            let r = seg.regions[l]
            if r.area < minA || r.area > maxA { continue }
            keep[l] = true
            cellList.append(l)
            if !r.touchesBorder { wholeAreas.append(Double(r.area)) }
        }
    }
    wholeAreas.sort()
    let median = wholeAreas.isEmpty ? 0 : wholeAreas[wholeAreas.count / 2]

    // Stomata: small, oval regions (guard cells) much smaller than the surrounding cells.
    var cand: [Int] = []
    if median >= 150 && wholeAreas.count >= 8 {
        for l in cellList {
            let r = seg.regions[l]
            if r.touchesBorder { continue }
            let a = Double(r.area)
            if a >= 40 && a <= 0.55 * median && r.aspect >= 1.0 && r.aspect <= 3.4 { cand.append(l) }
        }
    }
    // Two guard cells next to each other are one stoma.
    var groupOf = [Int](repeating: -1, count: cand.count)
    var groups: [[Int]] = []
    for a in 0..<cand.count {
        if groupOf[a] >= 0 { continue }
        let gi = groups.count
        groups.append([a])
        groupOf[a] = gi
        var changed = true
        while changed {
            changed = false
            for b in 0..<cand.count where groupOf[b] < 0 {
                let rb = seg.regions[cand[b]]
                for m in groups[gi] {
                    let rm = seg.regions[cand[m]]
                    let dx = rb.cx - rm.cx
                    let dy = rb.cy - rm.cy
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d <= 1.3 * max(rb.major, rm.major) {
                        groups[gi].append(b)
                        groupOf[b] = gi
                        changed = true
                        break
                    }
                }
            }
        }
    }
    let stomata = groups.count

    // Green coverage.
    var greenPx = 0
    var sumR = 0.0
    var sumG = 0.0
    var sumB = 0.0
    img.rgba.withUnsafeBufferPointer { p in
        var i = 0
        while i < n {
            let r = Float(p[i * 4])
            let g = Float(p[i * 4 + 1])
            let b = Float(p[i * 4 + 2])
            let c = hsvOf(r, g, b)
            if c.h > 70 && c.h < 170 && c.s > 0.18 && c.v > 0.12 { greenPx += 1 }
            sumR += Double(r)
            sumG += Double(g)
            sumB += Double(b)
            i += 3
        }
    }
    let samples = Double((n + 2) / 3)

    var rows: [SRow] = []
    var notes: [String] = []
    rows.append(SRow(label: "Cells counted", value: "\(cellList.count)"))
    if median > 0 {
        rows.append(SRow(label: "Typical cell area", value: u.area(median)))
    }
    rows.append(SRow(label: "Stomata", value: "\(stomata)"))
    if stomata > 0 {
        let mm2 = u.mm2(Double(n))
        if mm2 > 0 {
            rows.append(SRow(label: "Stomatal density", value: String(format: "%.0f /mm²", Double(stomata) / mm2)))
        } else {
            let mpx = Double(n) * u.scale * u.scale / 1_000_000
            rows.append(SRow(label: "Stomata per megapixel", value: String(format: "%.1f", Double(stomata) / max(mpx, 0.01))))
        }
        let idx = Double(stomata) / Double(stomata + max(cellList.count - cand.count, 1)) * 100
        rows.append(SRow(label: "Stomatal index", value: String(format: "%.1f %%", idx)))
        var sizeSum = 0.0
        for g in groups {
            var mx = 0.0
            for m in g { mx = max(mx, seg.regions[cand[m]].major) }
            sizeSum += mx
        }
        rows.append(SRow(label: "Stoma length (approx.)", value: u.length(sizeSum / Double(stomata))))
    } else if median < 150 || wholeAreas.count < 8 {
        notes.append("No clear cell pattern, so stomata cannot be found. Try an epidermal peel or a clear-nail-polish impression.")
    } else {
        notes.append("No stomata found in this view. Move the stage to another spot.")
    }
    rows.append(SRow(label: "Green coverage", value: String(format: "%.0f %%", Double(greenPx) / Double(n) * 100)))
    if samples > 0 {
        rows.append(SRow(label: "Leaf colour", value: colorName(sumR / samples, sumG / samples, sumB / samples)))
    }
    if !u.calibrated {
        notes.append("Not calibrated: density needs a scale. Calibrate in the Measure tab to get stomata per mm².")
    }
    if stomata > 0 {
        notes.append("Stomata are found by size and shape. Check the red rings on the picture.")
    }

    var ov = [UInt8](repeating: 0, count: n * 4)
    paintOutlines(seg.labels, keep: keep, w, h, (140, 255, 170), into: &ov)
    for g in groups {
        var cx = 0.0
        var cy = 0.0
        var radius = 0.0
        for m in g {
            let r = seg.regions[cand[m]]
            cx += r.cx
            cy += r.cy
            radius = max(radius, r.major)
        }
        cx /= Double(g.count)
        cy /= Double(g.count)
        paintRing(&ov, w, h, cx: cx, cy: cy, radius: max(radius * 0.9, 8), width: 3, (255, 70, 70))
    }
    return SResult(kind: .leaf, rows: rows, notes: notes, overlay: ov, w: w, h: h)
}

// MARK: - 4. Metal

/// Keeps only the parts of a mask that lie on straight lines at least `length` long.
func lineOpen(_ mask: [Bool], _ w: Int, _ h: Int, length: Int) -> [Bool] {
    var out = [Bool](repeating: false, count: w * h)
    let half = max(length / 2, 1)
    let angles = 12
    for a in 0..<angles {
        let th = Double.pi * Double(a) / Double(angles)
        let c = cos(th)
        let s = sin(th)
        var dxs: [Int] = []
        var dys: [Int] = []
        for t in -half...half {
            dxs.append(Int((Double(t) * c).rounded()))
            dys.append(Int((Double(t) * s).rounded()))
        }
        let m = dxs.count
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                var ok = true
                var k = 0
                while k < m {
                    let xx = x + dxs[k]
                    let yy = y + dys[k]
                    if xx < 0 || yy < 0 || xx >= w || yy >= h || !mask[yy * w + xx] {
                        ok = false
                        break
                    }
                    k += 1
                }
                if ok {
                    for q in 0..<m {
                        out[(y + dys[q]) * w + (x + dxs[q])] = true
                    }
                }
            }
        }
    }
    return out
}

func countIntercepts(_ mask: [Bool], _ w: Int, _ h: Int, lines: Int) -> (count: Int, length: Double) {
    var count = 0
    var total = 0.0
    for k in 0..<lines {
        let y = min(h - 1, Int((Double(k) + 0.5) * Double(h) / Double(lines)))
        var prev = false
        for x in 0..<w {
            let v = mask[y * w + x]
            if v && !prev { count += 1 }
            prev = v
        }
        total += Double(w)
        let x = min(w - 1, Int((Double(k) + 0.5) * Double(w) / Double(lines)))
        prev = false
        for yy in 0..<h {
            let v = mask[yy * w + x]
            if v && !prev { count += 1 }
            prev = v
        }
        total += Double(h)
    }
    return (count, total)
}

func analyzeMetal(_ img: SImage, _ gray: [Float], _ u: SUnits) -> SResult {
    let w = img.w
    let h = img.h
    let n = w * h
    let long = max(w, h)

    let sm = boxBlur(gray, w, h, 1)
    let bg = boxBlur(sm, w, h, max(long / 10, 8))
    var fl = [Float](repeating: 0, count: n)
    for i in 0..<n { fl[i] = sm[i] - bg[i] }

    // Dark thin lines (grain boundaries) = black top-hat; bright thin lines = white top-hat.
    let closed = morph(morph(fl, w, h, 3, wantMax: true), w, h, 3, wantMax: false)
    let opened = morph(morph(fl, w, h, 3, wantMax: false), w, h, 3, wantMax: true)
    var bth = [Float](repeating: 0, count: n)
    var wth = [Float](repeating: 0, count: n)
    for i in 0..<n {
        bth[i] = max(closed[i] - fl[i], 0)
        wth[i] = max(fl[i] - opened[i], 0)
    }
    zeroBorder(&bth, w, h, 6)
    zeroBorder(&wth, w, h, 6)
    let bs = meanStd(bth)
    let ws = meanStd(wth)

    // Grain boundaries.
    let bmax = max(bth.max() ?? 1, 0.001)
    let ot = otsuFloat(bth, lo: 0, hi: bmax).t
    let bt = max(ot, bs.mean + 0.7 * bs.sd)
    var bmask = [Bool](repeating: false, count: n)
    for i in 0..<n { bmask[i] = bth[i] > bt }
    let (bl, bn) = labelComponents(bmask, w, h, eight: true)
    let br = regionsOf(bl, bn, w, h)
    for i in 0..<n {
        let l = Int(bl[i])
        if l != 0 && br[l].area < 12 { bmask[i] = false }
    }

    var rows: [SRow] = []
    var notes: [String] = []
    let ic = countIntercepts(bmask, w, h, lines: 16)
    var lbar = 0.0
    if ic.count >= 12 {
        lbar = ic.length / Double(ic.count)
        rows.append(SRow(label: "Boundaries crossed", value: "\(ic.count)"))
        rows.append(SRow(label: "Mean intercept length", value: u.length(lbar)))
        if u.calibrated {
            let mm = u.um(lbar) / 1000
            if mm > 0 {
                let g = -6.643856 * log10(mm) - 3.288
                rows.append(SRow(label: "ASTM grain size G", value: String(format: "%.1f", g)))
            }
        } else {
            notes.append("Not calibrated: the ASTM grain size G needs a scale. Calibrate in the Measure tab.")
        }
    } else {
        rows.append(SRow(label: "Grain boundaries", value: "not visible"))
        notes.append("Few grain boundaries found. Polish and etch the surface, or raise the magnification, to see them.")
    }

    // Phases and pores.
    let fs = meanStd(fl)
    let span = 3 * max(fs.sd, 0.5)
    let ph = otsuFloat(fl, lo: -span, hi: span)
    var darkCount = 0
    for i in 0..<n where fl[i] < ph.t { darkCount += 1 }
    let darkShare = Double(darkCount) / Double(n)
    if ph.eta >= 0.82 && darkShare > 0.05 && darkShare < 0.95 {
        rows.append(SRow(label: "Dark phase", value: String(format: "%.1f %%", darkShare * 100)))
        rows.append(SRow(label: "Light phase", value: String(format: "%.1f %%", (1 - darkShare) * 100)))
    } else {
        rows.append(SRow(label: "Phases", value: "single phase"))
    }

    var veryDark = [Bool](repeating: false, count: n)
    let cut = -2.5 * fs.sd
    for i in 0..<n { veryDark[i] = fl[i] < cut }
    let dtp = distanceTransform(veryDark, w, h)
    var poreCore = [Bool](repeating: false, count: n)
    for i in 0..<n { poreCore[i] = dtp[i] >= 1.5 && dtp[i] < 500 }
    let (pl, pn) = labelComponents(poreCore, w, h, eight: true)
    let pr = regionsOf(pl, pn, w, h)
    var pores = 0
    var poreArea = 0
    var poreKeep = [Bool](repeating: false, count: pn + 1)
    if pn > 0 {
        for l in 1...pn where pr[l].area >= 12 && pr[l].aspect <= 4 {
            pores += 1
            poreArea += pr[l].area
            poreKeep[l] = true
        }
    }
    rows.append(SRow(label: "Pores / voids", value: pores == 0 ? "none found" : "\(pores) · \(String(format: "%.2f", Double(poreArea) / Double(n) * 100)) % of area"))

    // Long straight scratches and cracks: only lines much longer than a grain survive.
    var ridge = [Bool](repeating: false, count: n)
    let hiB = bs.mean + 2.2 * bs.sd
    let hiW = ws.mean + 2.2 * ws.sd
    for i in 0..<n { ridge[i] = bth[i] > hiB || wth[i] > hiW }
    ridge = dilate3(ridge, w, h)
    var L = Int(max(0.12 * Double(long), 3 * lbar, 40))
    L = min(L, long / 2)
    if L % 2 == 0 { L += 1 }
    let lines = lineOpen(ridge, w, h, length: L)
    var linePx = 0
    for i in 0..<n where lines[i] { linePx += 1 }
    let (ll, ln) = labelComponents(lines, w, h, eight: true)
    let lr = regionsOf(ll, ln, w, h)
    var defects = 0
    if ln > 0 {
        for l in 1...ln where lr[l].area >= L / 2 && lr[l].major >= 0.8 * Double(L) { defects += 1 }
    }
    if defects > 0 {
        rows.append(SRow(label: "Scratches / cracks", value: "\(defects) · about \(u.length(Double(linePx) / 3)) long"))
        notes.append("Long straight lines are marked red. They may be polishing scratches or cracks: look at them before you decide.")
    } else {
        rows.append(SRow(label: "Scratches / cracks", value: "none found"))
    }

    var ov = [UInt8](repeating: 0, count: n * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            if bmask[i] { paint(&ov, w, h, x, y, (60, 220, 255)) }
        }
    }
    if pn > 0 {
        for i in 0..<n {
            let l = Int(pl[i])
            if l != 0 && poreKeep[l] { paint(&ov, w, h, i % w, i / w, (255, 214, 77)) }
        }
    }
    for i in 0..<n where lines[i] { paint(&ov, w, h, i % w, i / w, (255, 60, 60)) }
    return SResult(kind: .metal, rows: rows, notes: notes, overlay: ov, w: w, h: h)
}

// MARK: - Entry point (runs off the main thread)

func runSampleEngine(_ img: SImage, _ units: SUnits, _ forced: SampleKind?) -> SOutput {
    let det = detectSample(img)
    guard let kind = forced ?? det.kind else { return SOutput(detection: det, result: nil) }
    let gray = grayFloat(img)
    let res: SResult
    switch kind {
    case .onion: res = analyzeOnion(img, gray, units)
    case .leaf: res = analyzeLeaf(img, gray, units)
    case .metal: res = analyzeMetal(img, gray, units)
    }
    return SOutput(detection: det, result: res)
}
