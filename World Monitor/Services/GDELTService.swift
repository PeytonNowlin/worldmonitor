import Foundation
import MapKit

/// Service for fetching data from GDELT (Global Database of Events, Language, and Tone)
actor GDELTService {
    static let shared = GDELTService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.gdelt
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch events from GDELT GeoJSON API
    func fetchEvents(
        query: GDELTQuery = GDELTQuery(),
        region: String? = nil
    ) async throws -> [GDELTEvent] {
        return try await cache.fetchWithCache(
            source: .gdelt,
            region: region,
            maxAge: DataSource.gdelt.defaultCacheTTL
        ) {
            // Build URL
            var components = URLComponents(
                url: self.config.baseURL.appendingPathComponent("/api/v2/geo/geo"),
                resolvingAgainstBaseURL: true
            )
            components?.queryItems = query.queryItems
            
            guard let url = components?.url else {
                throw HTTPClientError.invalidURL
            }
            
            // Fetch and decode
            let response: GDELTGeoJSONResponse = try await self.httpClient.fetch(
                url: url,
                source: .gdelt,
                retries: self.config.retryPolicy.maxRetries
            )
            
            return response.features.map { $0.properties }
        }
    }
    
    /// Fetch recent events (last 7 days) with high mention count
    func fetchRecentSignificantEvents(
        days: Int = 7,
        minMentions: Int = 5,
        region: RegionPreset? = nil
    ) async throws -> [GDELTEvent] {
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: endDate)!
        
        var query = GDELTQuery()
        query.startDate = startDate
        query.endDate = endDate
        query.maxRecords = 500
        
        // Add location filter if region specified
        if let region = region, let bounds = boundsForRegion(region) {
            query.location = GDELTQuery.GDELTLocationFilter(
                nearLatitude: bounds.center.latitude,
                nearLongitude: bounds.center.longitude,
                radiusKm: bounds.radiusKm
            )
        }
        
        let events = try await fetchEvents(query: query, region: region?.rawValue)
        
        // Filter by mention count and deduplicate
        return events
            .filter { $0.numMentions >= minMentions }
            .sorted { $0.severity > $1.severity }
    }
    
    /// Fetch conflict-related events (protests, fights, assaults)
    func fetchConflictEvents(
        days: Int = 3,
        region: RegionPreset? = nil
    ) async throws -> [GDELTEvent] {
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: endDate)!
        
        var query = GDELTQuery()
        query.startDate = startDate
        query.endDate = endDate
        query.maxRecords = 250
        
        if let region = region, let bounds = boundsForRegion(region) {
            query.location = GDELTQuery.GDELTLocationFilter(
                nearLatitude: bounds.center.latitude,
                nearLongitude: bounds.center.longitude,
                radiusKm: bounds.radiusKm
            )
        }
        
        let allEvents = try await fetchEvents(query: query, region: region?.rawValue)
        
        // Filter to conflict codes (14-20 are protest/conflict/violence)
        let conflictCodes = ["14", "15", "16", "17", "18", "19", "20"]
        return allEvents.filter { event in
            conflictCodes.contains(event.eventType)
        }
    }
    
    /// Fetch GKG (Global Knowledge Graph) articles
    func fetchGKGArticles(
        themes: [String]? = nil,
        days: Int = 1,
        region: RegionPreset? = nil
    ) async throws -> [GDELTGKGArticle] {
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: endDate)!
        
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "QUERY", value: themes?.joined(separator: ";") ?? ""),
            URLQueryItem(name: "STARTDATETIME", value: formatDate(startDate)),
            URLQueryItem(name: "ENDDATETIME", value: formatDate(endDate)),
            URLQueryItem(name: "MAXROWS", value: "250"),
            URLQueryItem(name: "FORMAT", value: "JSON")
        ]
        
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("/api/v1/gkg/gkg"),
            resolvingAgainstBaseURL: true
        )
        components?.queryItems = queryItems
        
        guard let url = components?.url else {
            throw HTTPClientError.invalidURL
        }
        
        // Note: GKG API returns CSV-like data, this is a simplified version
        // In production, you'd need a CSV parser for the actual GKG response
        let data = try await httpClient.fetchData(url: url, source: .gdelt)
        
        // Parse the response (GKG returns tabular data, not JSON)
        // This is a placeholder - real implementation would parse the actual format
        return []
    }
    
    /// Get trending themes from recent events
    func fetchTrendingThemes(days: Int = 2) async throws -> [(theme: String, count: Int)] {
        let events = try await fetchRecentSignificantEvents(days: days, minMentions: 1)
        
        // Extract and count themes (simplified - would need GKG for real themes)
        var themeCounts: [String: Int] = [:]
        
        for event in events {
            if let rootCode = GDELTRootCode(rawValue: event.eventType) {
                themeCounts[rootCode.displayName, default: 0] += event.numMentions
            }
        }
        
        return themeCounts
            .map { (theme: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
    
    // MARK: - Private Methods
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
    
    private func boundsForRegion(_ region: RegionPreset) -> (center: CLLocationCoordinate2D, radiusKm: Double)? {
        switch region {
        case .global:
            return nil
        case .americas:
            return (CLLocationCoordinate2D(latitude: 15, longitude: -100), 5000)
        case .europe:
            return (CLLocationCoordinate2D(latitude: 50, longitude: 10), 2000)
        case .mena:
            return (CLLocationCoordinate2D(latitude: 25, longitude: 45), 2500)
        case .asia:
            return (CLLocationCoordinate2D(latitude: 35, longitude: 100), 4000)
        case .africa:
            return (CLLocationCoordinate2D(latitude: 0, longitude: 20), 4000)
        }
    }
}

// MARK: - Convenience Extensions

extension GDELTService {
    /// Convert GDELT events to FeedItems for display
    func convertToFeedItems(events: [GDELTEvent]) -> [FeedItem] {
        events.map { event in
            let body: String
            if !event.actor1.isEmpty && !event.actor2.isEmpty {
                body = "\(event.actor1) - \(event.actor2)"
            } else if !event.actor1.isEmpty {
                body = event.actor1
            } else {
                body = "GDELT Event"
            }
            
            return FeedItem(
                id: event.id,
                title: event.title,
                body: body,
                severity: event.severity,
                source: "GDELT",
                publishedAt: event.eventDate
            )
        }
    }
}
