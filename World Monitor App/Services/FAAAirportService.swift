import Foundation

/// Service for FAA Airport Status data
actor FAAAirportService {
    static let shared = FAAAirportService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.faaAirport
    
    // Major airports to monitor
    private let majorAirports = [
        "ATL", "LAX", "ORD", "DFW", "DEN", "JFK", "SFO", "SEA", "LAS", "MCO",
        "EWR", "MIA", "CLT", "PHX", "IAH", "BOS", "MSP", "DTW", "FLL", "PHL",
        "LGA", "BWI", "SLC", "DCA", "SAN", "IAD", "TPA", "MDW", "HNL", "PDX"
    ]
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch all airport status
    func fetchAllAirportStatus() async throws -> [AirportDelay] {
        return try await cache.fetchWithCache(
            source: .faaAirport,
            maxAge: DataSource.faaAirport.defaultCacheTTL
        ) {
            let url = self.config.baseURL.appendingPathComponent("/airport-status")
            
            let data = try await self.httpClient.fetchData(url: url, source: .faaAirport)
            
            let delays = self.parseAirportData(data)
            
            // Sort by status severity
            return delays.sorted { a, b in
                let aScore = self.statusScore(a.status)
                let bScore = self.statusScore(b.status)
                return aScore > bScore || (aScore == bScore && (a.averageDelay ?? 0) > (b.averageDelay ?? 0))
            }
        }
    }
    
    /// Fetch status for major airports only
    func fetchMajorAirportStatus() async throws -> [AirportDelay] {
        let allAirports = try await fetchAllAirportStatus()
        return allAirports.filter { majorAirports.contains($0.iata) }
    }
    
    /// Get airport by IATA code
    func fetchAirportStatus(iata: String) async throws -> AirportDelay? {
        let allAirports = try await fetchAllAirportStatus()
        return allAirports.first { $0.iata.uppercased() == iata.uppercased() }
    }
    
    /// Get airports with delays
    func fetchDelayedAirports() async throws -> [AirportDelay] {
        let allAirports = try await fetchAllAirportStatus()
        return allAirports.filter { $0.hasSignificantDelay }
    }
    
    /// Get airports with ground stops
    func fetchGroundStops() async throws -> [AirportDelay] {
        let allAirports = try await fetchAllAirportStatus()
        return allAirports.filter { $0.groundStop || $0.status == .groundStop }
    }
    
    /// Get statistics
    func fetchStats() async throws -> AirportStats {
        let allAirports = try await fetchAllAirportStatus()
        
        let normal = allAirports.filter { $0.status == .normal }.count
        let delayed = allAirports.filter { $0.status == .delay }.count
        let groundStops = allAirports.filter { $0.status == .groundStop }.count
        let closed = allAirports.filter { $0.status == .closed }.count
        
        let worst = allAirports
            .filter { $0.status != .normal }
            .sorted {
                let aScore = self.statusScore($0.status) * 100 + Double($0.averageDelay ?? 0)
                let bScore = self.statusScore($1.status) * 100 + Double($1.averageDelay ?? 0)
                return aScore > bScore
            }
            .prefix(10)
            .map { $0 }
        
        return AirportStats(
            totalMonitored: allAirports.count,
            normalCount: normal,
            delayedCount: delayed,
            groundStopsCount: groundStops,
            closedCount: closed,
            worstAirports: Array(worst),
            lastUpdated: Date()
        )
    }
    
    /// Get average delay across all airports
    func fetchAverageDelay() async throws -> Double {
        let airports = try await fetchAllAirportStatus()
        let delays = airports.compactMap { $0.averageDelay }
        guard !delays.isEmpty else { return 0 }
        return Double(delays.reduce(0, +)) / Double(delays.count)
    }
    
    /// Search airports
    func searchAirports(query: String) async throws -> [AirportDelay] {
        let allAirports = try await fetchAllAirportStatus()
        let lowerQuery = query.lowercased()
        
        return allAirports.filter { airport in
            airport.iata.lowercased().contains(lowerQuery) ||
            airport.icao.lowercased().contains(lowerQuery) ||
            airport.name.lowercased().contains(lowerQuery) ||
            airport.city.lowercased().contains(lowerQuery)
        }
    }
    
    // MARK: - Private Methods
    
    private func parseAirportData(_ data: Data) -> [AirportDelay] {
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(FAAAirportResponse.self, from: data)
            
            return response.status.compactMap { status -> AirportDelay? in
                guard let iata = status.iata else { return nil }
                
                let airportStatus: AirportDelay.AirportStatus
                if status.groundDelay?.groundDelay == true {
                    airportStatus = .delay
                } else if status.groundStop?.groundStop == true {
                    airportStatus = .groundStop
                } else if (status.delayCount?.delayed ?? 0) > 0 {
                    airportStatus = .delay
                } else {
                    airportStatus = .normal
                }
                
                return AirportDelay(
                    iata: iata,
                    icao: status.icao ?? "",
                    name: status.name ?? iata,
                    city: status.city ?? "",
                    state: status.state,
                    country: "US",
                    status: airportStatus,
                    delayReason: status.groundDelay?.reason ?? status.groundStop?.reason,
                    averageDelay: status.groundDelay?.averageDelay ?? status.groundDelay?.maxDelay,
                    groundStop: status.groundStop?.groundStop == true,
                    groundStopEndTime: nil,
                    lastUpdated: Date()
                )
            }
        } catch {
            // Try alternative parsing
            return parseAlternativeFormat(data)
        }
    }
    
    private func parseAlternativeFormat(_ data: Data) -> [AirportDelay] {
        // Fallback parsing for different API versions
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let airports = json["airports"] as? [[String: Any]] {
                
                return airports.compactMap { airport -> AirportDelay? in
                    guard let iata = airport["iata"] as? String else { return nil }
                    
                    let statusString = airport["status"] as? String ?? "normal"
                    let status = AirportDelay.AirportStatus(rawValue: statusString.capitalized) ?? .normal
                    
                    return AirportDelay(
                        iata: iata,
                        icao: airport["icao"] as? String ?? "",
                        name: airport["name"] as? String ?? iata,
                        city: airport["city"] as? String ?? "",
                        state: airport["state"] as? String,
                        country: "US",
                        status: status,
                        delayReason: airport["delay_reason"] as? String,
                        averageDelay: airport["avg_delay"] as? Int,
                        groundStop: airport["ground_stop"] as? Bool ?? false,
                        groundStopEndTime: nil,
                        lastUpdated: Date()
                    )
                }
            }
        } catch {
            return []
        }
        
        return []
    }
    
    private func statusScore(_ status: AirportDelay.AirportStatus) -> Double {
        switch status {
        case .normal: return 0
        case .delay: return 1
        case .groundStop: return 2
        case .closed: return 3
        }
    }
}

// MARK: - FAA Response Models

struct FAAAirportResponse: Codable {
    let status: [FAAAirportStatus]
    let requestTime: String
}

struct FAAAirportStatus: Codable {
    let iata: String?
    let icao: String?
    let name: String?
    let city: String?
    let state: String?
    let delayCount: DelayCount?
    let groundDelay: GroundDelay?
    let groundStop: GroundStop?
    let closure: Closure?
    
    struct DelayCount: Codable {
        let delayed: Int
        let onTime: Int
    }
    
    struct GroundDelay: Codable {
        let groundDelay: Bool
        let averageDelay: Int?
        let maxDelay: Int?
        let reason: String?
    }
    
    struct GroundStop: Codable {
        let groundStop: Bool
        let reason: String?
        let endTime: String?
    }
    
    struct Closure: Codable {
        let closureBegin: String?
        let closureEnd: String?
        let reason: String?
    }
}
