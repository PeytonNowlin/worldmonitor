import Foundation

/// Service for Cloudflare Radar internet connectivity data
actor CloudflareRadarService {
    static let shared = CloudflareRadarService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.cloudflareRadar
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch global internet connectivity data
    func fetchConnectivityData() async throws -> [CloudflareRadarData] {
        return try await cache.fetchWithCache(
            source: .cloudflareRadar,
            region: "global",
            maxAge: DataSource.cloudflareRadar.defaultCacheTTL
        ) {
            let url = self.config.baseURL.appendingPathComponent("/radar/http/timeseries")
            
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "aggInterval", value: "1h"),
                URLQueryItem(name: "dateRange", value: "1d")
            ]
            
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.queryItems = queryItems
            
            guard let finalURL = components?.url else {
                throw HTTPClientError.invalidURL
            }
            
            let data = try await self.httpClient.fetchData(url: finalURL, source: .cloudflareRadar)
            
            // Parse Cloudflare Radar response
            return self.parseRadarData(data)
        }
    }
    
    /// Fetch connectivity for a specific country
    func fetchCountryConnectivity(countryCode: String) async throws -> CloudflareRadarData? {
        let allData = try await fetchConnectivityData()
        return allData.first { $0.countryCode.uppercased() == countryCode.uppercased() }
    }
    
    /// Get countries with degraded connectivity
    func fetchDegradedConnectivity(threshold: Double = 70) async throws -> [CloudflareRadarData] {
        let allData = try await fetchConnectivityData()
        return allData.filter { $0.connectivityScore < threshold }
            .sorted { $0.connectivityScore < $1.connectivityScore }
    }
    
    /// Get outage events (significant drops in connectivity)
    func detectOutageEvents() async throws -> [CloudflareOutageEvent] {
        let data = try await fetchConnectivityData()
        
        // Countries with severe connectivity issues
        return data
            .filter { $0.status == .severe }
            .map { countryData in
                CloudflareOutageEvent(
                    id: "outage-\(countryData.countryCode)-\(Int(countryData.timestamp.timeIntervalSince1970))",
                    countryCode: countryData.countryCode,
                    countryName: countryData.countryName,
                    startTime: countryData.timestamp,
                    endTime: nil,
                    severity: .critical,
                    description: "Connectivity at \(Int(countryData.connectivityScore))%"
                )
            }
    }
    
    /// Get connectivity statistics
    func fetchStats() async throws -> CloudflareStats {
        let data = try await fetchConnectivityData()
        
        let total = data.count
        let normal = data.filter { $0.status == .normal }.count
        let degraded = data.filter { $0.status == .degraded }.count
        let severe = data.filter { $0.status == .severe }.count
        
        let avgScore = data.isEmpty
            ? 0
            : data.map { $0.connectivityScore }.reduce(0, +) / Double(data.count)
        
        let worstCountries = data
            .sorted { $0.connectivityScore < $1.connectivityScore }
            .prefix(10)
            .map { $0 }
        
        return CloudflareStats(
            countriesMonitored: total,
            normalConnectivity: normal,
            degradedConnectivity: degraded,
            severeConnectivity: severe,
            averageConnectivityScore: avgScore,
            worstAffectedCountries: worstCountries,
            lastUpdated: Date()
        )
    }
    
    // MARK: - Private Methods
    
    private func parseRadarData(_ data: Data) -> [CloudflareRadarData] {
        // Simplified parsing - Cloudflare API returns complex JSON
        // In production, parse the actual response structure
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]] {
                
                return dataArray.compactMap { item in
                    guard let countryCode = item["countryCode"] as? String,
                          let score = item["connectivityScore"] as? Double else {
                        return nil
                    }
                    
                    return CloudflareRadarData(
                        id: "\(countryCode)-\(Date().timeIntervalSince1970)",
                        countryCode: countryCode,
                        countryName: item["countryName"] as? String ?? countryCode,
                        connectivityScore: score,
                        httpRequests: item["httpRequests"] as? Int64 ?? 0,
                        timestamp: Date(),
                        change1h: item["change1h"] as? Double,
                        change24h: item["change24h"] as? Double
                    )
                }
            }
        } catch {
            return []
        }
        
        return []
    }
}

// MARK: - Statistics Model

struct CloudflareStats: Codable {
    let countriesMonitored: Int
    let normalConnectivity: Int
    let degradedConnectivity: Int
    let severeConnectivity: Int
    let averageConnectivityScore: Double
    let worstAffectedCountries: [CloudflareRadarData]
    let lastUpdated: Date
}
