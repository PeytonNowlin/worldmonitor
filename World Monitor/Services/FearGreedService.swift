import Foundation

/// Service for Fear & Greed Index from Alternative.me
actor FearGreedService {
    static let shared = FearGreedService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.fearGreed
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch current Fear & Greed Index
    func fetchCurrentIndex() async throws -> FearGreedIndex {
        return try await cache.fetchWithCache(
            source: .fearGreed,
            maxAge: DataSource.fearGreed.defaultCacheTTL
        ) {
            let url = self.config.baseURL.appendingPathComponent("/fng/")
            
            let data = try await self.httpClient.fetchData(url: url, source: .fearGreed)
            
            let decoder = JSONDecoder()
            let response = try decoder.decode(FearGreedResponse.self, from: data)
            
            guard let dataPoint = response.data.first else {
                throw HTTPClientError.decodingError("No data in response")
            }
            
            return FearGreedIndex(
                value: Int(dataPoint.value) ?? 0,
                valueClassification: dataPoint.valueClassification,
                timestamp: Date(timeIntervalSince1970: TimeInterval(dataPoint.timestamp) ?? 0),
                updateTimestamp: Date()
            )
        }
    }
    
    /// Fetch historical data
    func fetchHistory(limit: Int = 30) async throws -> [FearGreedDataPoint] {
        let url = config.baseURL.appendingPathComponent("/fng/?limit=\(limit)")
        
        let data = try await httpClient.fetchData(url: url, source: .fearGreed)
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(FearGreedResponse.self, from: data)
        
        return response.data
    }
    
    /// Get trend over time
    func fetchTrend(days: Int = 7) async throws -> FearGreedTrend {
        let history = try await fetchHistory(limit: days)
        
        guard history.count >= 2 else {
            return FearGreedTrend(direction: .neutral, change: 0, description: "Insufficient data")
        }
        
        let current = Int(history.first?.value ?? "50") ?? 50
        let previous = Int(history.last?.value ?? "50") ?? 50
        let change = current - previous
        
        let direction: FearGreedDirection
        if change > 10 {
            direction = .increasing
        } else if change < -10 {
            direction = .decreasing
        } else {
            direction = .neutral
        }
        
        let description: String
        switch direction {
        case .increasing:
            description = "Market sentiment improving (+\(change))"
        case .decreasing:
            description = "Market sentiment declining (\(change))"
        case .neutral:
            description = "Market sentiment stable"
        }
        
        return FearGreedTrend(direction: direction, change: change, description: description)
    }
    
    /// Get current classification
    func getCurrentClassification() async throws -> FearGreedClassification {
        let index = try await fetchCurrentIndex()
        return index.classification
    }
    
    /// Check if market is extreme (extreme fear or greed)
    func isExtreme() async throws -> (isExtreme: Bool, type: FearGreedClassification) {
        let classification = try await getCurrentClassification()
        return (classification == .extremeFear || classification == .extremeGreed, classification)
    }
}

// MARK: - Supporting Types

struct FearGreedResponse: Codable {
    let name: String
    let data: [FearGreedDataPoint]
}

struct FearGreedTrend: Codable {
    let direction: FearGreedDirection
    let change: Int
    let description: String
}

enum FearGreedDirection: String, Codable {
    case increasing
    case decreasing
    case neutral
}
