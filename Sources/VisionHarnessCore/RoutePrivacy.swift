import Foundation

// MARK: - Which models may see sensitive data
//
// A route is *private* when the model runs on hardware you control — a DGX Spark or a Strix Halo box on your
// network, Ollama on this Mac. Private models may see sensitive data; the others (every online service: OpenAI,
// Amazon Bedrock, the subscription plans) get it masked (see `ShieldClient`). The default is decided by the
// address alone, and in the safe direction: only an address that can't be anything but your own network counts.
// (This is deliberately not `isSelfHosted`, which takes an unknown host to be self-hosted — the wrong way round
// for privacy.) The user can flip it either way; an explicit choice is stored on the route and wins.

public enum RoutePrivacy {
    /// The default for a route the user hasn't decided about.
    public static func isPrivateByDefault(_ route: ProviderProfile) -> Bool {
        // Bedrock is Amazon's service; Claude Code sends what it reads to Anthropic.
        route.kind == .bedrock || route.kind == .claudeCode ? false : isPrivateAddress(route.baseURL)
    }

    /// Whether a base URL's host is your own: `localhost`, a loopback / private (RFC 1918) / link-local /
    /// carrier-grade NAT (100.64.0.0/10 — Tailscale) / IPv6 unique-local or loopback address, a single-label
    /// host name, or a name under `.local`, `.lan`, `.home`, `.home.arpa`, `.internal` or `.ts.net`.
    public static func isPrivateAddress(_ baseURL: String) -> Bool {
        guard let host = hostOf(baseURL) else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if let v4 = ipv4(host) { return isPrivateIPv4(v4) }
        if host.contains(":") { return isPrivateIPv6(host) }
        // A name: one label (a machine on the LAN — "spark", "nas"), or a local-only suffix.
        if !host.contains(".") { return !host.isEmpty }
        let suffixes = [".local", ".lan", ".home", ".home.arpa", ".internal", ".ts.net"]
        return suffixes.contains { host.hasSuffix($0) }
    }

    /// The lower-cased host of a URL, without IPv6 brackets or a trailing dot.
    static func hostOf(_ baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://" + trimmed),
              var host = components.percentEncodedHost ?? components.host else { return nil }
        host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// The four octets of a dotted-quad address, or nil.
    static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            octets.append(value)
        }
        return octets
    }

    static func isPrivateIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (127, _): return true                       // loopback
        case (10, _): return true                        // RFC 1918
        case (172, 16...31): return true                 // RFC 1918
        case (192, 168): return true                     // RFC 1918
        case (169, 254): return true                     // link-local
        case (100, 64...127): return true                // carrier-grade NAT (Tailscale)
        default: return false
        }
    }

    static func isPrivateIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host   // drop a zone ("fe80::1%en0")
        if address == "::1" { return true }
        // IPv4-mapped: ::ffff:192.168.1.5
        if address.hasPrefix("::ffff:"), let v4 = ipv4(String(address.dropFirst(7))) { return isPrivateIPv4(v4) }
        guard let first = address.split(separator: ":", omittingEmptySubsequences: false).first,
              let group = UInt16(first.isEmpty ? "0" : String(first), radix: 16) else { return false }
        if group & 0xFE00 == 0xFC00 { return true }      // unique-local fc00::/7
        if group & 0xFFC0 == 0xFE80 { return true }      // link-local fe80::/10
        return false
    }
}
