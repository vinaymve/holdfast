// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import Darwin

/// Minimal SNTP client (RFC 4330). Used only to settle "was the clock moved while the Mac was off?" after a reboot.
public enum NetworkTime {
    static let ntpEpochOffset: TimeInterval = 2_208_988_800   // seconds from 1900 to 1970

    static func makeRequest(nonce: [UInt8]) -> [UInt8] {
        precondition(nonce.count == 8)
        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = 0b00_100_011           // leap 0, version 4, mode 3 (client)
        packet.replaceSubrange(40..<48, with: nonce)   // transmit timestamp: random, echoed back as origin
        return packet
    }

    /// Validates a server reply and returns its transmit time, or nil if it doesn't look like a real answer to us.
    static func parseResponse(_ bytes: [UInt8], nonce: [UInt8]) -> Date? {
        guard bytes.count >= 48 else { return nil }
        let mode = bytes[0] & 0b111
        let leap = bytes[0] >> 6
        let stratum = bytes[1]
        guard mode == 4, leap != 3, (1...15).contains(stratum) else { return nil }
        guard Array(bytes[24..<32]) == nonce else { return nil }     // reply to *our* request

        var seconds: UInt64 = 0
        for byte in bytes[40..<44] { seconds = seconds << 8 | UInt64(byte) }
        var fraction: UInt64 = 0
        for byte in bytes[44..<48] { fraction = fraction << 8 | UInt64(byte) }
        guard seconds > 0 else { return nil }
        let unix = TimeInterval(seconds) - ntpEpochOffset + TimeInterval(fraction) / 4_294_967_296
        return Date(timeIntervalSince1970: unix)
    }

    /// Parses an HTTP `Date` header ("Tue, 03 Nov 2026 12:34:56 GMT").
    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    /// Time from an HTTPS response's `Date` header. Many networks block NTP (UDP 123) but allow HTTPS. TLS needs the
    /// clock to be roughly right, but a clock moved by hours or days still validates, and the header can't be forged
    /// without breaking the certificate. One-second resolution is plenty for a 60 s tolerance.
    /// Blocking; call off the daemon's work queue.
    public static func queryHTTPS(url: URL = URL(string: "https://www.apple.com")!, timeout: TimeInterval = 5,
                                  configuration: URLSessionConfiguration = .ephemeral) -> Date? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        session.dataTask(with: request) { _, response, _ in
            box.header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date")
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 1) == .success, let header = box.header,
              let date = parseHTTPDate(header) else { return nil }
        let roundTrip = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started) / 1_000_000_000
        return date.addingTimeInterval(roundTrip / 2)
    }

    private final class Box: @unchecked Sendable { var header: String? }

    /// SNTP first, then HTTPS. Blocking.
    public static func current() -> Date? { query() ?? queryHTTPS() }

    /// Blocking; call off the daemon's work queue. Returns nil if offline or the reply is unusable.
    public static func query(host: String = "time.apple.com", timeout: TimeInterval = 2.5) -> Date? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "123", &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let nonce = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let request = makeRequest(nonce: nonce)
        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let sent = request.withUnsafeBytes { sendto(fd, $0.baseAddress, request.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen) }
        guard sent == request.count else { return nil }

        var reply = [UInt8](repeating: 0, count: 128)
        let received = recv(fd, &reply, reply.count, 0)
        guard received >= 48 else { return nil }
        let roundTrip = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started) / 1_000_000_000

        guard let serverTime = parseResponse(Array(reply.prefix(received)), nonce: nonce) else { return nil }
        return serverTime.addingTimeInterval(roundTrip / 2)
    }
}
