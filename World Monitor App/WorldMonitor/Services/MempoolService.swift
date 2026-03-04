import Foundation

/// Service for Bitcoin network data from mempool.space
actor MempoolService {
    static let shared = MempoolService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.mempoolSpace
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch Bitcoin network stats
    func fetchNetworkStats() async throws -> BitcoinNetworkStats {
        return try await cache.fetchWithCache(
            source: .mempoolSpace,
            region: "stats",
            maxAge: DataSource.mempoolSpace.defaultCacheTTL
        ) {
            let url = config.baseURL.appendingPathComponent("/mempool")
            
            let data = try await httpClient.fetchData(url: url, source: .mempoolSpace)
            
            let decoder = JSONDecoder()
            let mempoolData = try decoder.decode(MempoolStatsResponse.self, from: data)
            
            return BitcoinNetworkStats(
                mempoolSize: mempoolData.vsize / 1_000_000, // Convert to MB
                unconfirmedTxs: mempoolData.count,
                avgFeeRate: mempoolData.feeHistogram.first?.avgFee ?? 0,
                avgBlockTime: 10.0 // Approximate
            )
        }
    }
}

// MARK: - Supporting Types

struct MempoolStatsResponse: Codable {
    let count: Int
    let vsize: Int // Virtual size in bytes
    let totalFee: Double
    let feeHistogram: [FeeHistogramEntry]
    
    struct FeeHistogramEntry: Codable {
        let feeRange: [Double]
        let avgFee: Double
        let count: Int
    }
}
