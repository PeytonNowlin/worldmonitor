import Foundation
import MapKit

/// Service for GPS/GNSS interference data from gpsjam.org
actor GPSJamService {
    static let shared = GPSJamService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.gpsJam
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch current GPS jamming data
    func fetchJammingData(region: GPSJamRegion? = nil) async throws -> [GPSJamHexCell] {
        return try await cache.fetchWithCache(
            source: .gpsJam,
            region: region?.rawValue,
            maxAge: DataSource.gpsJam.defaultCacheTTL
        ) {
            let url = self.config.baseURL.appendingPathComponent("/api/data.json")
            
            let data = try await self.httpClient.fetchData(url: url, source: .gpsJam)
            
            // Custom decoder with date parsing
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            
            let jamData = try decoder.decode(GPSJamData.self, from: data)
            
            // Filter significant cells
            var cells = jamData.hexCells.filter { $0.isSignificant }
            
            // Filter by region if specified
            if let region = region {
                cells = cells.filter { cell in
                    region.contains(latitude: cell.centerLatitude, longitude: cell.centerLongitude)
                }
            }
            
            return cells.sorted { $0.interferencePercent > $1.interferencePercent }
        }
    }
    
    /// Get high interference zones (>10% bad GPS)
    func fetchHighInterferenceZones() async throws -> [GPSJamHexCell] {
        let allCells = try await fetchJammingData()
        return allCells.filter { $0.interferenceLevel == .high }
    }
    
    /// Get statistics by region
    func fetchRegionalStats() async throws -> [GPSJamRegionStats] {
        let allCells = try await fetchJammingData()
        
        var stats: [GPSJamRegionStats] = []
        
        for region in GPSJamRegion.allCases {
            let regionCells = allCells.filter { cell in
                region.contains(latitude: cell.centerLatitude, longitude: cell.centerLongitude)
            }
            
            guard !regionCells.isEmpty else { continue }
            
            let totalAircraft = regionCells.reduce(0) { $0 + $1.aircraftCount }
            let badGpsAircraft = regionCells.reduce(0) { $0 + $1.aircraftWithBadGps }
            let avgInterference = regionCells.map { $0.interferencePercent }.reduce(0, +) / Double(regionCells.count)
            
            let highInterferenceCells = regionCells.filter { $0.interferenceLevel == .high }.count
            let mediumInterferenceCells = regionCells.filter { $0.interferenceLevel == .medium }.count
            
            stats.append(GPSJamRegionStats(
                region: region,
                totalCells: regionCells.count,
                highInterferenceCells: highInterferenceCells,
                mediumInterferenceCells: mediumInterferenceCells,
                totalAircraft: totalAircraft,
                aircraftWithBadGps: badGpsAircraft,
                averageInterferencePercent: avgInterference,
                mostAffectedLocation: regionCells.max { $0.interferencePercent < $1.interferencePercent }
            ))
        }
        
        return stats.sorted { $0.totalAffectedAircraft > $1.totalAffectedAircraft }
    }
    
    /// Get most affected areas (top N by interference percentage)
    func fetchMostAffectedAreas(limit: Int = 10) async throws -> [GPSJamHexCell] {
        let allCells = try await fetchJammingData()
        return Array(allCells.prefix(limit))
    }
    
    /// Check if a specific coordinate is in a jamming zone
    func isJammed(latitude: Double, longitude: Double) async throws -> Bool {
        let allCells = try await fetchJammingData()
        
        // Find if point is within any high or medium interference cell
        // H3 resolution 4 hexagons are roughly 100km across
        // We'll use a simple distance check (not perfect but sufficient)
        let thresholdKm = 50.0 // Half the cell size
        
        return allCells.contains { cell in
            guard cell.interferenceLevel != .low else { return false }
            
            let distance = haversineDistance(
                lat1: latitude, lon1: longitude,
                lat2: cell.centerLatitude, lon2: cell.centerLongitude
            )
            return distance <= thresholdKm
        }
    }
    
    /// Get interference level at a specific coordinate
    func getInterferenceAt(
        latitude: Double,
        longitude: Double
    ) async throws -> (level: GPSJamLevel, percent: Double)? {
        let allCells = try await fetchJammingData()
        
        let thresholdKm = 50.0
        
        // Find nearest significant cell
        if let nearestCell = allCells.min(by: {
            haversineDistance(lat1: latitude, lon1: longitude, lat2: $0.centerLatitude, lon2: $0.centerLongitude) <
            haversineDistance(lat1: latitude, lon1: longitude, lat2: $1.centerLatitude, lon2: $1.centerLongitude)
        }) {
            let distance = haversineDistance(
                lat1: latitude, lon1: longitude,
                lat2: nearestCell.centerLatitude, lon2: nearestCell.centerLongitude
            )
            
            if distance <= thresholdKm {
                return (nearestCell.interferenceLevel, nearestCell.interferencePercent)
            }
        }
        
        return nil
    }
    
    // MARK: - Private Methods
    
    private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0 // Earth's radius in km
        let dLat = (lat2 - lat1).radians
        let dLon = (lon2 - lon1).radians
        
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1.radians) * cos(lat2.radians) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        
        return R * c
    }
}

// MARK: - Statistics Models

struct GPSJamRegionStats: Identifiable {
    let region: GPSJamRegion
    let totalCells: Int
    let highInterferenceCells: Int
    let mediumInterferenceCells: Int
    let totalAircraft: Int
    let aircraftWithBadGps: Int
    let averageInterferencePercent: Double
    let mostAffectedLocation: GPSJamHexCell?
    
    var id: String { region.rawValue }
    
    var totalAffectedAircraft: Int {
        aircraftWithBadGps
    }
    
    var severityScore: Int {
        // Calculate severity score (1-10)
        let interferenceFactor = Int(averageInterferencePercent / 10)
        let aircraftFactor = min(5, aircraftWithBadGps / 100)
        let highCellFactor = min(3, highInterferenceCells)
        return min(10, 1 + interferenceFactor + aircraftFactor + highCellFactor)
    }
}

// MARK: - Helper Extensions

private extension Double {
    var radians: Double {
        self * .pi / 180
    }
}
