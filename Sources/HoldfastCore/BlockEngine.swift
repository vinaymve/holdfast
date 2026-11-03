// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// Port of BlockManager: turns a list of entries into /etc/hosts rules and pf rules, and tears them down again.
public final class BlockEngine {
    public struct Config {
        public var isAllowlist: Bool
        public var allowLocalNetworks: Bool
        public var includeCommonSubdomains: Bool
        public var includeLinkedDomains: Bool

        public init(isAllowlist: Bool, allowLocalNetworks: Bool = true,
                    includeCommonSubdomains: Bool = true, includeLinkedDomains: Bool = true) {
            self.isAllowlist = isAllowlist
            self.allowLocalNetworks = allowLocalNetworks
            self.includeCommonSubdomains = includeCommonSubdomains
            self.includeLinkedDomains = includeLinkedDomains
        }

        public init(block: ActiveBlock) {
            self.init(isAllowlist: block.isAllowlist,
                      allowLocalNetworks: block.options.allowLocalNetworks,
                      includeCommonSubdomains: block.options.evaluateCommonSubdomains,
                      includeLinkedDomains: block.options.includeLinkedDomains)
        }
    }

    public let config: Config
    private let paths: SystemPaths
    private let hosts: HostsFileEditor
    private let pf: PacketFilter
    private let resolver: DomainResolving
    private let scraper: LinkScraping

    private let queue: OperationQueue
    private let lock = NSLock()
    private var seen = Set<BlockEntry>()
    private var hostDomains: [String] = []
    private var hostDomainSet = Set<String>()
    private var hostsBlockingEnabled = false
    private var appendMode = false

    public init(config: Config, paths: SystemPaths = .production, runner: CommandRunner = ProcessRunner(),
                resolver: DomainResolving = SystemResolver(), scraper: LinkScraping = HTTPLinkScraper()) {
        self.config = config
        self.paths = paths
        self.hosts = HostsFileEditor(path: paths.hosts)
        self.pf = PacketFilter(isAllowlist: config.isAllowlist, allowLocalNetworks: config.allowLocalNetworks,
                               paths: paths, runner: runner)
        self.resolver = resolver
        self.scraper = scraper
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 35
    }

    // MARK: Building a block

    public func prepareToAddBlock() {
        if hosts.containsBlock() { hosts.removeBlock() }
        if !config.isAllowlist {
            hosts.createBackup()
            hostsBlockingEnabled = true
        } else {
            hostsBlockingEnabled = false
        }
    }

    public func add(_ strings: [String]) {
        for string in strings {
            queue.addOperation { [self] in addEntry(fromString: string) }
        }
    }

    public func finalizeBlock() throws {
        queue.waitUntilAllOperationsAreFinished()
        if hostsBlockingEnabled {
            try hosts.installBlock(domains: domainsSnapshot())
        }
        try pf.startBlock()
    }

    // MARK: Appending to a running blocklist

    public func beginAppending() throws {
        guard !config.isAllowlist else { throw SCError(.allowlistCannotBeUpdated) }
        guard hosts.containsBlock() else { throw SCError(.ioFailure, "No hosts block exists to extend.") }
        hostsBlockingEnabled = true
        appendMode = true
        pf.beginAppending()
    }

    public func finishAppending() throws {
        queue.waitUntilAllOperationsAreFinished()
        defer { appendMode = false }
        try hosts.appendToBlock(domains: domainsSnapshot())
        try pf.finishAppending()
    }

    // MARK: Tearing down

    /// Removes pf and hosts rules. Returns true if both are verifiably gone.
    @discardableResult
    public func clearBlock() -> Bool { teardown(force: false) }

    @discardableResult
    public func forceClearBlock() -> Bool { teardown(force: true) }

    private func teardown(force: Bool) -> Bool {
        pf.stopBlock(force: force)
        let pfGone = !pf.containsBlock

        let hostsGone = hosts.removeBlock()
        var cleared = pfGone && hostsGone

        if !cleared {
            if !pfGone { pf.stopBlock(force: true) }
            if !hostsGone { hosts.restoreBackup() }
            cleared = !blockIsActive
        }
        hosts.deleteBackup()
        return cleared
    }

    public var blockIsActive: Bool { hosts.containsBlock() || pf.containsBlock }

    // MARK: Entry handling

    private func domainsSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return hostDomains
    }

    private func addHostsDomain(_ domain: String) {
        lock.lock(); defer { lock.unlock() }
        if hostDomainSet.insert(domain).inserted { hostDomains.append(domain) }
    }

    /// Port of addBlockEntryFromString: queue related entries first so they resolve in parallel.
    private func addEntry(fromString string: String) {
        guard let entry = BlockEntry.parse(string) else { return }
        for related in relatedEntries(for: entry) {
            queue.addOperation { [self] in addParsed(related) }
        }
        addParsed(entry)
    }

    func relatedEntries(for entry: BlockEntry) -> [BlockEntry] {
        guard !entry.isIP, !entry.isWildcard else { return [] }
        var related: [BlockEntry] = []
        if config.isAllowlist && config.includeLinkedDomains {
            for host in scraper.relatedHosts(for: entry.hostname) {
                related.append(BlockEntry(hostname: host))
            }
        }
        if config.includeCommonSubdomains {
            for host in CommonSubdomains.hosts(for: entry.hostname) {
                // Derived entries keep the original's port, so "mail.example.com:993" doesn't
                // turn into a full hosts-level block of "www.mail.example.com".
                if let parsed = BlockEntry.parse(host) {
                    related.append(BlockEntry(hostname: parsed.hostname, port: entry.port, maskLen: parsed.maskLen))
                }
            }
        }
        return related
    }

    private func addParsed(_ entry: BlockEntry) {
        lock.lock()
        let isNew = seen.insert(entry).inserted
        lock.unlock()
        guard isNew else { return }

        if entry.isWildcard {
            pf.addRule(ip: nil, port: entry.port, maskLen: 0)
        } else if entry.isIP {
            pf.addRule(ip: entry.hostname, port: entry.port, maskLen: entry.maskLen)
        } else if GoogleRanges.isGoogleDomain(entry.hostname) {
            // Google shares IPs across Search/Mail/YouTube, so blocklists rely on hosts-level blocking only.
            // Allowlists would be hopelessly error-prone any other way, so allow Google's whole range.
            if config.isAllowlist {
                for cidr in GoogleRanges.cidrs {
                    let parts = cidr.split(separator: "/")
                    pf.addRule(ip: String(parts[0]), port: 0, maskLen: Int(parts[1]) ?? 0)
                }
            }
        } else {
            for ip in resolver.addresses(for: entry.hostname) {
                pf.addRule(ip: ip, port: entry.port, maskLen: entry.maskLen)
            }
        }

        if hostsBlockingEnabled, entry.isDomain, entry.port == 0 {
            addHostsDomain(entry.hostname)
        }
    }
}
