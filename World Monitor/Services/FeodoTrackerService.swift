import Foundation

/// Service for Feodo Tracker (abuse.ch) - C2 server intelligence
actor FeodoTrackerService {
    static let shared = FeodoTrackerService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.feodoTracker
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch C2 server blocklist
    func fetchC2Servers(
        malwareFamily: String? = nil,
        minSeverity: ThreatSeverity = .low
    ) async throws -> [FeodoC2Server] {
        return try await cache.fetchWithCache(
            source: .feodoTracker,
            maxAge: DataSource.feodoTracker.defaultCacheTTL
        ) {
            let url = self.config.baseURL.appendingPathComponent("/downloads/ipblocklist.json")
            
            let data = try await self.httpClient.fetchData(url: url, source: .feodoTracker)
            
            // Custom decoder for Feodo date format
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                
                // Try multiple date formats
                let formatters = [
                    "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd"
                ].map { format -> DateFormatter in
                    let f = DateFormatter()
                    f.dateFormat = format
                    f.timeZone = TimeZone(identifier: "UTC")
                    return f
                }
                
                for formatter in formatters {
                    if let date = formatter.date(from: dateString) {
                        return date
                    }
                }
                
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
            }
            
            let servers = try decoder.decode([FeodoC2Server].self, from: data)
            
            // Filter by criteria
            return servers.filter { server in
                // Filter by severity
                guard server.severity >= minSeverity else { return false }
                
                // Filter by malware family if specified
                if let family = malwareFamily {
                    return server.malwareFamily.lowercased() == family.lowercased()
                }
                
                return true
            }
        }
    }
    
    /// Fetch recent active C2 servers (seen in last 24 hours)
    func fetchRecentActiveC2(hours: Int = 24) async throws -> [FeodoC2Server] {
        let allServers = try await fetchC2Servers()
        let cutoffDate = Date().addingTimeInterval(-Double(hours) * 3600)
        
        return allServers.filter { $0.lastSeen >= cutoffDate }
    }
    
    /// Get statistics summary
    func fetchStats() async throws -> FeodoStats {
        let servers = try await fetchC2Servers()
        
        var byMalware: [String: Int] = [:]
        var byCountry: [String: Int] = [:]
        var byASN: [String: Int] = [:]
        
        for server in servers {
            byMalware[server.malwareFamily, default: 0] += 1
            if let country = server.countryCode {
                byCountry[country, default: 0] += 1
            }
            if let asn = server.asn {
                byASN[asn, default: 0] += 1
            }
        }
        
        return FeodoStats(
            totalServers: servers.count,
            activeInLast24h: servers.filter { $0.lastSeen >= Date().addingTimeInterval(-86400) }.count,
            byMalwareFamily: byMalware,
            byCountry: byCountry,
            topASNs: byASN.sorted { $0.value > $1.value }.prefix(10).map { (asn: $0.key, count: $0.value) },
            lastUpdated: Date()
        )
    }
    
    /// Get threat intelligence by malware family
    func fetchByMalwareFamily(_ family: String) async throws -> [FeodoC2Server] {
        return try await fetchC2Servers(malwareFamily: family)
    }
    
    /// Check if an IP is a known C2 server
    func isKnownC2(ipAddress: String) async throws -> FeodoC2Server? {
        let servers = try await fetchC2Servers()
        return servers.first { $0.ipAddress == ipAddress }
    }
    
    /// Get top threats by severity
    func fetchTopThreats(limit: Int = 20) async throws -> [FeodoC2Server] {
        let servers = try await fetchC2Servers(minSeverity: .medium)
        return servers
            .sorted { $0.severity > $1.severity || ($0.severity == $1.severity && $0.lastSeen > $1.lastSeen) }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Statistics Model

struct FeodoStats {
    let totalServers: Int
    let activeInLast24h: Int
    let byMalwareFamily: [String: Int]
    let byCountry: [String: Int]
    let topASNs: [(asn: String, count: Int)]
    let lastUpdated: Date
}
