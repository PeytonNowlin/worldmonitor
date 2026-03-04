import Foundation

/// Service for C2IntelFeeds - Community-sourced C2 intelligence from GitHub
actor C2IntelService {
    static let shared = C2IntelService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.c2IntelFeeds
    
    // GitHub raw URLs for C2IntelFeeds
    private let feedURLs = [
        "https://raw.githubusercontent.com/drb-ra/C2IntelFeeds/master/feeds/all.txt",
        "https://raw.githubusercontent.com/drb-ra/C2IntelFeeds/master/feeds/daily.txt"
    ]
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch C2 intelligence from GitHub feeds
    func fetchC2Intel(
        confidence: C2IntelIOC.ConfidenceLevel? = nil,
        indicatorType: C2IntelIOC.IndicatorType? = nil
    ) async throws -> [C2IntelIOC] {
        return try await cache.fetchWithCache(
            source: .c2IntelFeeds,
            maxAge: DataSource.c2IntelFeeds.defaultCacheTTL
        ) {
            var allIOCs: [C2IntelIOC] = []
            
            for feedURL in self.feedURLs {
                guard let url = URL(string: feedURL) else { continue }
                
                do {
                    let data = try await self.httpClient.fetchData(url: url, source: .c2IntelFeeds)
                    
                    if let text = String(data: data, encoding: .utf8) {
                        let iocs = self.parseIntelFeed(text, source: feedURL)
                        allIOCs.append(contentsOf: iocs)
                    }
                } catch {
                    // Continue to next feed if one fails
                    continue
                }
            }
            
            // Filter by criteria
            return allIOCs.filter { ioc in
                if let confidence = confidence, ioc.confidence != confidence {
                    return false
                }
                if let type = indicatorType, ioc.indicatorType != type {
                    return false
                }
                return true
            }
        }
    }
    
    /// Fetch high-confidence C2 indicators
    func fetchHighConfidenceIOC() async throws -> [C2IntelIOC] {
        return try await fetchC2Intel(confidence: .high)
    }
    
    /// Get statistics
    func fetchStats() async throws -> C2IntelStats {
        let iocs = try await fetchC2Intel()
        
        var byType: [C2IntelIOC.IndicatorType: Int] = [:]
        var byMalwareFamily: [String: Int] = [:]
        var byConfidence: [C2IntelIOC.ConfidenceLevel: Int] = [:]
        var bySource: [String: Int] = [:]
        
        for ioc in iocs {
            byType[ioc.indicatorType, default: 0] += 1
            byMalwareFamily[ioc.malwareFamily, default: 0] += 1
            byConfidence[ioc.confidence, default: 0] += 1
            bySource[ioc.source, default: 0] += 1
        }
        
        return C2IntelStats(
            totalIOCs: iocs.count,
            byIndicatorType: byType,
            byMalwareFamily: byMalwareFamily,
            byConfidence: byConfidence,
            bySource: bySource,
            lastUpdated: Date()
        )
    }
    
    /// Search IOCs by indicator (IP, domain, etc.)
    func searchIOC(indicator: String) async throws -> [C2IntelIOC] {
        let iocs = try await fetchC2Intel()
        return iocs.filter { $0.indicator == indicator || $0.indicator.contains(indicator) }
    }
    
    /// Get IOCs by malware family
    func fetchByMalwareFamily(_ family: String) async throws -> [C2IntelIOC] {
        let iocs = try await fetchC2Intel()
        return iocs.filter { $0.malwareFamily.lowercased() == family.lowercased() }
    }
    
    /// Check if an indicator is known malicious
    func isMaliciousIndicator(_ indicator: String) async throws -> C2IntelIOC? {
        let iocs = try await fetchC2Intel()
        return iocs.first { $0.indicator == indicator }
    }
    
    /// Get all IOCs as IP addresses only
    func fetchIPAddresses() async throws -> [String] {
        let iocs = try await fetchC2Intel(indicatorType: .ipv4)
        return iocs.map { $0.indicator }
    }
    
    /// Get all IOCs as domains only
    func fetchDomains() async throws -> [String] {
        let iocs = try await fetchC2Intel(indicatorType: .domain)
        return iocs.map { $0.indicator }
    }
    
    // MARK: - Private Methods
    
    /// Parse the text feed format
    /// Format varies but typically: indicator,type,malware_family,first_seen,last_seen,confidence
    private func parseIntelFeed(_ text: String, source: String) -> [C2IntelIOC] {
        var iocs: [C2IntelIOC] = []
        let lines = text.components(separatedBy: .newlines)
        
        // Skip header line if present
        let dataLines = lines.dropFirst()
        
        for line in dataLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            
            let parts = trimmed.components(separatedBy: ",")
            
            // Try to parse based on common formats
            if parts.count >= 3 {
                let indicator = parts[0]
                let type = parseIndicatorType(parts[safe: 1] ?? "ipv4")
                let family = parts[safe: 2] ?? "unknown"
                let confidence = parseConfidence(parts[safe: 5] ?? "medium")
                
                let ioc = C2IntelIOC(
                    id: "\(source)-\(indicator)",
                    indicator: indicator,
                    indicatorType: type,
                    threatType: detectThreatType(family),
                    malwareFamily: family,
                    firstSeen: Date(),
                    lastSeen: Date(),
                    countryCode: nil,
                    source: source,
                    confidence: confidence
                )
                
                iocs.append(ioc)
            }
        }
        
        return iocs
    }
    
    private func parseIndicatorType(_ string: String) -> C2IntelIOC.IndicatorType {
        switch string.lowercased() {
        case "domain", "hostname": return .domain
        case "ip", "ipv4": return .ipv4
        case "ipv6": return .ipv6
        case "url": return .url
        case "md5": return .md5
        case "sha256": return .sha256
        default:
            // Detect by format
            if string.contains(".") && !string.contains(":") && string.rangeOfCharacter(from: CharacterSet.letters) != nil {
                return .domain
            } else if string.contains(":") {
                return .ipv6
            } else if string.contains("/") {
                return .url
            }
            return .ipv4
        }
    }
    
    private func parseConfidence(_ string: String) -> C2IntelIOC.ConfidenceLevel {
        switch string.lowercased() {
        case "high": return .high
        case "low": return .low
        default: return .medium
        }
    }
    
    private func detectThreatType(_ malwareFamily: String) -> ThreatType {
        let lower = malwareFamily.lowercased()
        if lower.contains("c2") || lower.contains("command") {
            return .c2Server
        } else if lower.contains("phish") {
            return .phishing
        } else if lower.contains("bot") {
            return .botnet
        }
        return .malwareHost
    }
}

// MARK: - Statistics Model

struct C2IntelStats: Codable {
    let totalIOCs: Int
    let byIndicatorType: [C2IntelIOC.IndicatorType: Int]
    let byMalwareFamily: [String: Int]
    let byConfidence: [C2IntelIOC.ConfidenceLevel: Int]
    let bySource: [String: Int]
    let lastUpdated: Date
    
    enum CodingKeys: String, CodingKey {
        case totalIOCs
        case byIndicatorType
        case byMalwareFamily
        case byConfidence
        case bySource
        case lastUpdated
    }
}

// MARK: - Helper Extensions

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
