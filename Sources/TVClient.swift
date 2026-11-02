import Foundation

enum Key {
    case home, back, up, down, left, right, center
    case volumeUp, volumeDown, power, enter, del, playPause, mute

    /// Android KeyEvent code.
    var androidCode: Int {
        switch self {
        case .home: 3
        case .back: 4
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .center: 23
        case .volumeUp: 24
        case .volumeDown: 25
        case .power: 26
        case .enter: 66
        case .del: 67
        case .playPause: 85
        case .mute: 164
        }
    }

    /// Samsung SmartView key name.
    var samsungCode: String {
        switch self {
        case .home: "KEY_HOME"
        case .back: "KEY_RETURN"
        case .up: "KEY_UP"
        case .down: "KEY_DOWN"
        case .left: "KEY_LEFT"
        case .right: "KEY_RIGHT"
        case .center, .enter: "KEY_ENTER"
        case .volumeUp: "KEY_VOLUP"
        case .volumeDown: "KEY_VOLDOWN"
        case .power: "KEY_POWER"
        case .del: "KEY_BACKSPACE"
        case .playPause: "KEY_PLAY_BACK"
        case .mute: "KEY_MUTE"
        }
    }
}

struct TVDevice: Codable, Hashable {
    enum Kind: String, Codable { case android, samsung }
    var kind: Kind
    var name: String
    var host: String
    /// Stable across IP changes; keys pairing data.
    var id: String { "\(kind.rawValue):\(name)" }
}

enum TVState: Equatable {
    case idle, searching, choosing, connecting, pairing, enterCode, confirmOnTV, connected
    case offline(String)
}

protocol BackendDelegate: AnyObject {
    func backend(state: TVState)
    func backend(text: String)
    func backend(pairingError: String?)
    func backend(mac: String)
    /// The TV could not be reached at its saved address.
    func backendUnreachable(_ message: String)
}

protocol TVBackend: AnyObject {
    var delegate: BackendDelegate? { get set }
    func connect()
    func disconnect()
    func resetPairing()
    func send(_ key: Key)
    func editText(from old: String, to new: String)
    func submitText()
    func submitCode(_ code: String)
}

/// Front for whichever TV is selected: discovery, selection, reconnects, Wake-on-LAN.
final class TVClient: ObservableObject, BackendDelegate {
    typealias State = TVState

    @Published private(set) var state: State = .idle
    @Published private(set) var device: TVDevice?
    @Published private(set) var devices: [TVDevice] = []
    @Published var pairingError: String?
    /// Current contents of the focused text field on the TV.
    @Published private(set) var tvText = ""

    var tvName: String { device?.name ?? "TV" }

    private var backend: TVBackend?
    private var discovery: Discovery?
    private var rediscovered = false
    private var idleTimer: Timer?

    init() {
        Self.migrate()
        if let data = UserDefaults.standard.data(forKey: "device") {
            device = try? JSONDecoder().decode(TVDevice.self, from: data)
        }
        if let device { devices = [device] }
    }

    private func save() {
        UserDefaults.standard.set(device.flatMap { try? JSONEncoder().encode($0) }, forKey: "device")
    }

    private var mac: String? {
        get { device.flatMap { UserDefaults.standard.string(forKey: "mac.\($0.id)") } }
        set { if let device { UserDefaults.standard.set(newValue, forKey: "mac.\(device.id)") } }
    }

    /// v1.0 stored a single Android TV under flat keys.
    private static func migrate() {
        let d = UserDefaults.standard
        guard d.data(forKey: "device") == nil, let host = d.string(forKey: "tvHost") else { return }
        let dev = TVDevice(kind: .android, name: d.string(forKey: "tvName") ?? "TV", host: host)
        d.set(try? JSONEncoder().encode(dev), forKey: "device")
        d.set(d.bool(forKey: "paired"), forKey: "paired.\(dev.id)")
        d.set(d.string(forKey: "tvMAC"), forKey: "mac.\(dev.id)")
        for k in ["tvHost", "tvName", "paired", "tvMAC"] { d.removeObject(forKey: k) }
    }

    // MARK: lifecycle

    func connect() {
        idleTimer?.invalidate()
        switch state {
        case .idle, .offline: break
        default: return
        }
        guard let device else { scan(choose: false); return }
        if backend == nil { backend = makeBackend(device) }
        backend?.connect()
    }

    private func makeBackend(_ d: TVDevice) -> TVBackend {
        let b: TVBackend = d.kind == .samsung ? SamsungTV(device: d) : AndroidTV(device: d)
        b.delegate = self
        return b
    }

    /// Drop the connection a while after the remote closes to keep the app fully idle.
    func scheduleIdleDisconnect() {
        idleTimer?.invalidate()
        // Keep waiting while the user is pairing or picking a TV.
        guard ![.searching, .choosing, .pairing, .enterCode, .confirmOnTV].contains(state) else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            self?.disconnect()
        }
    }

    func disconnect() {
        backend?.disconnect()
        discovery?.cancel(); discovery = nil
        state = .idle
    }

    /// Pair with the current TV again.
    func forget() {
        backend?.resetPairing()
        backend = nil
        mac = nil
        state = .idle
        connect()
    }

    func select(_ d: TVDevice) {
        backend?.disconnect()
        backend = nil
        device = d
        save()
        tvText = ""
        pairingError = nil
        state = .idle
        connect()
    }

    // MARK: discovery

    /// Searches the network. With `choose`, always ends in the TV picker.
    func scan(choose: Bool) {
        idleTimer?.invalidate()
        backend?.disconnect()
        discovery?.cancel()
        state = .searching
        let disc = Discovery()
        discovery = disc
        disc.run { [weak self] found in
            guard let self, self.discovery === disc else { return }
            self.discovery = nil
            self.devices = found
            if choose && !found.isEmpty { self.state = .choosing; return }
            if let want = self.device {
                if let match = found.first(where: { $0.id == want.id }) {
                    if match.host != want.host { self.device = match; self.save(); self.backend = nil }
                    self.state = .idle
                    self.connect()
                } else if found.isEmpty {
                    self.state = .offline("Телевізор не знайдено в мережі")
                } else {
                    self.state = .choosing
                }
            } else if found.count == 1 {
                self.select(found[0])
            } else {
                self.state = found.isEmpty ? .offline("Телевізор не знайдено в мережі") : .choosing
            }
        }
    }

    // MARK: BackendDelegate

    func backend(state: State) {
        self.state = state
        if state == .connected { rediscovered = false }
    }

    func backend(text: String) { tvText = text }
    func backend(pairingError: String?) { self.pairingError = pairingError }
    func backend(mac: String) { if self.mac == nil { self.mac = mac } }

    func backendUnreachable(_ message: String) {
        // The TV's IP may have changed — rediscover once.
        if !rediscovered {
            rediscovered = true
            scan(choose: false)
        } else {
            state = .offline(message)
        }
    }

    // MARK: commands

    func send(_ key: Key) {
        guard state == .connected, let backend else {
            if key == .power, let mac { WakeOnLAN.wake(mac) } // TV asleep: try to wake it
            connect(); return
        }
        backend.send(key)
    }

    /// Brings the TV's focused text field from `old` to `new`.
    func editText(from old: String, to new: String) {
        guard state == .connected else { return }
        backend?.editText(from: old, to: new)
    }

    func submitText() {
        guard state == .connected else { connect(); return }
        backend?.submitText()
    }

    func submitCode(_ code: String) { backend?.submitCode(code) }
}

extension Data {
    init?(hex: String) {
        var d = Data()
        var it = hex.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
            d.append(v)
        }
        self = d
    }
}

enum WakeOnLAN {
    /// MAC address of a LAN host, read from the ARP cache.
    static func mac(for ip: String) -> String? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-n", ip]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let r = text.range(of: #"([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    static func wake(_ mac: String) {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9).bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

