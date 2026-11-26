import SwiftUI
import Darwin

// MARK: - LED ring on an Arduino Nano (USB serial, 9600 baud)
//
// Talks to the Lister LED sketch: 'a' all on, 's' all off (works with the first
// sketch too). The v2 sketch adds 'm<0-1023>' to set every LED at once from a bit
// pattern (bit 0 = LED 1 on D2 … bit 9 = LED 10 on D11) and '?' to report the
// state as "MASK n". Lister sends '?' when the board starts; a "MASK" reply means
// single-LED control is available.
// Opening the port resets the Nano (about 2 s), so the port is opened once and
// kept open; commands sent before the sketch prints "Ready!" are held and sent
// as soon as it is ready.

final class LightController: ObservableObject {
    @Published var portPath: String {
        didSet { UserDefaults.standard.set(portPath, forKey: "ledPort") }
    }
    /// Turn the LEDs on for each capture and off again afterwards.
    @Published var autoCapture: Bool {
        didSet { UserDefaults.standard.set(autoCapture, forKey: "ledAuto") }
    }
    /// Seconds between switching the LEDs on and taking the photo, so the phone can re-expose.
    @Published var warmup: Double {
        didSet { UserDefaults.standard.set(warmup, forKey: "ledWarmup") }
    }
    /// Which LEDs are on: bit 0 = LED 1 … bit 9 = LED 10.
    @Published private(set) var mask = 0
    /// The board runs the v2 sketch (single-LED control).
    @Published private(set) var individual = false
    /// LEDs used while capturing (v2 sketch). Default: all 10.
    @Published var captureMask: Int {
        didSet { UserDefaults.standard.set(captureMask, forKey: "ledCaptureMask") }
    }

    static let count = 10
    static let all = (1 << count) - 1

    var isOn: Bool { mask != 0 }
    func ledOn(_ i: Int) -> Bool { mask & (1 << i) != 0 }
    var onCount: Int { (0..<Self.count).filter { ledOn($0) }.count }
    @Published private(set) var connected = false
    @Published private(set) var ready = false
    @Published private(set) var lastMessage = ""
    @Published private(set) var ports: [String] = []

    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var lineBuffer = ""
    private var pending: Int?
    private var openedAt = Date.distantPast

    init() {
        let d = UserDefaults.standard
        portPath = d.string(forKey: "ledPort") ?? "/dev/cu.usbserial-A5069RR4"
        autoCapture = d.object(forKey: "ledAuto") as? Bool ?? true
        warmup = d.object(forKey: "ledWarmup") as? Double ?? 1.0
        let cm = d.object(forKey: "ledCaptureMask") as? Int ?? LightController.all
        captureMask = cm > 0 && cm <= LightController.all ? cm : LightController.all
        refreshPorts()
    }

    deinit { closePort() }

    // MARK: Ports

    func refreshPorts() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        ports = names
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming") && !$0.contains("debug-console") }
            .sorted { a, b in
                // USB serial adapters first.
                let ua = a.contains("usb"), ub = b.contains("usb")
                return ua != ub ? ua : a < b
            }
            .map { "/dev/" + $0 }
    }

    /// Seconds left until the Nano has finished its reset after the port was opened.
    var secondsUntilReady: Double {
        guard connected, !ready else { return 0 }
        return max(2.2 - Date().timeIntervalSince(openedAt), 0)
    }

    func autoConnect() {
        guard !connected, FileManager.default.fileExists(atPath: portPath) else { return }
        _ = connect()
    }

    @discardableResult
    func connect() -> Bool {
        closePort()
        refreshPorts()
        let f = open(portPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else {
            lastMessage = "Could not open \(portPath) (\(String(cString: strerror(errno))))."
            return false
        }
        var t = termios()
        guard tcgetattr(f, &t) == 0 else {
            close(f)
            lastMessage = "\(portPath) is not a serial port."
            return false
        }
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B9600))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(f, TCSANOW, &t) == 0 else {
            close(f)
            lastMessage = "Could not set 9600 baud on \(portPath)."
            return false
        }
        tcflush(f, TCIOFLUSH)

        fd = f
        connected = true
        ready = false
        individual = false
        mask = 0
        openedAt = Date()
        lastMessage = "Connected, waiting for the Arduino to start…"

        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: .main)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume()
        reader = src

        // If the sketch's "Ready!" line is missed, carry on after the reset time anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.connected, !self.ready, self.fd == f else { return }
            self.becameReady()
        }
        return true
    }

    func disconnect() {
        closePort()
        lastMessage = "Disconnected"
    }

    private func closePort() {
        reader?.cancel()
        reader = nil
        if fd >= 0 { close(fd) }
        fd = -1
        connected = false
        ready = false
        individual = false
        mask = 0
        pending = nil
    }

    // MARK: Reading the sketch's replies

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 256) }
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) {
                closePort()
                lastMessage = "Arduino unplugged."
            }
            return
        }
        lineBuffer += String(decoding: buf[0..<n], as: UTF8.self)
        while let r = lineBuffer.firstIndex(where: { $0.isNewline }) {
            let line = lineBuffer[..<r].trimmingCharacters(in: .whitespaces)
            lineBuffer = String(lineBuffer[lineBuffer.index(after: r)...])
            guard !line.isEmpty else { continue }
            lastMessage = line
            if line.hasPrefix("Ready") { becameReady() }
            if line == "All LEDs ON" { mask = Self.all }
            if line == "All LEDs OFF" { mask = 0 }
            if line.hasPrefix("MASK "), let m = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
                individual = true
                mask = m & Self.all
            }
        }
    }

    private func becameReady() {
        ready = true
        if lastMessage.hasPrefix("Connected") { lastMessage = "Ready" }
        _ = sendRaw("?\n")      // a v2 sketch answers "MASK n"
        if let p = pending {
            pending = nil
            apply(mask: p)
        }
    }

    // MARK: Switching

    /// Any LED on → all off; all off → all on.
    func toggle() { set(!isOn) }

    /// Turns all LEDs on or off. Connects first if needed.
    func set(_ on: Bool) { apply(mask: on ? Self.all : 0) }

    /// Switches one LED (0 = LED 1 … 9 = LED 10).
    func setLED(_ i: Int, _ on: Bool) {
        guard (0..<Self.count).contains(i) else { return }
        apply(mask: on ? (mask | (1 << i)) : (mask & ~(1 << i)))
    }

    func toggleLED(_ i: Int) { setLED(i, !ledOn(i)) }

    /// LEDs for a capture: the saved capture pattern on a v2 sketch, otherwise all.
    func lightForCapture() { apply(mask: individual ? captureMask : Self.all) }

    /// Sets every LED at once. All/none use 'a'/'s' so the first sketch still works.
    func apply(mask newMask: Int) {
        let m = newMask & Self.all
        if !connected { guard connect() else { return } }
        guard ready else {
            pending = m
            mask = m
            return
        }
        let cmd = m == 0 ? "s" : (m == Self.all ? "a" : "m\(m)\n")
        if sendRaw(cmd) {
            mask = m
        } else {
            closePort()
            lastMessage = "Could not talk to the Arduino. Check the cable, then Connect again."
        }
    }

    private func sendRaw(_ s: String) -> Bool {
        guard fd >= 0 else { return false }
        let bytes = Array(s.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        return written == bytes.count
    }

    var statusText: String {
        if !connected { return lastMessage.isEmpty ? "Not connected" : lastMessage }
        if !ready { return "Starting…" }
        if mask == 0 { return "LEDs off" }
        if mask == Self.all { return "All 10 LEDs on" }
        return "\(onCount) of 10 LEDs on"
    }

    static func describe(_ m: Int) -> String {
        if m == all { return "all 10 LEDs" }
        let on = (0..<count).filter { m & (1 << $0) != 0 }.map { "\($0 + 1)" }
        return on.isEmpty ? "no LEDs" : "LED " + on.joined(separator: ", ")
    }
}

// MARK: - Toolbar button

struct LEDButton: View {
    @EnvironmentObject var lights: LightController
    @EnvironmentObject var store: Store

    var body: some View {
        Button {
            if !lights.connected && !lights.connect() {
                store.notify("LEDs: \(lights.lastMessage) Pick the port in Settings.",
                             icon: "lightbulb.slash", error: true)
                return
            }
            withAnimation(Theme.spring) { lights.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: lights.isOn ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(lights.isOn ? (Theme.dark ? Color.yellow : Color.orange) : Color.secondary)
                    .symbolEffect(.bounce, value: lights.isOn)
                Text("LEDs").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(lights.isOn ? Color.yellow.opacity(0.2) : Theme.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(lights.isOn ? Color.yellow.opacity(0.6) : Theme.ink.opacity(0.08), lineWidth: 1))
            .shadow(color: lights.isOn ? Color.yellow.opacity(0.35) : .clear, radius: lights.isOn ? 6 : 0)
            .opacity(lights.connected ? 1 : 0.6)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(lights.connected ? "Turn all LEDs on or off (⌘B) · \(lights.statusText)\(lights.autoCapture ? " · on automatically while capturing" : "")"
                               : "LEDs not connected. Click to connect (⌘B)")
        .contextMenu {
            Toggle("Turn on automatically while capturing", isOn: $lights.autoCapture)
            Divider()
            if lights.connected {
                Button("Disconnect Arduino") { lights.disconnect() }
            } else {
                Button("Connect Arduino") { lights.connect() }
            }
        }
        .animation(Theme.spring, value: lights.isOn)
    }
}

/// Toolbar switch: should the LEDs come on by themselves for each photo?
struct LEDAutoButton: View {
    @EnvironmentObject var lights: LightController

    var body: some View {
        Button {
            withAnimation(Theme.spring) { lights.autoCapture.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: lights.autoCapture ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(lights.autoCapture ? (Theme.dark ? Color.yellow : Color.orange) : Color.secondary)
                Text(lights.autoCapture ? "Flash on" : "Flash off")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(lights.autoCapture ? Color.yellow.opacity(0.2) : Theme.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(lights.autoCapture ? Color.yellow.opacity(0.6) : Theme.ink.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(lights.autoCapture
              ? "LEDs switch on by themselves for every photo, including voice capture. Click to turn this off."
              : "LEDs stay as they are during a photo. Click to switch them on automatically for every photo.")
        .animation(Theme.spring, value: lights.autoCapture)
    }
}

// MARK: - Settings card

struct LEDSettings: View {
    @EnvironmentObject var lights: LightController

    var body: some View {
        Card(title: "LED lights · Arduino", icon: "lightbulb.fill") {
            HStack(spacing: 8) {
                Circle()
                    .fill(lights.connected ? (lights.ready ? Color.green : Color.yellow) : Color.orange)
                    .frame(width: 7, height: 7)
                Text(lights.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }

            HStack(spacing: 6) {
                Menu {
                    ForEach(lights.ports, id: \.self) { p in
                        Button(p) { lights.portPath = p }
                    }
                    if lights.ports.isEmpty { Text("No serial ports found") }
                    Divider()
                    Button("Refresh list") { lights.refreshPorts() }
                } label: {
                    Text(lights.portPath.replacingOccurrences(of: "/dev/", with: ""))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))

                Button(lights.connected ? "Disconnect" : "Connect") {
                    if lights.connected { lights.disconnect() } else { lights.connect() }
                }
                .buttonStyle(PillStyle(prominent: !lights.connected))
            }

            HStack(spacing: 6) {
                Button { lights.set(true) } label: { Label("All on", systemImage: "lightbulb.fill") }
                Button { lights.set(false) } label: { Label("All off", systemImage: "lightbulb") }
                Spacer()
            }
            .buttonStyle(PillStyle())

            Toggle(isOn: $lights.autoCapture) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Turn on automatically while capturing").font(.system(size: 12.5, weight: .medium))
                    Text("On before each photo, off right after (also for time-lapse)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            SliderRow(title: "Wait before photo", value: String(format: "%.1f s", lights.warmup),
                      v: $lights.warmup, range: 0...3, step: 0.1,
                      note: "lets the camera adjust")
        }
    }
}

// MARK: - Adjust tab: single-LED control

struct LEDControlCard: View {
    @EnvironmentObject var lights: LightController

    var body: some View {
        Card(title: "LED lights", icon: "lightbulb.fill") {
            HStack(spacing: 8) {
                Circle()
                    .fill(lights.connected ? (lights.ready ? Color.green : Color.yellow) : Color.orange)
                    .frame(width: 7, height: 7)
                Text(lights.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if !lights.connected {
                    Button("Connect") { lights.connect() }
                        .buttonStyle(PillStyle(prominent: true))
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 10) {
                ForEach(0..<LightController.count, id: \.self) { i in
                    ledDot(i)
                }
            }
            .opacity(lights.connected ? 1 : 0.45)

            if lights.connected && lights.ready && !lights.individual {
                Text("Your Arduino still has the first sketch, so only All on / All off work. Upload the Lister LED v2 sketch to switch single LEDs.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button { withAnimation(Theme.bouncy) { lights.set(true) } } label: {
                    Label("All on", systemImage: "lightbulb.fill")
                }
                Button { withAnimation(Theme.bouncy) { lights.set(false) } } label: {
                    Label("All off", systemImage: "lightbulb")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(PillStyle())

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $lights.autoCapture) {
                    Text("Light up while capturing").font(.system(size: 12.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if lights.autoCapture {
                    Text("Uses \(LightController.describe(lights.individual ? lights.captureMask : LightController.all))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Use LEDs that are on now") { lights.captureMask = lights.mask }
                            .disabled(!lights.individual || lights.mask == 0)
                        Button("All 10") { lights.captureMask = LightController.all }
                            .disabled(!lights.individual || lights.captureMask == LightController.all)
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(PillStyle())
                }
            }
            .animation(Theme.spring, value: lights.autoCapture)
        }
    }

    private func ledDot(_ i: Int) -> some View {
        let on = lights.ledOn(i)
        let usable = lights.connected && lights.individual
        let inCapture = lights.captureMask & (1 << i) != 0
        return Button {
            withAnimation(Theme.bouncy) { lights.toggleLED(i) }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(on ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(Theme.raised()))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(on ? Color.orange.opacity(0.8) : Theme.line(0.12), lineWidth: 1))
                        .shadow(color: on ? Color.yellow.opacity(0.7) : .clear, radius: on ? 8 : 0)
                    Text("\(i + 1)")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(on ? Color.black.opacity(0.75) : Color.secondary)
                }
                .scaleEffect(on ? 1.06 : 1)
                HStack(spacing: 2) {
                    if lights.autoCapture && lights.individual && inCapture {
                        Circle().fill(Theme.accent).frame(width: 4, height: 4)
                    }
                    Text("D\(i + 2)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!usable)
        .help(usable ? "LED \(i + 1) on pin D\(i + 2)\(inCapture ? " · used while capturing" : "")"
                     : "Single LEDs need the v2 Arduino sketch")
        .animation(Theme.bouncy, value: on)
    }
}
