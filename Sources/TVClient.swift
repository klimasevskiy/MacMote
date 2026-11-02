import Foundation
import Network
import Security
import CryptoKit

/// Android KeyEvent codes.
enum Key: Int {
    case home = 3, back = 4, up = 19, down = 20, left = 21, right = 22, center = 23
    case volumeUp = 24, volumeDown = 25, power = 26, enter = 66, del = 67
    case playPause = 85, next = 87, mute = 164
}

/// TLS connection carrying varint-framed protobuf messages.
final class Link {
    private let conn: NWConnection
    private var framer = Framer()
    private(set) var serverCert: SecCertificate?
    var onMessage: (PBMsg) -> Void = { _ in }
    var onReady: () -> Void = {}
    var onFail: (Error?) -> Void = { _ in }

    init(host: String, port: UInt16, identity: SecIdentity) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, sec_identity_create(identity)!)
        let box = CertBox()
        sec_protocol_options_set_verify_block(sec, { _, trust, done in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            box.cert = (SecTrustCopyCertificateChain(t) as? [SecCertificate])?.first
            done(true) // TV uses a self-signed cert
        }, .main)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                            using: NWParameters(tls: tls, tcp: tcp))
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.serverCert = box.cert
                self.onReady()
                self.receive()
            case .failed(let e): self.finish(e)
            case .waiting(let e): self.finish(e)
            default: break
            }
        }
    }

    private final class CertBox { var cert: SecCertificate? }

    func start() { conn.start(queue: .main) }

    func send(_ body: Data) {
        conn.send(content: PB.varint(body.count) + body, completion: .contentProcessed { _ in })
    }

    func cancel() {
        onFail = { _ in }
        conn.cancel()
    }

    private func finish(_ e: Error?) {
        let cb = onFail
        cancel()
        cb(e)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data {
                for m in self.framer.push(data) { if let msg = PBMsg(m) { self.onMessage(msg) } }
            }
            if done || err != nil { self.finish(err) } else { self.receive() }
        }
    }
}

final class TVClient: ObservableObject {
    enum State: Equatable {
        case idle, searching, connecting, pairing, enterCode, connected
        case offline(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var tvName: String = UserDefaults.standard.string(forKey: "tvName") ?? "TV"
    @Published var pairingError: String?
    /// Current contents of the focused text field on the TV.
    @Published private(set) var tvText = ""

    private var host: String? {
        get { UserDefaults.standard.string(forKey: "tvHost") }
        set { UserDefaults.standard.set(newValue, forKey: "tvHost") }
    }
    private var paired: Bool {
        get { UserDefaults.standard.bool(forKey: "paired") }
        set { UserDefaults.standard.set(newValue, forKey: "paired") }
    }

    private var mac: String? {
        get { UserDefaults.standard.string(forKey: "tvMAC") }
        set { UserDefaults.standard.set(newValue, forKey: "tvMAC") }
    }

    private var identity: SecIdentity?
    private var remote: Link?
    private var pairing: Link?
    private var browser: NWBrowser?
    private var resolver: NWConnection?
    private var imeCounter = 0, fieldCounter = 0
    private var rediscovered = false
    private var idleTimer: Timer?

    // MARK: lifecycle

    func connect() {
        idleTimer?.invalidate()
        switch state {
        case .connected, .connecting, .searching, .pairing, .enterCode: return
        default: break
        }
        do { identity = try identity ?? ClientIdentity.load() } catch {
            state = .offline(error.localizedDescription); return
        }
        if let host { paired ? openRemote(host) : startPairing(host) } else { discover() }
    }

    /// Drop the connection a while after the popover closes to keep the app fully idle.
    func scheduleIdleDisconnect() {
        idleTimer?.invalidate()
        guard state != .enterCode && state != .pairing else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            self?.disconnect()
        }
    }

    func disconnect() {
        remote?.cancel(); remote = nil
        pairing?.cancel(); pairing = nil
        browser?.cancel(); browser = nil
        resolver?.cancel(); resolver = nil
        state = .idle
    }

    func forget() {
        disconnect()
        host = nil
        mac = nil
        paired = false
        ClientIdentity.reset()
        identity = nil
        connect()
    }

    // MARK: discovery

    private func discover() {
        state = .searching
        let b = NWBrowser(for: .bonjour(type: "_androidtvremote2._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let r = results.first, self.resolver == nil else { return }
            if case .service(let name, _, _, _) = r.endpoint { self.tvName = name }
            UserDefaults.standard.set(self.tvName, forKey: "tvName")
            self.resolve(r.endpoint)
        }
        b.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { self?.state = .offline("Пошук: \(e.localizedDescription)") }
        }
        browser = b
        b.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.state == .searching, self.resolver == nil else { return }
            self.browser?.cancel(); self.browser = nil
            self.state = .offline("Телевізор не знайдено в мережі")
        }
    }

    private func resolve(_ endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: endpoint, using: params)
        resolver = c
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                if case .hostPort(let h, _)? = c.currentPath?.remoteEndpoint {
                    var str = "\(h)"
                    if let pct = str.firstIndex(of: "%") { str = String(str[..<pct]) }
                    self.host = str
                }
                c.cancel(); self.resolver = nil
                self.browser?.cancel(); self.browser = nil
                self.state = .idle
                self.connect()
            case .failed(let e), .waiting(let e):
                c.cancel(); self.resolver = nil
                self.state = .offline(e.localizedDescription)
            default: break
            }
        }
        c.start(queue: .main)
    }

    // MARK: pairing (port 6467)

    private func pairMsg(_ build: (inout PB) -> Void) -> Data {
        PB.build { p in p.int(1, 2); p.int(2, 200); build(&p) }
    }

    private func startPairing(_ host: String) {
        guard let identity else { return }
        state = .pairing
        pairingError = nil
        let l = Link(host: host, port: 6467, identity: identity)
        pairing = l
        l.onReady = { [weak l, weak self] in
            guard let self else { return }
            l?.send(self.pairMsg { $0.msg(10) { $0.string(1, "atvremote"); $0.string(2, "MacMote") } })
        }
        l.onMessage = { [weak self, weak l] m in
            guard let self, let l else { return }
            guard m.int(2) == 200 else {
                self.pairingError = "Телевізор відхилив сполучення (\(m.int(2) ?? 0))"
                if self.state != .enterCode { self.pairing?.cancel(); self.pairing = nil; self.state = .offline(self.pairingError!) }
                return
            }
            let hexEncoding: (inout PB) -> Void = { $0.int(1, 3); $0.int(2, 6) }
            if m.has(11) {
                l.send(self.pairMsg { $0.msg(20) { $0.msg(1, hexEncoding); $0.int(3, 1) } })
            } else if m.has(20) {
                l.send(self.pairMsg { $0.msg(30) { $0.msg(1, hexEncoding); $0.int(2, 1) } })
            } else if m.has(31) {
                self.state = .enterCode
            } else if m.has(41) {
                self.paired = true
                l.cancel(); self.pairing = nil
                self.state = .idle
                self.connect()
            }
        }
        l.onFail = { [weak self] e in
            guard let self else { return }
            self.pairing = nil
            self.state = .offline(e.map { "Сполучення: \($0.localizedDescription)" } ?? "Телевізор розірвав з'єднання")
            self.retryDiscoveryIfNeeded()
        }
        l.start()
    }

    func submitCode(_ raw: String) {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 6, let first = UInt8(code.prefix(2), radix: 16),
              let tail = Data(hex: String(code.dropFirst(2))) else {
            pairingError = "Код має містити 6 символів (0-9, A-F)"; return
        }
        guard let l = pairing, let identity, let serverCert = l.serverCert else { return }
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert, let c = ClientIdentity.rsaComponents(of: cert),
              let s = ClientIdentity.rsaComponents(of: serverCert) else {
            pairingError = "Не вдалося прочитати ключі"; return
        }
        var h = SHA256()
        h.update(data: c.n); h.update(data: c.e)
        h.update(data: s.n); h.update(data: s.e)
        h.update(data: tail)
        let digest = Data(h.finalize())
        guard digest[0] == first else { pairingError = "Невірний код"; return }
        pairingError = nil
        l.send(pairMsg { $0.msg(40) { $0.bytes(1, digest) } })
    }

    // MARK: remote (port 6466)

    private func openRemote(_ host: String) {
        guard let identity else { return }
        state = .connecting
        let l = Link(host: host, port: 6466, identity: identity)
        remote = l
        var gotMessage = false
        l.onMessage = { [weak self, weak l] m in
            guard let self, let l else { return }
            gotMessage = true
            if m.has(1) {
                l.send(PB.build { $0.msg(1) { p in
                    p.int(1, 615)
                    p.msg(2) { d in
                        d.string(1, "MacBook"); d.string(2, "Apple"); d.int(3, 1)
                        d.string(4, "1"); d.string(5, "atvremote"); d.string(6, "1.0.0")
                    }
                } })
            } else if m.has(2) {
                l.send(PB.build { $0.msg(2) { $0.int(1, 615) } })
                self.state = .connected
                self.rediscovered = false
                if self.mac == nil { self.mac = WakeOnLAN.mac(for: host) }
            } else if let ping = m.sub(8) {
                l.send(PB.build { $0.msg(9) { $0.int(1, ping.int(1) ?? 0) } })
            } else if let field = m.sub(20)?.sub(2) ?? m.sub(22)?.sub(2) {
                // Text field focused/updated on the TV
                self.fieldCounter = field.int(1) ?? self.fieldCounter
                self.tvText = field.string(2) ?? ""
            } else if let edit = m.sub(21) {
                self.imeCounter = edit.int(1) ?? 0
                if let f = edit.int(2), f != 0 { self.fieldCounter = f }
            } else if m.has(3) {
                self.state = .offline("Помилка від телевізора")
            }
        }
        l.onFail = { [weak self] e in
            guard let self else { return }
            self.remote = nil
            if !gotMessage, case .tls? = e as? NWError {
                // TV no longer trusts our certificate — pair again.
                self.paired = false
                self.state = .idle
                self.connect()
            } else if gotMessage {
                self.state = .idle // dropped; reconnect on next action
            } else {
                self.state = .offline(e?.localizedDescription ?? "Немає з'єднання")
                self.retryDiscoveryIfNeeded()
            }
        }
        l.start()
    }

    /// The TV's IP may have changed — rediscover once.
    private func retryDiscoveryIfNeeded() {
        guard !rediscovered else { return }
        rediscovered = true
        host = nil
        state = .idle
        connect()
    }

    func send(_ key: Key) {
        guard state == .connected, let remote else {
            if key == .power, let mac { WakeOnLAN.wake(mac) } // TV asleep: try to wake it
            connect(); return
        }
        remote.send(PB.build { $0.msg(10) { $0.int(1, key.rawValue); $0.int(2, 3) } })
    }

    /// Brings the TV text field from `old` to `new`. The TV inserts text at its cursor,
    /// so only the difference is sent: Delete presses for removed characters, then the new tail.
    func editText(from old: String, to new: String) {
        guard state == .connected else { return }
        let prefix = old.commonPrefix(with: new)
        for _ in 0..<(old.count - prefix.count) { send(.del) }
        let tail = String(new.dropFirst(prefix.count))
        if !tail.isEmpty { insertText(tail, cursor: max(new.utf16.count - 1, 0)) }
    }

    private func insertText(_ text: String, cursor: Int) {
        guard let remote else { return }
        remote.send(PB.build { $0.msg(21) { p in
            p.int(1, imeCounter)
            p.int(2, fieldCounter)
            p.msg(3) { e in
                e.int(1, 1)
                e.msg(2) { o in o.int(1, cursor); o.int(2, cursor); o.string(3, text) }
            }
        } })
    }
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

