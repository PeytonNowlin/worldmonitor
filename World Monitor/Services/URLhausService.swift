import Foundation

/// Service for URLhaus (abuse.ch) - Malicious URL intelligence
actor URLhausService {
    static let shared = URLhausService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.urlhaus
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch recent malicious URLs
    func fetchRecentURLs(
        status: URLhausEntry.URLStatus? = nil,
        tag: String? = nil,
        limit: Int = 100
    ) async throws -> [URLhausEntry] {
        return try await cache.fetchWithCache(
            source: .urlhaus,
            maxAge: DataSource.urlhaus.defaultCacheTTL
        ) {
            let url = self.config.baseURL.appendingPathComponent("/v1/urls/recent/")
            
            let data = try await self.httpClient.fetchData(url: url, source: .urlhaus)
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                
                // URLhaus uses: 2024-01-15 08:30:00 UTC
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                formatter.timeZone = TimeZone(identifier: "UTC")
                
                if let date = formatter.date(from: dateString) {
                    return date
                }
                
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
            }
            
            let response = try decoder.decode(URLhausRecentResponse.self, from: data)
            
            // Filter results
            return response.urls.filter { entry in
                if let status = status, entry.urlStatus != status {
                    return false
                }
                if let tag = tag, !entry.tags.contains(tag) {
                    return false
                }
                return true
            }.prefix(limit).map { $0 }
        }
    }
    
    /// Fetch currently active (online) malicious URLs
    func fetchActiveURLs(limit: Int = 100) async throws -> [URLhausEntry] {
        return try await fetchRecentURLs(status: .online, limit: limit)
    }
    
    /// Get statistics summary
    func fetchStats() async throws -> URLhausStats {
        let urls = try await fetchRecentURLs(limit: 1000)
        
        var byStatus: [URLhausEntry.URLStatus: Int] = [:]
        var byCountry: [String: Int] = [:]
        var byMalwareFamily: [String: Int] = [:]
        var byTag: [String: Int] = [:]
        
        for url in urls {
            byStatus[url.urlStatus, default: 0] += 1
            
            if let country = url.countryCode {
                byCountry[country, default: 0] += 1
            }
            
            if let family = url.malwareFamily {
                byMalwareFamily[family, default: 0] += 1
            }
            
            for tag in url.tags {
                byTag[tag, default: 0] += 1
            }
        }
        
        return URLhausStats(
            totalInSample: urls.count,
            onlineCount: byStatus[.online] ?? 0,
            offlineCount: byStatus[.offline] ?? 0,
            byCountry: byCountry,
            byMalwareFamily: byMalwareFamily,
            topTags: byTag.sorted { $0.value > $1.value }.prefix(10).map { (tag: $0.key, count: $0.value) },
            lastUpdated: Date()
        )
    }
    
    /// Search URLs by tag
    func searchByTag(_ tag: String, limit: Int = 50) async throws -> [URLhausEntry] {
        return try await fetchRecentURLs(tag: tag, limit: limit)
    }
    
    /// Get URLs by malware family
    func fetchByMalwareFamily(_ family: String) async throws -> [URLhausEntry] {
        let urls = try await fetchRecentURLs(limit: 1000)
        return urls.filter { $0.malwareFamily?.lowercased() == family.lowercased() }
    }
    
    /// Check if a URL is known malicious
    func isMaliciousURL(_ urlString: String) async throws -> URLhausEntry? {
        let urls = try await fetchRecentURLs(limit: 1000)
        return urls.first { $0.url == urlString || $0.hostName == urlString }
    }
    
    /// Get top active threats
    func fetchTopActiveThreats(limit: Int = 20) async throws -> [URLhausEntry] {
        let urls = try await fetchActiveURLs(limit: 200)
        return urls
            .sorted { $0.firstSeen > $1.firstSeen }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Statistics Model

struct URLhausStats {
    let totalInSample: Int
    let onlineCount: Int
    let offlineCount: Int
    let byCountry: [String: Int]
    let byMalwareFamily: [String: Int]
    let topTags: [(tag: String, count: Int)]
    let lastUpdated: Date
}
