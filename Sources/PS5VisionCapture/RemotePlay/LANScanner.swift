import Darwin
import Foundation

/// Finds PlayStation consoles on the local /24 network WITHOUT broadcast or
/// multicast: it sends the PlayStation discovery request ("SRCH") as unicast
/// UDP to every address of the subnet. Unicast only needs the Local Network
/// permission, not the `com.apple.developer.networking.multicast`
/// entitlement that broadcast discovery requires.
///
/// The console answers from port 9302 (PS5) or 987 (PS4) with an HTTP-like
/// reply: "HTTP/1.1 200 Ok" (ready) or "HTTP/1.1 620 Server Standby".
final class LANScanner: @unchecked Sendable {
    /// Called on the main queue with the consoles found so far.
    var onUpdate: (([DiscoveredConsole]) -> Void)?
    /// Called on the main queue when the scan ends.
    var onFinish: (() -> Void)?

    private let queue = DispatchQueue(label: "RemotePlay.lanScanner")
    private var cancelled = false
    private var found: [String: DiscoveredConsole] = [:]

    private static let ps5Port: UInt16 = 9302
    private static let ps4Port: UInt16 = 987
    private static let ps5Request = "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n"
    private static let ps4Request = "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00020020\n"

    /// Scans for `duration` seconds, sending three rounds of requests.
    func start(duration: TimeInterval = 4) {
        cancelled = false
        queue.async { [self] in
            found = [:]
            run(duration: duration)
        }
    }

    func stop() { cancelled = true }

    // MARK: - Local network

    /// IPv4 address and netmask of the Wi-Fi/Ethernet interface.
    static func localSubnet() -> (address: UInt32, mask: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: (UInt32, UInt32)?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Prefer en* (Wi-Fi / Ethernet); skip link-local 169.254/16.
            if a >> 16 == 0xA9FE { continue }
            if name.hasPrefix("en") { return (a, m) }
            if best == nil { best = (a, m) }
        }
        return best
    }

    // MARK: - Scan

    private func run(duration: TimeInterval) {
        defer { DispatchQueue.main.async { [self] in onFinish?() } }
        guard let (address, mask) = Self.localSubnet() else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Never scan more than a /24 around our own address: larger subnets
        // would take long and look like a port scan.
        let effectiveMask = max(mask, 0xFFFF_FF00)
        let network = address & effectiveMask
        let hostCount = Int(~effectiveMask)
        let targets: [UInt32] = (1..<hostCount).map { network | UInt32($0) }.filter { $0 != address }

        let deadline = Date().addingTimeInterval(duration)
        var round = 0
        var nextRound = Date()
        while !cancelled && Date() < deadline {
            if round < 3 && Date() >= nextRound {
                for target in targets where !cancelled {
                    send(fd, Self.ps5Request, to: target, port: Self.ps5Port)
                    send(fd, Self.ps4Request, to: target, port: Self.ps4Port)
                }
                round += 1
                nextRound = Date().addingTimeInterval(1)
            }
            receive(fd)
        }
    }

    private func send(_ fd: Int32, _ text: String, to ip: UInt32, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = ip.bigEndian
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func receive(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen)
            }
        }
        guard n > 0 else { return }
        let ip = UInt32(bigEndian: from.sin_addr.s_addr)
        let address = "\(ip >> 24).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
        let port = UInt16(bigEndian: from.sin_port)
        guard let text = String(bytes: buffer[0..<n], encoding: .utf8),
              let console = Self.parse(text, address: address, port: port) else { return }
        found[console.id] = console
        let list = found.values.sorted { $0.address < $1.address }
        DispatchQueue.main.async { [self] in onUpdate?(list) }
    }

    static func parse(_ text: String, address: String, port: UInt16) -> DiscoveredConsole? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let status = lines.first, status.hasPrefix("HTTP/1.1") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let state: DiscoveredConsole.State
        if status.contains(" 200") { state = .ready }
        else if status.contains(" 620") { state = .standby }
        else { state = .unknown }
        let type = headers["host-type"]?.uppercased() ?? ""
        let isPS5 = type.contains("PS5") || (type.isEmpty && port == ps5Port)
        return DiscoveredConsole(address: address,
                                 name: headers["host-name"] ?? "",
                                 hostID: headers["host-id"] ?? "",
                                 runningApp: headers["running-app-name"] ?? "",
                                 isPS5: isPS5, state: state)
    }
}
