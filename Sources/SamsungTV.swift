import Foundation

/// Samsung Tizen TVs (2016+) over the SmartView WebSocket API on port 8002.
/// The first connection shows an "Allow" prompt on the TV, which returns a token for later ones.
final class SamsungTV: NSObject, TVBackend, URLSessionDelegate {
    weak var delegate: BackendDelegate?
    private let device: TVDevice
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var connected = false

    private static let appName = Data("MacMote".utf8).base64EncodedString()
    private var tokenKey: String { "token.\(device.id)" }
    private var token: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    init(device: TVDevice) { self.device = device }

    func connect() {
        var s = "wss://\(device.host):8002/api/v2/channels/samsung.remote.control?name=\(Self.appName)"
        if let token { s += "&token=\(token)" }
        guard let url = URL(string: s) else { return }
        delegate?.backend(state: token == nil ? .confirmOnTV : .connecting)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = token == nil ? 40 : 6 // user needs time to press "Allow"
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        let ws = session.webSocketTask(with: url)
        self.session = session
        socket = ws
        connected = false
        ws.resume()
        receive(ws)
    }

    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        connected = false
    }

    func resetPairing() {
        disconnect()
        token = nil
    }

    private func receive(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self, ws === self.socket else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(text)
                self.receive(ws)
            case .success:
                self.receive(ws)
            case .failure(let e):
                let wasConnected = self.connected
                self.disconnect()
                if wasConnected { self.delegate?.backend(state: .idle) } // dropped; reconnect on next action
                else { self.delegate?.backendUnreachable(e.localizedDescription) }
            }
        }
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let event = obj["event"] as? String else { return }
        let data = obj["data"]
        switch event {
        case "ms.channel.connect":
            if let t = (data as? [String: Any])?["token"] as? String { token = t }
            connected = true
            delegate?.backend(state: .connected)
            fetchMAC()
        case "ms.channel.unauthorized":
            token = nil
            disconnect()
            delegate?.backend(state: .offline("Доступ заборонено на TV"))
        case "ms.channel.timeOut":
            disconnect()
            delegate?.backend(state: .offline("Запит не підтверджено на TV"))
        case "ms.remote.imeStart":
            delegate?.backend(text: "")
        case "ms.remote.imeUpdate":
            if let b64 = data as? String, let d = Data(base64Encoded: b64) {
                delegate?.backend(text: String(decoding: d, as: UTF8.self))
            }
        default: break
        }
    }

    private func fetchMAC() {
        guard let url = URL(string: "http://\(device.host):8001/api/v2/") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mac = (obj["device"] as? [String: Any])?["wifiMac"] as? String else { return }
            DispatchQueue.main.async { self?.delegate?.backend(mac: mac.lowercased()) }
        }.resume()
    }

    private func send(_ params: [String: String]) {
        let msg: [String: Any] = ["method": "ms.remote.control", "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        socket?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func send(_ key: Key) {
        send(["Cmd": "Click", "DataOfCmd": key.samsungCode, "Option": "false", "TypeOfRemote": "SendRemoteKey"])
    }

    /// Samsung replaces the whole field with the string it receives.
    func editText(from old: String, to new: String) {
        send(["Cmd": Data(new.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"])
    }

    func submitText() {
        send(["TypeOfRemote": "SendInputEnd"])
    }

    func submitCode(_ code: String) {}

    // The TV uses a self-signed certificate; trust it only for this TV's address.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == device.host, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
