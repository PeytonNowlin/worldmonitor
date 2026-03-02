import Foundation

/// Service for Bitcoin network data from mempool.space
actor MempoolService {
    static let shared = MempoolService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.mempoolSpace
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch Bitcoin hashrate data
    func fetchHashrate(timeRange: String = "3d") async throws -> BitcoinHashrate {
        return try await cache.fetchWithCache(
            source: .mempoolSpace,
            region: "hashrate",
            maxAge: DataSource.mempoolSpace.defaultCacheTTL
        ) {
            let url = self.config.baseURL.appendingPathComponent("/mining/hashrate/\(timeRange)")
            
            let data = try await self.httpClient.fetchData(url: url, source: .mempoolSpace)
            
            let decoder = JSONDecoder()
            let response = try decoder.decode(MempoolHashrateResponse.self, from: data)
            
            return BitcoinHashrate(
                currentHashrate: response.currentHashrate / 1e18, // Convert to EH/s
                currentDifficulty: Double(response.currentDifficulty),
                difficultyChange: response.difficultyChange,
                difficultyEpoch: response.difficultyEpoch,
                remainingBlocksToDifficultyAdjustment: response.remainingBlocks,
                estimatedDifficultyChange: response.estimatedDifficultyChange,
                timestamp: Date()
            )
        }
    }
    
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
            
            // Fetch hashrate for complete stats
            let hashrateData = try? await fetchHashrate()
            
            return BitcoinNetworkStats(
                hashrate: hashrateData?.currentHashrate ?? 0,
                difficulty: hashrateData?.currentDifficulty ?? 0,
                mempoolSize: mempoolData.vsize / 1_000_000, // Convert to MB
                unconfirmedTxs: mempoolData.count,
                avgFeeRate: mempoolData.feeHistogram.first?.avgFee ?? 0,
                avgBlockTime: 10.0 // Approximate
            )
        }
    }
    
    /// Fetch difficulty adjustment estimate
    func fetchDifficultyEstimate() async throws -> DifficultyEstimate {
        let hashrate = try await fetchHashrate()
        
        return DifficultyEstimate(
            currentDifficulty: hashrate.currentDifficulty,
            estimatedDifficulty: hashrate.currentDifficulty * (1 + hashrate.estimatedDifficultyChange / 100),
            changePercent: hashrate.estimatedDifficultyChange,
            blocksRemaining: hashrate.remainingBlocksToDifficultyAdjustment,
            estimatedDate: Date().addingTimeInterval(Double(hashrate.remainingBlocksToDifficultyAdjustment) * 10 * 60)
        )
    }
    
    /// Get hashrate trend (30-day change)
    func fetchHashrateTrend() async throws -> HashrateTrend {
        let hashrate3d = try await fetchHashrate(timeRange: "3d")
        let hashrate1m = try await fetchHashrate(timeRange: "1m")
        
        let change = ((hashrate3d.currentHashrate - hashrate1m.currentHashrate) / hashrate1m.currentHashrate) * 100
        
        let trend: HashrateTrendDirection
        if change > 10 {
            trend = .increasing
        } else if change < -10 {
            trend = .decreasing
        } else {
            trend = .stable
        }
        
        return HashrateTrend(
            currentHashrate: hashrate3d.currentHashrate,
            changePercent30d: change,
            direction: trend
        )
    }
}

// MARK: - Supporting Types

struct MempoolHashrateResponse: Codable {
    let currentHashrate: Double // In H/s
    let currentDifficulty: Int
    let difficultyChange: Double
    let difficultyEpoch: Int
    let remainingBlocks: Int
    let estimatedDifficultyChange: Double
    
    enum CodingKeys: String, CodingKey {
        case currentHashrate = "currentHashrate"
        case currentDifficulty = "currentDifficulty"
        case difficultyChange = "difficultyChange"
        case difficultyEpoch = "difficultyEpoch"
        case remainingBlocks = "remainingBlocks"
        case estimatedDifficultyChange = "estimatedDifficultyChange"
    }
}

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

struct DifficultyEstimate: Codable {
    let currentDifficulty: Double
    let estimatedDifficulty: Double
    let changePercent: Double
    let blocksRemaining: Int
    let estimatedDate: Date
}

struct HashrateTrend: Codable {
    let currentHashrate: Double // EH/s
    let changePercent30d: Double
    let direction: HashrateTrendDirection
}

enum HashrateTrendDirection: String, Codable {
    case increasing
    case decreasing
    case stable
}
