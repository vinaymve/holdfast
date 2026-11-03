// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import Darwin

public protocol DomainResolving {
    func addresses(for host: String) -> [String]
}

public protocol LinkScraping {
    /// Other hostnames a page links to; used so allowlisted sites keep working (CDNs, etc.).
    func relatedHosts(for host: String) -> Set<String>
}

public struct SystemResolver: DomainResolving {
    public init() {}

    public func addresses(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var seen = Set<String>()
        var ordered: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if seen.insert(ip).inserted { ordered.append(ip) }
            }
            cursor = info.pointee.ai_next
        }
        return ordered
    }
}

public struct NoScraper: LinkScraping {
    public init() {}
    public func relatedHosts(for host: String) -> Set<String> { [] }
}

/// Port of AllowlistScraper: fetch the site's front page and collect the hosts it links to.
/// This runs inside a root daemon on arbitrary web content, so the download is size-capped and uses no disk cache.
public struct HTTPLinkScraper: LinkScraping {
    public static let maxBodyBytes = 1_000_000
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    private static let neverAdd: Set<String> = [
        "instagram.com", "www.instagram.com", "twitter.com", "www.twitter.com", "facebook.com",
        "www.facebook.com", "reddit.com", "www.reddit.com", "youtube.com", "www.youtube.com",
        "pinterest.com", "plus.google.com", "www.pinterest.com", "linkedin.com", "www.linkedin.com",
        "tumblr.com", "www.tumblr.com",
    ]

    private final class Collector: NSObject, URLSessionDataDelegate {
        let limit: Int
        private let lock = NSLock()
        private var buffer = Data()
        private var finished = false
        let done = DispatchSemaphore(value: 0)

        init(limit: Int) { self.limit = limit }

        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer.prefix(limit) }

        private func finish() {
            lock.lock(); defer { lock.unlock() }
            if !finished { finished = true; done.signal() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            buffer.append(data)
            let full = buffer.count >= limit
            lock.unlock()
            if full {
                dataTask.cancel()      // stop downloading; we only need the start of the page
                finish()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish() }
    }

    /// At most `maxBodyBytes` of the response, or nil if nothing came back.
    func fetchBody(of url: URL) -> Data? {
        let collector = Collector(limit: Self.maxBodyBytes)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        let task = session.dataTask(with: request)
        task.resume()
        if collector.done.wait(timeout: .now() + 6) == .timedOut { task.cancel() }
        let data = collector.data
        return data.isEmpty ? nil : data
    }

    public func relatedHosts(for host: String) -> Set<String> {
        guard let root = URL(string: "http://\(host)"), let body = fetchBody(of: root),
              let html = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }

        var found = Set<String>()
        detector.enumerateMatches(in: html, range: NSRange(html.startIndex..., in: html)) { match, _, _ in
            guard let url = match?.url, let scheme = url.scheme, ["http", "https"].contains(scheme),
                  let linkHost = url.host?.lowercased(), !linkHost.isEmpty, linkHost != root.host,
                  BlockEntry.isValidHostname(linkHost), !Self.neverAdd.contains(linkHost) else { return }
            found.insert(linkHost)
        }
        return found
    }
}

public enum CommonSubdomains {
    // https://developers.facebook.com/docs/sharing/webmasters/crawler (as of the original port)
    static let facebookRanges = [
        "31.13.24.0/21", "31.13.64.0/18", "45.64.40.0/22", "66.220.144.0/20", "69.63.176.0/20",
        "69.171.224.0/19", "74.119.76.0/22", "102.132.96.0/20", "103.4.96.0/22", "129.134.0.0/16",
        "147.75.208.0/20", "157.240.0.0/16", "173.252.64.0/18", "179.60.192.0/22", "185.60.216.0/22",
        "185.89.216.0/22", "199.201.64.0/22", "204.15.20.0/22",
    ]

    /// "m.facebook.com" and "facebook.com" match "facebook.com"; "notfacebook.com" doesn't.
    static func isSameOrSubdomain(_ host: String, of domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Extra hosts to block alongside `host` so a mirror or subdomain doesn't leak through.
    public static func hosts(for host: String) -> [String] {
        var extra = Set<String>()
        if isSameOrSubdomain(host, of: "facebook.com") { extra.formUnion(facebookRanges) }
        if isSameOrSubdomain(host, of: "twitter.com") { extra.insert("api.twitter.com") }
        if isSameOrSubdomain(host, of: "netflix.com") { extra.formUnion(["assets.nflxext.com", "codex.nflxext.com", "nflxext.com"]) }
        if host.hasPrefix("www.") {
            extra.insert(String(host.dropFirst(4)))
        } else {
            extra.insert("www." + host)
        }
        return extra.sorted()
    }
}

public enum GoogleRanges {
    private static let regex = try! NSRegularExpression(
        pattern: #"^([a-z0-9]+\.)*(google|youtube|picasa|sketchup|blogger|blogspot)\.([a-z]{1,3})(\.[a-z]{1,3})?$"#)

    public static func isGoogleDomain(_ host: String) -> Bool {
        regex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil
    }

    /// From https://www.gstatic.com/ipranges/goog.json (last synced with the original on 2021-09-23).
    /// The original had a typo (23.236.48.0/240) and several duplicate lines; both are fixed here.
    public static let cidrs: [String] = [
        "8.8.4.0/24", "8.34.208.0/20", "8.35.192.0/20", "23.236.48.0/20", "23.251.128.0/19", "34.64.0.0/10",
        "34.128.0.0/10", "35.184.0.0/13", "35.192.0.0/14", "35.196.0.0/15", "35.198.0.0/16", "35.199.0.0/17",
        "35.199.128.0/18", "35.200.0.0/13", "35.208.0.0/12", "35.224.0.0/12", "35.240.0.0/13", "64.15.112.0/20",
        "64.233.160.0/19", "66.102.0.0/20", "66.249.64.0/19", "70.32.128.0/19", "72.14.192.0/18", "74.114.24.0/21",
        "74.125.0.0/16", "104.154.0.0/16", "104.196.0.0/14", "104.237.160.0/19", "107.167.160.0/19",
        "107.178.192.0/18", "108.59.80.0/20", "108.170.192.0/18", "108.177.0.0/17", "130.211.0.0/16",
        "136.112.0.0/12", "142.250.0.0/15", "146.148.0.0/17", "162.216.148.0/22", "162.222.176.0/21",
        "172.110.32.0/21", "172.217.0.0/16", "172.253.0.0/16", "173.194.0.0/16", "173.255.112.0/20",
        "192.158.28.0/22", "192.178.0.0/15", "193.186.4.0/24", "199.36.154.0/23", "199.36.156.0/24",
        "199.192.112.0/22", "199.223.232.0/21", "207.223.160.0/20", "208.65.152.0/22", "208.68.108.0/22",
        "208.81.188.0/22", "208.117.224.0/19", "209.85.128.0/17", "216.58.192.0/19", "216.73.80.0/20",
        "216.239.32.0/19", "2001:4860::/32", "2404:6800::/32", "2404:f340::/32", "2600:1900::/28",
        "2606:73c0::/32", "2607:f8b0::/32", "2620:11a:a000::/40", "2620:120:e000::/40", "2800:3f0::/32",
        "2a00:1450::/32", "2c0f:fb50::/32",
    ]
}

public enum Presets {
    public static let commonDistractingWebsites = [
        "facebook.com", "twitter.com", "reddit.com", "tumblr.com", "youtube.com", "9gag.com", "netflix.com",
        "hulu.com", "buzzfeed.com", "dailymotion.com", "pinterest.com", "instagram.com", "tiktok.com",
        "twitch.tv", "x.com",
    ]

    public static let newsAndPublications = [
        "cnn.com", "huffingtonpost.com", "foxnews.com", "nytimes.com", "bbc.com", "bbc.co.uk", "telegraph.co.uk",
        "news.google.com", "buzzfeed.com", "vice.com", "forbes.com", "usatoday.com", "theonion.com",
        "news.yahoo.com", "washingtonpost.com", "wsj.com", "theguardian.com", "latimes.com", "nydailynews.com",
        "salon.com", "msnbc.com", "bloomberg.com", "drudgereport.com", "nationalgeographic.com", "nypost.com",
        "chicagotribune.com", "msn.com", "usnews.com", "news.ycombinator.com",
    ]

    public static let starterProfiles: [Profile] = [
        Profile(name: "Social & Video", symbol: "bubble.left.and.bubble.right.fill", entries: commonDistractingWebsites),
        Profile(name: "News", symbol: "newspaper.fill", entries: newsAndPublications),
    ]
}
