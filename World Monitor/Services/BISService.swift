import Foundation

/// Service for BIS (Bank for International Settlements) data
actor BISService {
    static let shared = BISService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.bis
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch policy rates for major economies
    func fetchPolicyRates() async throws -> [BISPolicyRate] {
        return try await cache.fetchWithCache(
            source: .bis,
            region: "policy-rates",
            maxAge: DataSource.bis.defaultCacheTTL
        ) {
            // BIS data structure is complex, this is simplified
            // In production, you'd parse their specific SDMX format
            let url = self.config.baseURL.appendingPathComponent("/data/WS_CBPOL/all/latest")
            
            let data = try await self.httpClient.fetchData(url: url, source: .bis)
            
            // Parse BIS response (simplified)
            return self.parsePolicyRates(data)
        }
    }
    
    /// Fetch Real Effective Exchange Rates (REER)
    func fetchREER() async throws -> [BISREER] {
        return try await cache.fetchWithCache(
            source: .bis,
            region: "reer",
            maxAge: DataSource.bis.defaultCacheTTL
        ) {
            let url = config.baseURL.appendingPathComponent("/data/WS_REER/all/latest")
            
            let data = try await httpClient.fetchData(url: url, source: .bis)
            
            return self.parseREER(data)
        }
    }
    
    /// Get major central bank rates
    func fetchMajorCentralBankRates() async -> [BISPolicyRate] {
        let majorBanks = [
            ("US", "United States", "Federal Reserve"),
            ("EA", "Euro Area", "ECB"),
            ("JP", "Japan", "Bank of Japan"),
            ("GB", "United Kingdom", "Bank of England"),
            ("CH", "Switzerland", "SNB"),
            ("AU", "Australia", "RBA"),
            ("CA", "Canada", "Bank of Canada"),
            ("SE", "Sweden", "Riksbank"),
            ("NO", "Norway", "Norges Bank"),
            ("NZ", "New Zealand", "RBNZ")
        ]
        
        do {
            let allRates = try await fetchPolicyRates()
            
            // Filter to major banks
            return allRates.filter { rate in
                majorBanks.contains { $0.0 == rate.countryCode }
            }.sorted { $0.rate > $1.rate }
        } catch {
            // Return static fallback data if API fails
            return majorBanks.map { bank in
                BISPolicyRate(
                    countryCode: bank.0,
                    countryName: bank.1,
                    rate: 0, // Unknown
                    rateChange: nil,
                    effectiveDate: Date(),
                    frequency: "unknown"
                )
            }
        }
    }
    
    /// Get summary statistics
    func fetchStats() async throws -> BISStats {
        let rates = try await fetchPolicyRates()
        let reer = try await fetchREER()
        
        let avgRate = rates.map { $0.rate }.reduce(0, +) / Double(rates.count)
        let negativeRateCountries = rates.filter { $0.rate < 0 }.count
        let hikingRates = rates.filter { ($0.rateChange ?? 0) > 0 }.count
        let cuttingRates = rates.filter { ($0.rateChange ?? 0) < 0 }.count
        
        let appreciating = reer.filter { $0.change12M > 5 }.count
        let depreciating = reer.filter { $0.change12M < -5 }.count
        
        return BISStats(
            countriesWithData: rates.count,
            averagePolicyRate: avgRate,
            negativeRateCountries: negativeRateCountries,
            countriesHikingRates: hikingRates,
            countriesCuttingRates: cuttingRates,
            appreciatingCurrencies: appreciating,
            depreciatingCurrencies: depreciating,
            lastUpdated: Date()
        )
    }
    
    // MARK: - Private Methods
    
    private func parsePolicyRates(_ data: Data) -> [BISPolicyRate] {
        // Simplified parsing - BIS uses SDMX format which is complex
        // This would need proper SDMX parsing in production
        
        // For now, return empty and implement proper parsing later
        return []
    }
    
    private func parseREER(_ data: Data) -> [BISREER] {
        // Simplified parsing
        return []
    }
}

// MARK: - Statistics Model

struct BISStats: Codable {
    let countriesWithData: Int
    let averagePolicyRate: Double
    let negativeRateCountries: Int
    let countriesHikingRates: Int
    let countriesCuttingRates: Int
    let appreciatingCurrencies: Int
    let depreciatingCurrencies: Int
    let lastUpdated: Date
}
