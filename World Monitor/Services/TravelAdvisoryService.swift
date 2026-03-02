import Foundation

/// Service for US State Department Travel Advisories
actor TravelAdvisoryService {
    static let shared = TravelAdvisoryService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.usTravelAdvisory
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch all travel advisories
    func fetchAllAdvisories() async throws -> [TravelAdvisory] {
        return try await cache.fetchWithCache(
            source: .usTravelAdvisory,
            maxAge: DataSource.usTravelAdvisory.defaultCacheTTL
        ) {
            // State Department advisories JSON
            let url = URL(string: "https://travel.state.gov/content/travel/en/traveladvisories/traveladvisories.json")!
            
            let data = try await self.httpClient.fetchData(url: url, source: .usTravelAdvisory)
            
            return self.parseAdvisories(data)
        }
    }
    
    /// Fetch advisory for specific country
    func fetchAdvisory(countryCode: String) async throws -> TravelAdvisory? {
        let allAdvisories = try await fetchAllAdvisories()
        return allAdvisories.first { $0.countryCode.uppercased() == countryCode.uppercased() }
    }
    
    /// Get high-risk countries (Level 3 and 4)
    func fetchHighRiskCountries() async throws -> [TravelAdvisory] {
        let allAdvisories = try await fetchAllAdvisories()
        return allAdvisories
            .filter { $0.advisoryLevel.isRisky }
            .sorted { $0.advisoryLevel > $1.advisoryLevel }
    }
    
    /// Get Level 4 (Do Not Travel) countries
    func fetchDoNotTravelList() async throws -> [TravelAdvisory] {
        let allAdvisories = try await fetchAllAdvisories()
        return allAdvisories.filter { $0.advisoryLevel == .level4 }
    }
    
    /// Get statistics
    func fetchStats() async throws -> AdvisoryStats {
        let allAdvisories = try await fetchAllAdvisories()
        
        let counts = allAdvisories.reduce(into: [TravelAdvisory.AdvisoryLevel: Int]()) { counts, advisory in
            counts[advisory.advisoryLevel, default: 0] += 1
        }
        
        let highRisk = allAdvisories.filter { $0.advisoryLevel.isRisky }
            .sorted { $0.advisoryLevel > $1.advisoryLevel }
        
        return AdvisoryStats(
            totalCountries: allAdvisories.count,
            level1Count: counts[.level1] ?? 0,
            level2Count: counts[.level2] ?? 0,
            level3Count: counts[.level3] ?? 0,
            level4Count: counts[.level4] ?? 0,
            highRiskCountries: highRisk,
            lastUpdated: Date()
        )
    }
    
    /// Search advisories by country name
    func searchAdvisories(query: String) async throws -> [TravelAdvisory] {
        let allAdvisories = try await fetchAllAdvisories()
        let lowerQuery = query.lowercased()
        
        return allAdvisories.filter { advisory in
            advisory.countryName.lowercased().contains(lowerQuery) ||
            advisory.countryCode.lowercased() == lowerQuery
        }
    }
    
    /// Get advisories by level
    func fetchByLevel(_ level: TravelAdvisory.AdvisoryLevel) async throws -> [TravelAdvisory] {
        let allAdvisories = try await fetchAllAdvisories()
        return allAdvisories.filter { $0.advisoryLevel == level }
    }
    
    // MARK: - Private Methods
    
    private func parseAdvisories(_ data: Data) -> [TravelAdvisory] {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return json.compactMap { item in
                    guard let countryCode = item["country_code"] as? String ??
                          item["iso3"] as? String,
                          let countryName = item["country_name"] as? String ??
                          item["name"] as? String,
                          let levelInt = item["advisory_level"] as? Int ??
                          item["level"] as? Int else {
                        return nil
                    }
                    
                    let level = TravelAdvisory.AdvisoryLevel(rawValue: levelInt) ?? .level1
                    
                    return TravelAdvisory(
                        id: countryCode,
                        countryName: countryName,
                        countryCode: countryCode,
                        advisoryLevel: level,
                        advisoryText: item["advisory_text"] as? String ?? "",
                        lastUpdated: Date(),
                        specificWarnings: item["warnings"] as? [String] ?? [],
                        restrictedAreas: item["restricted_areas"] as? [String]
                    )
                }
            }
        } catch {
            // Return empty on parse error
            return []
        }
        
        return []
    }
}
