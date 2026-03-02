import Foundation
import MapKit

/// Service for UCDP (Uppsala Conflict Data Program) API
/// Provides state-based conflict data
actor UCDPService {
    static let shared = UCDPService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.ucdp
    
    // Track discovered API version
    private var discoveredVersion: String = "23.1"
    private var lastVersionCheck: Date?
    private let versionCacheTTL: TimeInterval = 3600 // 1 hour
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch active conflicts with automatic version discovery
    func fetchActiveConflicts(
        year: Int? = nil,
        region: RegionPreset? = nil
    ) async throws -> [UCDPConflictEvent] {
        // Discover API version if needed
        await discoverAPIVersionIfNeeded()
        
        return try await cache.fetchWithCache(
            source: .ucdp,
            region: region?.rawValue,
            maxAge: DataSource.ucdp.defaultCacheTTL
        ) {
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "pagesize", value: "500")
            ]
            
            // Filter by year or use current year
            let targetYear = year ?? Calendar.current.component(.year, from: Date())
            queryItems.append(URLQueryItem(name: "Year", value: "\(targetYear)"))
            
            // Build URL with discovered version
            let path = "/api/gedevents/\(self.discoveredVersion)"
            
            var components = URLComponents(
                url: self.config.baseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: true
            )
            components?.queryItems = queryItems
            
            guard let url = components?.url else {
                throw HTTPClientError.invalidURL
            }
            
            let response: UCDPResponse = try await self.httpClient.fetch(
                url: url,
                source: .ucdp,
                retries: self.config.retryPolicy.maxRetries
            )
            
            // Filter active conflicts (no end date or end date in future)
            return response.result.filter { $0.isActive }
        }
    }
    
    /// Fetch conflicts by specific country
    func fetchConflictsByCountry(
        countryCode: String,
        years: Int = 5
    ) async throws -> [UCDPConflictEvent] {
        await discoverAPIVersionIfNeeded()
        
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let startYear = currentYear - years
        
        var allConflicts: [UCDPConflictEvent] = []
        
        // Fetch for multiple years
        for year in startYear...currentYear {
            let yearConflicts = try await fetchActiveConflicts(year: year)
            let filtered = yearConflicts.filter {
                $0.location.contains(countryCode) ||
                $0.sideA.contains(countryCode) ||
                $0.sideB.contains(countryCode)
            }
            allConflicts.append(contentsOf: filtered)
        }
        
        // Deduplicate by conflict ID
        var seenIds = Set<String>()
        return allConflicts.filter { event in
            guard !seenIds.contains(event.id) else { return false }
            seenIds.insert(event.id)
            return true
        }
    }
    
    /// Get high-intensity conflict zones (wars)
    func fetchWarZones(region: RegionPreset? = nil) async throws -> [UCDPConflictEvent] {
        let conflicts = try await fetchActiveConflicts(region: region)
        return conflicts.filter { $0.conflictIntensity == .war }
    }
    
    /// Get conflict statistics summary
    func fetchConflictStats(region: RegionPreset? = nil) async throws -> UCDPStats {
        let conflicts = try await fetchActiveConflicts(region: region)
        
        let totalDeaths = conflicts.reduce(0) { $0 + $1.deaths }
        let totalCivilianDeaths = conflicts.reduce(0) { $0 + $1.deathsCivilians }
        let warCount = conflicts.filter { $0.conflictIntensity == .war }.count
        let minorConflictCount = conflicts.filter { $0.conflictIntensity == .minor }.count
        
        // Count by country
        var countryCounts: [String: Int] = [:]
        for conflict in conflicts {
            let countries = conflict.location.split(separator: ",")
            for country in countries {
                let trimmed = country.trimmingCharacters(in: .whitespaces)
                countryCounts[trimmed, default: 0] += conflict.deaths
            }
        }
        
        let topCountries = countryCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { (country: $0.key, deaths: $0.value) }
        
        return UCDPStats(
            totalActiveConflicts: conflicts.count,
            warCount: warCount,
            minorConflictCount: minorConflictCount,
            totalDeathsThisYear: totalDeaths,
            totalCivilianDeaths: totalCivilianDeaths,
            topAffectedCountries: topCountries,
            lastUpdated: Date()
        )
    }
    
    /// Check if a country has active conflict
    func hasActiveConflict(countryCode: String) async throws -> Bool {
        let conflicts = try await fetchActiveConflicts()
        return conflicts.contains { conflict in
            conflict.location.contains(countryCode)
        }
    }
    
    // MARK: - Private Methods
    
    private func discoverAPIVersionIfNeeded() async {
        // Check if we need to rediscover version
        if let lastCheck = lastVersionCheck,
           Date().timeIntervalSince(lastCheck) < versionCacheTTL {
            return // Version is fresh
        }
        
        // Try common versions in order
        let versionsToTry = ["23.1", "23.0", "22.1", "22.0", "21.1"]
        
        for version in versionsToTry {
            if await testVersion(version) {
                discoveredVersion = version
                lastVersionCheck = Date()
                return
            }
        }
        
        // Fall back to default if all fail
        discoveredVersion = "23.1"
        lastVersionCheck = Date()
    }
    
    private func testVersion(_ version: String) async -> Bool {
        let testURL = config.baseURL.appendingPathComponent("/api/gedevents/\(version)")
            .appending(queryItems: [
                URLQueryItem(name: "pagesize", value: "1"),
                URLQueryItem(name: "Year", value: "2024")
            ])
        
        do {
            let _: UCDPResponse = try await httpClient.fetch(
                url: testURL,
                source: .ucdp,
                retries: 1
            )
            return true
        } catch {
            return false
        }
    }
    
    private func filterByRegion(
        conflicts: [UCDPConflictEvent],
        region: RegionPreset
    ) -> [UCDPConflictEvent] {
        // Region-based filtering using approximate bounds
        switch region {
        case .global:
            return conflicts
        case .americas:
            return conflicts.filter {
                $0.longitude >= -170 && $0.longitude <= -30 &&
                $0.latitude >= -60 && $0.latitude <= 75
            }
        case .europe:
            return conflicts.filter {
                $0.longitude >= -25 && $0.longitude <= 45 &&
                $0.latitude >= 35 && $0.latitude <= 72
            }
        case .mena:
            return conflicts.filter {
                $0.longitude >= -20 && $0.longitude <= 65 &&
                $0.latitude >= 12 && $0.latitude <= 42
            }
        case .asia:
            return conflicts.filter {
                $0.longitude >= 45 && $0.longitude <= 180 &&
                $0.latitude >= -10 && $0.latitude <= 80
            }
        case .africa:
            return conflicts.filter {
                $0.longitude >= -25 && $0.longitude <= 55 &&
                $0.latitude >= -40 && $0.latitude <= 38
            }
        }
    }
}

// MARK: - Statistics Model

struct UCDPStats {
    let totalActiveConflicts: Int
    let warCount: Int
    let minorConflictCount: Int
    let totalDeathsThisYear: Int
    let totalCivilianDeaths: Int
    let topAffectedCountries: [(country: String, deaths: Int)]
    let lastUpdated: Date
}

// MARK: - Convenience Extensions

extension UCDPService {
    /// Convert UCDP events to FeedItems
    func convertToFeedItems(events: [UCDPConflictEvent]) -> [FeedItem] {
        events.map { event in
            let body = "\(event.sideA) vs \(event.sideB) - \(event.deaths) deaths"
            
            return FeedItem(
                id: "ucdp-\(event.id)",
                title: "\(event.conflictName)",
                body: body,
                severity: event.severity,
                source: "UCDP",
                publishedAt: event.startDate
            )
        }
    }
}
