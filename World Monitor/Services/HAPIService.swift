import Foundation

/// Service for UN OCHA HAPI (Humanitarian API) displacement data
actor HAPIService {
    static let shared = HAPIService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.unOchaHAPI
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch displacement data by origin country
    func fetchDisplacementByOrigin() async throws -> [DisplacementData] {
        return try await cache.fetchWithCache(
            source: .unOchaHAPI,
            region: "by-origin",
            maxAge: DataSource.unOchaHAPI.defaultCacheTTL
        ) {
            // HAPI endpoint for refugees/IDPs
            let url = self.config.baseURL.appendingPathComponent("/population-social/pin")
            
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "output_format", value: "json"),
                URLQueryItem(name: "limit", value: "500")
            ]
            
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.queryItems = queryItems
            
            guard let finalURL = components?.url else {
                throw HTTPClientError.invalidURL
            }
            
            let data = try await self.httpClient.fetchData(url: finalURL, source: .unOchaHAPI)
            return self.parseDisplacementData(data, perspective: .origin)
        }
    }
    
    /// Fetch displacement data by host country
    func fetchDisplacementByHost() async throws -> [DisplacementData] {
        return try await cache.fetchWithCache(
            source: .unOchaHAPI,
            region: "by-host",
            maxAge: DataSource.unOchaHAPI.defaultCacheTTL
        ) {
            // Fetch asylum seekers/refugees by host country
            let url = config.baseURL.appendingPathComponent("/population-social/asylum")
            
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "output_format", value: "json"),
                URLQueryItem(name: "limit", value: "500")
            ]
            
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.queryItems = queryItems
            
            guard let finalURL = components?.url else {
                throw HTTPClientError.invalidURL
            }
            
            let data = try await httpClient.fetchData(url: finalURL, source: .unOchaHAPI)
            return self.parseDisplacementData(data, perspective: .host)
        }
    }
    
    /// Get global displacement statistics
    func fetchGlobalStats() async throws -> DisplacementStats {
        async let originTask = fetchDisplacementByOrigin()
        async let hostTask = fetchDisplacementByHost()
        
        let (originData, hostData) = try await (originTask, hostTask)
        
        // Calculate totals
        let totalRefugees = originData.reduce(0) { $0 + $1.refugees }
        let totalIDPs = originData.reduce(0) { $0 + $1.idps }
        
        // Top origin countries
        var originCounts: [String: Int] = [:]
        for data in originData {
            originCounts[data.countryName, default: 0] += data.totalDisplaced
        }
        
        let topOrigins = originCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { (country: $0.key, count: $0.value) }
        
        // Top host countries
        var hostCounts: [String: Int] = [:]
        for data in hostData {
            hostCounts[data.countryName, default: 0] += data.refugees + data.asylumSeekers
        }
        
        let topHosts = hostCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { (country: $0.key, count: $0.value) }
        
        return DisplacementStats(
            totalRefugees: totalRefugees,
            totalIDPs: totalIDPs,
            topOriginCountries: topOrigins,
            topHostCountries: topHosts,
            lastUpdated: Date()
        )
    }
    
    /// Get data for specific countries with extreme displacement
    func fetchCrisisCountries() async throws -> [DisplacementData] {
        let allData = try await fetchDisplacementByOrigin()
        return allData
            .filter { $0.severity == .extreme || $0.severity == .severe }
            .sorted { $0.totalDisplaced > $1.totalDisplaced }
    }
    
    /// Get data for a specific country
    func fetchCountryData(countryCode: String) async throws -> DisplacementData? {
        let allData = try await fetchDisplacementByOrigin()
        return allData.first { $0.countryCode.uppercased() == countryCode.uppercased() }
    }
    
    // MARK: - Private Methods
    
    private func parseDisplacementData(_ data: Data, perspective: Perspective) -> [DisplacementData] {
        // Simplified parsing - HAPI returns specific JSON structure
        // In production, parse according to HAPI schema
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["data"] as? [[String: Any]] {
                
                return results.compactMap { item in
                    guard let countryCode = item["iso3"] as? String ?? item["country_code"] as? String,
                          let countryName = item["country_name"] as? String else {
                        return nil
                    }
                    
                    let refugees = item["refugees"] as? Int ?? 0
                    let idps = item["idps"] as? Int ?? 0
                    let asylumSeekers = item["asylum_seekers"] as? Int ?? 0
                    
                    return DisplacementData(
                        id: "\(countryCode)-\(perspective)",
                        countryCode: countryCode,
                        countryName: countryName,
                        refugees: refugees,
                        idps: idps,
                        asylumSeekers: asylumSeekers,
                        returnedRefugees: item["returned_refugees"] as? Int ?? 0,
                        returnedIDPs: item["returned_idps"] as? Int ?? 0,
                        statelessPersons: item["stateless_persons"] as? Int ?? 0,
                        otherOfConcern: item["other_of_concern"] as? Int ?? 0,
                        dataDate: Date(),
                        source: "UN OCHA HAPI"
                    )
                }
            }
        } catch {
            return []
        }
        
        return []
    }
    
    private enum Perspective {
        case origin
        case host
    }
}
