import Foundation
import Network
import Security
import CryptoKit

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

/// Android TV / Google TV over the Android TV Remote v2 protocol.
final class AndroidTV: TVBackend {
    weak var delegate: BackendDelegate?
    private let device: TVDevice
    private var identity: SecIdentity?
    private var remote: Link?
    private var pairing: Link?
    private var imeCounter = 0, fieldCounter = 0

    private var pairedKey: String { "paired.\(device.id)" }
    private var paired: Bool {
        get { UserDefaults.standard.bool(forKey: pairedKey) }
        set { UserDefaults.standard.set(newValue, forKey: pairedKey) }
    }

    init(device: TVDevice) { self.device = device }

    func connect() {
        do { identity = try identity ?? ClientIdentity.load() } catch {
            delegate?.backend(state: .offline(error.localizedDescription)); return
        }
        paired ? openRemote() : startPairing()
    }

    func disconnect() {
        remote?.cancel(); remote = nil
        pairing?.cancel(); pairing = nil
    }

    func resetPairing() {
        disconnect()
        paired = false
        ClientIdentity.reset()
        identity = nil
    }

    // MARK: pairing (port 6467)

    private func pairMsg(_ build: (inout PB) -> Void) -> Data {
        PB.build { p in p.int(1, 2); p.int(2, 200); build(&p) }
    }

    private func startPairing() {
        guard let identity else { return }
        delegate?.backend(state: .pairing)
        delegate?.backend(pairingError: nil)
        let l = Link(host: device.host, port: 6467, identity: identity)
        pairing = l
        var waitingForCode = false
        l.onReady = { [weak l, weak self] in
            guard let self else { return }
            l?.send(self.pairMsg { $0.msg(10) { $0.string(1, "atvremote"); $0.string(2, "MacMote") } })
        }
        l.onMessage = { [weak self, weak l] m in
            guard let self, let l else { return }
            guard m.int(2) == 200 else {
                let err = "Телевізор відхилив сполучення (\(m.int(2) ?? 0))"
                self.delegate?.backend(pairingError: err)
                if !waitingForCode { self.pairing?.cancel(); self.pairing = nil; self.delegate?.backend(state: .offline(err)) }
                return
            }
            let hexEncoding: (inout PB) -> Void = { $0.int(1, 3); $0.int(2, 6) }
            if m.has(11) {
                l.send(self.pairMsg { $0.msg(20) { $0.msg(1, hexEncoding); $0.int(3, 1) } })
            } else if m.has(20) {
                l.send(self.pairMsg { $0.msg(30) { $0.msg(1, hexEncoding); $0.int(2, 1) } })
            } else if m.has(31) {
                waitingForCode = true
                self.delegate?.backend(state: .enterCode)
            } else if m.has(41) {
                self.paired = true
                l.cancel(); self.pairing = nil
                self.openRemote()
            }
        }
        l.onFail = { [weak self] e in
            guard let self else { return }
            self.pairing = nil
            self.delegate?.backendUnreachable(e.map { "Сполучення: \($0.localizedDescription)" }
                                               ?? "Телевізор розірвав з'єднання")
        }
        l.start()
    }

    func submitCode(_ raw: String) {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 6, let first = UInt8(code.prefix(2), radix: 16),
              let tail = Data(hex: String(code.dropFirst(2))) else {
            delegate?.backend(pairingError: "Код має містити 6 символів (0-9, A-F)"); return
        }
        guard let l = pairing, let identity, let serverCert = l.serverCert else { return }
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert, let c = ClientIdentity.rsaComponents(of: cert),
              let s = ClientIdentity.rsaComponents(of: serverCert) else {
            delegate?.backend(pairingError: "Не вдалося прочитати ключі"); return
        }
        var h = SHA256()
        h.update(data: c.n); h.update(data: c.e)
        h.update(data: s.n); h.update(data: s.e)
        h.update(data: tail)
        let digest = Data(h.finalize())
        guard digest[0] == first else { delegate?.backend(pairingError: "Невірний код"); return }
        delegate?.backend(pairingError: nil)
        l.send(pairMsg { $0.msg(40) { $0.bytes(1, digest) } })
    }

    // MARK: remote (port 6466)

    private func openRemote() {
        guard let identity else { return }
        delegate?.backend(state: .connecting)
        let l = Link(host: device.host, port: 6466, identity: identity)
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
                self.delegate?.backend(state: .connected)
                if let mac = WakeOnLAN.mac(for: self.device.host) { self.delegate?.backend(mac: mac) }
            } else if let ping = m.sub(8) {
                l.send(PB.build { $0.msg(9) { $0.int(1, ping.int(1) ?? 0) } })
            } else if let field = m.sub(20)?.sub(2) ?? m.sub(22)?.sub(2) {
                // Text field focused/updated on the TV
                self.fieldCounter = field.int(1) ?? self.fieldCounter
                self.delegate?.backend(text: field.string(2) ?? "")
            } else if let edit = m.sub(21) {
                self.imeCounter = edit.int(1) ?? 0
                if let f = edit.int(2), f != 0 { self.fieldCounter = f }
            } else if m.has(3) {
                self.delegate?.backend(state: .offline("Помилка від телевізора"))
            }
        }
        l.onFail = { [weak self] e in
            guard let self else { return }
            self.remote = nil
            if !gotMessage, case .tls? = e as? NWError {
                // TV no longer trusts our certificate — pair again.
                self.paired = false
                self.startPairing()
            } else if gotMessage {
                self.delegate?.backend(state: .idle) // dropped; reconnect on next action
            } else {
                self.delegate?.backendUnreachable(e?.localizedDescription ?? "Немає з'єднання")
            }
        }
        l.start()
    }

    func send(_ key: Key) {
        remote?.send(PB.build { $0.msg(10) { $0.int(1, key.androidCode); $0.int(2, 3) } })
    }

    /// The TV inserts text at its cursor, so only the difference is sent:
    /// Delete presses for removed characters, then the new tail.
    func editText(from old: String, to new: String) {
        let prefix = old.commonPrefix(with: new)
        for _ in 0..<(old.count - prefix.count) { send(.del) }
        let tail = String(new.dropFirst(prefix.count))
        guard !tail.isEmpty, let remote else { return }
        let cursor = max(new.utf16.count - 1, 0)
        remote.send(PB.build { $0.msg(21) { p in
            p.int(1, imeCounter)
            p.int(2, fieldCounter)
            p.msg(3) { e in
                e.int(1, 1)
                e.msg(2) { o in o.int(1, cursor); o.int(2, cursor); o.string(3, tail) }
            }
        } })
    }

    func submitText() { send(.enter) }
}
