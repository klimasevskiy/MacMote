import Foundation
import Network

/// Finds Android TVs (Bonjour) and Samsung TVs (SSDP + /api/v2) on the local network in parallel.
final class Discovery {
    private var found: [TVDevice] = []
    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []
    private var done: (([TVDevice]) -> Void)?

    func run(timeout: TimeInterval = 4, _ completion: @escaping ([TVDevice]) -> Void) {
        done = completion
        browseAndroid()
        scanSamsung()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish() }
    }

    func cancel() {
        done = nil
        finish()
    }

    private func finish() {
        browser?.cancel(); browser = nil
        resolvers.forEach { $0.cancel() }; resolvers.removeAll()
        let cb = done
        done = nil
        cb?(found.sorted { $0.name < $1.name })
    }

    private func add(_ d: TVDevice) {
        guard done != nil, !found.contains(where: { $0.id == d.id }) else { return }
        found.append(d)
    }

    // MARK: Android TV — Bonjour, then a TCP connect to learn the IPv4 address

    private func browseAndroid() {
        let b = NWBrowser(for: .bonjour(type: "_androidtvremote2._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results { self?.resolve(r.endpoint) }
        }
        browser = b
        b.start(queue: .main)
    }

    private func resolve(_ endpoint: NWEndpoint) {
        guard case .service(let name, _, _, _) = endpoint else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: endpoint, using: params)
        resolvers.append(c)
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                if case .hostPort(let h, _)? = c.currentPath?.remoteEndpoint {
                    var host = "\(h)"
                    if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
                    self?.add(TVDevice(kind: .android, name: name, host: host))
                }
                c.cancel()
            case .failed, .waiting: c.cancel()
            default: break
            }
        }
        c.start(queue: .main)
    }

    // MARK: Samsung — SSDP M-SEARCH, then confirm via the REST info endpoint

    private func scanSamsung() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Self.ssdpSearch { self?.probeSamsung($0) }
        }
    }

    private func probeSamsung(_ ip: String) {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dev = obj["device"] as? [String: Any],
                  (dev["OS"] as? String) == "Tizen" || (obj["type"] as? String)?.contains("Samsung") == true
            else { return }
            var name = (dev["name"] as? String) ?? "Samsung TV"
            if name.hasPrefix("[TV] ") { name.removeFirst(5) }
            DispatchQueue.main.async { self?.add(TVDevice(kind: .samsung, name: name, host: ip)) }
        }.resume()
    }

    /// Reports each IP that answers an SSDP search. Samsung only answers `ssdp:all` / specific
    /// targets and replies late, hence MX 2.
    private static func ssdpSearch(wait: TimeInterval = 3, onFound: (String) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        let msg = Array(("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n" +
                         "MX: 2\r\nST: ssdp:all\r\n\r\n").utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var seen = Set<String>()
        var buf = [UInt8](repeating: 0, count: 2048)
        let end = Date().addingTimeInterval(wait)
        while Date() < end {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            if seen.insert(ip).inserted { onFound(ip) }
        }
    }
}
