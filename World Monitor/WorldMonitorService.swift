import Foundation
import MapKit

struct FeedQuery {
    let variant: MonitorVariant
    let region: RegionPreset
    let window: TimeWindow
}

protocol WorldMonitorService {
    // MARK: - Core Dashboard Data
    func snapshot(for query: FeedQuery) async throws -> MonitoringSnapshot
    func headlines(for query: FeedQuery) async throws -> [FeedItem]
    func naturalEvents(for query: FeedQuery) async throws -> [NaturalEvent]
    func militaryOverview(for query: FeedQuery) async throws -> MilitaryOverview
    
    // MARK: - Conflict & Security
    func gdeltEvents(for query: FeedQuery) async throws -> [GDELTEvent]
    func ucdpConflicts(for query: FeedQuery) async throws -> [UCDPConflictEvent]
    
    // MARK: - Military Data
    func gpsJammingData(region: GPSJamRegion?) async throws -> [GPSJamHexCell]
    func militaryBases(for region: RegionPreset) async -> [MilitaryBase]
    
    // MARK: - Cyber Threat Intelligence
    func c2Servers() async throws -> [FeodoC2Server]
    func maliciousURLs() async throws -> [URLhausEntry]
    func c2Intel() async throws -> [C2IntelIOC]
    
    // MARK: - Market Data
    func marketQuotes(indices: [MarketIndex]) async throws -> [YahooQuote]
    func cryptoAssets(coins: [CryptoCoin]) async throws -> [CryptoAsset]
    func fearGreedIndex() async throws -> FearGreedIndex

    // MARK: - Infrastructure
    func internetConnectivity() async throws -> [CloudflareRadarData]
    func displacementData() async throws -> [DisplacementData]
    
    // MARK: - Travel & Safety
    func travelAdvisories() async throws -> [TravelAdvisory]
    func airportDelays() async throws -> [AirportDelay]
}

private actor NaturalEventCache {
    private var events: [NaturalEvent] = []
    private var refreshedAt: Date?

    func read(maxAge: TimeInterval) -> [NaturalEvent]? {
        guard let refreshedAt, Date().timeIntervalSince(refreshedAt) <= maxAge else {
            return nil
        }
        return events
    }

    func write(_ events: [NaturalEvent]) {
        self.events = events
        self.refreshedAt = .now
    }
}

private actor MilitaryOverviewCache {
    private var store: [String: (refreshedAt: Date, overview: MilitaryOverview)] = [:]

    func read(regionKey: String, maxAge: TimeInterval) -> MilitaryOverview? {
        guard let entry = store[regionKey], Date().timeIntervalSince(entry.refreshedAt) <= maxAge else {
            return nil
        }
        return entry.overview
    }

    func write(regionKey: String, overview: MilitaryOverview) {
        store[regionKey] = (Date(), overview)
    }
}

struct LiveWorldMonitorService: WorldMonitorService {
    static let shared = LiveWorldMonitorService()

    private static let eventCache = NaturalEventCache()
    private static let militaryCache = MilitaryOverviewCache()
    private let session: URLSession = .shared
    private let endpointBaseURL = URL(string: "https://worldmonitor.app")!

    func snapshot(for query: FeedQuery) async throws -> MonitoringSnapshot {
        let allEvents = try await loadAllEvents()
        let events = filteredEvents(for: query.region, in: allEvents)
        let now = Date()
        let windowStart = now.addingTimeInterval(-query.window.interval)
        let newEvents = events.filter { $0.occurredAt >= windowStart }
        let highSeverity = events.filter { $0.severity >= 4 }.count

        let riskScore = min(95, 25 + (highSeverity * 8) + (newEvents.count * 3))
        let headline = events.sorted { $0.severity == $1.severity ? $0.occurredAt > $1.occurredAt : $0.severity > $1.severity }.first?.title ?? "Waiting for live natural events"
        let trend: String
        switch newEvents.count {
        case 10...:
            trend = "Escalating"
        case 4...:
            trend = "Rising"
        case 1...:
            trend = "Stable"
        default:
            trend = "Cooling"
        }

        let categoryCounts = Dictionary(grouping: newEvents, by: \ .category).mapValues(\.count)
        let findings = categoryCounts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.value) \(friendlyCategoryName($0.key)) events in last \(query.window.title)" }

        return MonitoringSnapshot(
            headline: headline,
            riskScore: riskScore,
            activeAlerts: events.count,
            newAlerts: newEvents.count,
            chokepoints: highSeverity,
            macroBias: highSeverity > 8 ? "Elevated" : "Moderate",
            trend: trend,
            findings: findings.isEmpty ? ["No critical natural-event clusters in selected window"] : findings,
            lastRefreshed: now
        )
    }

    func headlines(for query: FeedQuery) async throws -> [FeedItem] {
        let events = filteredEvents(for: query.region, in: try await loadAllEvents())
            .sorted { $0.occurredAt > $1.occurredAt }

        return Array(events.prefix(12)).map { event in
            FeedItem(
                id: event.id,
                title: event.title,
                body: "\(friendlyCategoryName(event.category)) near \(String(format: "%.2f", event.latitude)), \(String(format: "%.2f", event.longitude)).",
                severity: event.severity,
                source: event.source,
                publishedAt: event.occurredAt
            )
        }
    }

    func naturalEvents(for query: FeedQuery) async throws -> [NaturalEvent] {
        filteredEvents(for: query.region, in: try await loadAllEvents())
    }

    func militaryOverview(for query: FeedQuery) async throws -> MilitaryOverview {
        if let cached = await Self.militaryCache.read(regionKey: query.region.rawValue, maxAge: 120) {
            return cached
        }

        let bounds = bounds(for: query.region)
        async let flightsTask: [MilitaryFlightSignal] = {
            (try? await fetchMilitaryFlights(bounds: bounds)) ?? []
        }()
        async let vesselsTask: [MilitaryVesselSignal] = {
            (try? await fetchUSNIVessels()) ?? []
        }()
        async let basesTask: Int = {
            (try? await fetchMilitaryBasesCount(bounds: bounds)) ?? 0
        }()

        let overview = MilitaryOverview(
            flights: await flightsTask,
            vessels: await vesselsTask,
            basesInView: await basesTask
        )

        if !overview.flights.isEmpty || !overview.vessels.isEmpty || overview.basesInView > 0 {
            await Self.militaryCache.write(regionKey: query.region.rawValue, overview: overview)
            return overview
        }

        if let stale = await Self.militaryCache.read(regionKey: query.region.rawValue, maxAge: .infinity) {
            return stale
        }

        return overview
    }

    private func loadAllEvents() async throws -> [NaturalEvent] {
        if let cached = await Self.eventCache.read(maxAge: 180) {
            return cached
        }

        async let usgsTask: [NaturalEvent] = {
            (try? await fetchUSGSEvents()) ?? []
        }()
        async let eonetTask: [NaturalEvent] = {
            (try? await fetchEONETEvents()) ?? []
        }()
        async let gdacsTask: [NaturalEvent] = {
            (try? await fetchGDACSEvents()) ?? []
        }()

        let merged = deduplicate(events: await (usgsTask + eonetTask + gdacsTask))
            .sorted { $0.occurredAt > $1.occurredAt }

        if !merged.isEmpty {
            await Self.eventCache.write(merged)
            return merged
        }

        if let stale = await Self.eventCache.read(maxAge: .infinity) {
            return stale
        }

        return []
    }

    private func filteredEvents(for region: RegionPreset, in events: [NaturalEvent]) -> [NaturalEvent] {
        guard region != .global else { return events }
        return events.filter { event in
            switch region {
            case .global:
                return true
            case .americas:
                return event.longitude >= -170 && event.longitude <= -30 && event.latitude >= -60 && event.latitude <= 75
            case .europe:
                return event.longitude >= -25 && event.longitude <= 45 && event.latitude >= 35 && event.latitude <= 72
            case .mena:
                return event.longitude >= -20 && event.longitude <= 65 && event.latitude >= 12 && event.latitude <= 42
            case .asia:
                return event.longitude >= 45 && event.longitude <= 180 && event.latitude >= -10 && event.latitude <= 80
            case .africa:
                return event.longitude >= -25 && event.longitude <= 55 && event.latitude >= -40 && event.latitude <= 38
            }
        }
    }

    private func deduplicate(events: [NaturalEvent]) -> [NaturalEvent] {
        var seen = Set<String>()
        var result: [NaturalEvent] = []

        for event in events {
            let key = "\(Int(event.latitude * 10))|\(Int(event.longitude * 10))|\(event.category.rawValue)"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(event)
            }
        }

        return result
    }

    private func friendlyCategoryName(_ category: NaturalEvent.Category) -> String {
        switch category {
        case .earthquakes:
            return "Earthquake"
        case .severeStorms:
            return "Storm"
        case .wildfires:
            return "Wildfire"
        case .volcanoes:
            return "Volcano"
        case .floods:
            return "Flood"
        case .landslides:
            return "Landslide"
        case .drought:
            return "Drought"
        case .manmade:
            return "Manmade"
        }
    }

    private func fetchUSGSEvents() async throws -> [NaturalEvent] {
        let url = URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_week.geojson")!
        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(USGSResponse.self, from: data)

        return decoded.features.compactMap { feature in
            guard feature.geometry.coordinates.count >= 2 else { return nil }
            guard let magnitude = feature.properties.mag, let occurredAtMs = feature.properties.time else { return nil }

            let longitude = feature.geometry.coordinates[0]
            let latitude = feature.geometry.coordinates[1]
            let severity: Int
            switch magnitude {
            case 6.5...:
                severity = 5
            case 5.5...:
                severity = 4
            case 5.0...:
                severity = 3
            default:
                severity = 2
            }

            return NaturalEvent(
                id: feature.id,
                title: "M\(String(format: "%.1f", magnitude)) Earthquake - \(feature.properties.place)",
                category: .earthquakes,
                latitude: latitude,
                longitude: longitude,
                severity: severity,
                source: "USGS",
                occurredAt: Date(timeIntervalSince1970: Double(occurredAtMs) / 1000)
            )
        }
    }

    private func fetchEONETEvents() async throws -> [NaturalEvent] {
        let url = URL(string: "https://eonet.gsfc.nasa.gov/api/v3/events?status=open&days=30")!
        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(EONETResponse.self, from: data)
        let now = Date()

        return decoded.events.compactMap { event in
            guard let category = event.categories.first else { return nil }
            guard category.id != "earthquakes" else { return nil }
            guard let latestGeometry = event.geometry.last else { return nil }
            guard latestGeometry.type == "Point", latestGeometry.coordinates.count >= 2 else { return nil }

            let occurredAt = ISO8601DateFormatter().date(from: latestGeometry.date) ?? now
            if category.id == "wildfires", now.timeIntervalSince(occurredAt) > 48 * 60 * 60 {
                return nil
            }

            let lon = latestGeometry.coordinates[0]
            let lat = latestGeometry.coordinates[1]
            return NaturalEvent(
                id: event.id,
                title: event.title,
                category: mapEONETCategory(category.id),
                latitude: lat,
                longitude: lon,
                severity: severityForEONETCategory(category.id),
                source: "NASA EONET",
                occurredAt: occurredAt
            )
        }
    }

    private func fetchGDACSEvents() async throws -> [NaturalEvent] {
        var request = URLRequest(url: URL(string: "https://www.gdacs.org/gdacsapi/api/events/geteventlist/MAP")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await session.data(for: request)
        let decoded = try JSONDecoder().decode(GDACSResponse.self, from: data)

        return decoded.features.compactMap { feature in
            guard feature.geometry.type == "Point", feature.geometry.coordinates.count >= 2 else { return nil }
            guard feature.properties.alertlevel != "Green" else { return nil }

            let lon = feature.geometry.coordinates[0]
            let lat = feature.geometry.coordinates[1]
            let occurredAt = ISO8601DateFormatter().date(from: feature.properties.fromdate) ?? .now

            let severity = feature.properties.alertlevel == "Red" ? 5 : 4

            return NaturalEvent(
                id: "gdacs-\(feature.properties.eventtype)-\(feature.properties.eventid)",
                title: feature.properties.name.isEmpty ? feature.properties.description : feature.properties.name,
                category: mapGDACSCategory(feature.properties.eventtype),
                latitude: lat,
                longitude: lon,
                severity: severity,
                source: "GDACS",
                occurredAt: occurredAt
            )
        }
    }

    private func mapEONETCategory(_ id: String) -> NaturalEvent.Category {
        switch id {
        case "severeStorms":
            return .severeStorms
        case "wildfires":
            return .wildfires
        case "volcanoes":
            return .volcanoes
        case "floods":
            return .floods
        case "landslides":
            return .landslides
        case "drought":
            return .drought
        default:
            return .manmade
        }
    }

    private func mapGDACSCategory(_ eventType: String) -> NaturalEvent.Category {
        switch eventType {
        case "EQ":
            return .earthquakes
        case "FL":
            return .floods
        case "TC":
            return .severeStorms
        case "VO":
            return .volcanoes
        case "WF":
            return .wildfires
        case "DR":
            return .drought
        default:
            return .manmade
        }
    }

    private func severityForEONETCategory(_ id: String) -> Int {
        switch id {
        case "wildfires", "severeStorms", "volcanoes":
            return 4
        case "floods", "landslides":
            return 3
        default:
            return 2
        }
    }

    private func bounds(for region: RegionPreset) -> RegionBounds {
        switch region {
        case .global:
            return RegionBounds(south: -60, north: 80, west: -170, east: 180)
        case .americas:
            return RegionBounds(south: -60, north: 75, west: -170, east: -30)
        case .europe:
            return RegionBounds(south: 35, north: 72, west: -25, east: 45)
        case .mena:
            return RegionBounds(south: 12, north: 42, west: -20, east: 65)
        case .asia:
            return RegionBounds(south: -10, north: 80, west: 45, east: 180)
        case .africa:
            return RegionBounds(south: -40, north: 38, west: -25, east: 55)
        }
    }

    private func fetchMilitaryFlights(bounds: RegionBounds) async throws -> [MilitaryFlightSignal] {
        do {
            let endpoint: MilitaryFlightsEndpointResponse = try await requestEndpointJSON(
                path: "/api/military/v1/list-military-flights",
                queryItems: [
                    URLQueryItem(name: "page_size", value: "300"),
                    URLQueryItem(name: "sw_lat", value: "\(bounds.south)"),
                    URLQueryItem(name: "sw_lon", value: "\(bounds.west)"),
                    URLQueryItem(name: "ne_lat", value: "\(bounds.north)"),
                    URLQueryItem(name: "ne_lon", value: "\(bounds.east)")
                ]
            )

            let mapped = endpoint.flights.compactMap { flight -> MilitaryFlightSignal? in
                guard let location = flight.location else { return nil }
                return MilitaryFlightSignal(
                    id: flight.id,
                    callsign: flight.callsign.trimmingCharacters(in: .whitespacesAndNewlines),
                    latitude: location.latitude,
                    longitude: location.longitude,
                    altitude: flight.altitude,
                    speed: flight.speed,
                    lastSeenAt: Date(timeIntervalSince1970: flight.lastSeenAt / 1000)
                )
            }
            if !mapped.isEmpty {
                return mapped
            }
        } catch {
            // fall through to direct OpenSky fetch
        }

        let query = [
            URLQueryItem(name: "lamin", value: "\(bounds.south)"),
            URLQueryItem(name: "lamax", value: "\(bounds.north)"),
            URLQueryItem(name: "lomin", value: "\(bounds.west)"),
            URLQueryItem(name: "lomax", value: "\(bounds.east)")
        ]
        let openSky: OpenSkyResponse = try await requestJSON(
            baseURL: URL(string: "https://opensky-network.org")!,
            path: "/api/states/all",
            queryItems: query
        )

        guard let states = openSky.states else { return [] }
        return states.compactMap { state in
            guard state.count > 10 else { return nil }
            let icao24 = state[0].stringValue ?? UUID().uuidString
            let rawCallsign = (state[1].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLikelyMilitary(callsign: rawCallsign, hex: icao24) else { return nil }
            guard let longitude = state[5].doubleValue, let latitude = state[6].doubleValue else { return nil }

            let altitude = state[7].doubleValue ?? 0
            let speed = state[9].doubleValue ?? 0
            return MilitaryFlightSignal(
                id: icao24,
                callsign: rawCallsign.isEmpty ? icao24.uppercased() : rawCallsign,
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                speed: speed,
                lastSeenAt: .now
            )
        }
    }

    private func fetchUSNIVessels() async throws -> [MilitaryVesselSignal] {
        do {
            let endpoint: USNIFleetEndpointResponse = try await requestEndpointJSON(
                path: "/api/military/v1/get-usni-fleet-report",
                queryItems: []
            )
            let mapped = endpoint.report?.vessels.compactMap { vessel -> MilitaryVesselSignal? in
                guard vessel.regionLat != 0 || vessel.regionLon != 0 else { return nil }
                return MilitaryVesselSignal(
                    id: "\(vessel.name)-\(vessel.hullNumber)-\(vessel.region)",
                    name: vessel.name,
                    region: vessel.region,
                    latitude: vessel.regionLat,
                    longitude: vessel.regionLon,
                    vesselType: vessel.vesselType
                )
            } ?? []
            if !mapped.isEmpty {
                return mapped
            }
        } catch {
            // fall through to direct USNI WordPress feed
        }

        let posts: [USNIPost] = try await requestJSON(
            baseURL: URL(string: "https://news.usni.org")!,
            path: "/wp-json/wp/v2/posts",
            queryItems: [
                URLQueryItem(name: "categories", value: "4137"),
                URLQueryItem(name: "per_page", value: "1")
            ]
        )
        guard let first = posts.first else { return [] }
        return parseUSNIVessels(from: first.content.rendered)
    }

    private func fetchMilitaryBasesCount(bounds: RegionBounds) async throws -> Int {
        do {
            let endpoint: MilitaryBasesEndpointResponse = try await requestEndpointJSON(
                path: "/api/military/v1/list-military-bases",
                queryItems: [
                    URLQueryItem(name: "zoom", value: "3"),
                    URLQueryItem(name: "sw_lat", value: "\(bounds.south)"),
                    URLQueryItem(name: "sw_lon", value: "\(bounds.west)"),
                    URLQueryItem(name: "ne_lat", value: "\(bounds.north)"),
                    URLQueryItem(name: "ne_lon", value: "\(bounds.east)")
                ]
            )
            return endpoint.totalInView
        } catch {
            return 0
        }
    }

    private func requestEndpointJSON<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        try await requestJSON(baseURL: endpointBaseURL, path: path, queryItems: queryItems)
    }

    private func requestJSON<T: Decodable>(baseURL: URL, path: String, queryItems: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("text/html") {
            throw URLError(.cannotDecodeContentData)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private func isLikelyMilitary(callsign: String, hex: String) -> Bool {
        let cleaned = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "RCH", "MC", "FORTE", "NATO", "DUKE", "GAF", "RAFAIR", "IAF", "QID", "CNV", "SPAR", "REACH", "PAT"
        ]
        if prefixes.contains(where: { cleaned.hasPrefix($0) }) {
            return true
        }
        if cleaned.range(of: #"[A-Z]{2,6}\d{2,4}"#, options: .regularExpression) != nil {
            return true
        }
        let hexPrefix = hex.uppercased().prefix(2)
        let likelyMilitaryHexPrefixes: Set<String> = ["AE", "AD", "4B", "3E", "43"]
        return likelyMilitaryHexPrefixes.contains(String(hexPrefix))
    }

    private func parseUSNIVessels(from html: String) -> [MilitaryVesselSignal] {
        let sections = html.components(separatedBy: "<h2")
        var vessels: [MilitaryVesselSignal] = []

        for section in sections.dropFirst() {
            guard let h2Start = section.range(of: ">"),
                  let h2End = section.range(of: "</h2>") else {
                continue
            }
            let regionTitle = String(section[h2Start.upperBound..<h2End.lowerBound])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let coordinate = resolveUSNIRegionCoordinate(for: regionTitle) else { continue }

            let content = String(section[h2End.upperBound...])
            let regexes = [
                try? NSRegularExpression(pattern: #"USS\s+<(?:em|i)>([^<]+)</(?:em|i)>\s+\(([^)]+)\)"#, options: [.caseInsensitive]),
                try? NSRegularExpression(pattern: #"USS\s+([A-Za-z0-9\-\s]+)\s+\(([^)]+)\)"#, options: [.caseInsensitive])
            ]
            let matches = regexes.compactMap { $0 }.flatMap { regex in
                regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            }

            for match in matches {
                guard match.numberOfRanges >= 3,
                      let nameRange = Range(match.range(at: 1), in: content),
                      let hullRange = Range(match.range(at: 2), in: content) else {
                    continue
                }

                let name = String(content[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let hull = String(content[hullRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                vessels.append(
                    MilitaryVesselSignal(
                        id: "\(regionTitle)-\(hull)",
                        name: "USS \(name)",
                        region: regionTitle,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        vesselType: vesselType(fromHull: hull)
                    )
                )
            }
        }
        return vessels
    }

    private func resolveUSNIRegionCoordinate(for rawRegion: String) -> CLLocationCoordinate2D? {
        let normalized = rawRegion
            .replacingOccurrences(of: #"^(In the|In|The)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let exact = usniRegionCoordinates[normalized] {
            return exact
        }
        let lowered = normalized.lowercased()
        for (key, value) in usniRegionCoordinates {
            let keyLowered = key.lowercased()
            if lowered == keyLowered || lowered.contains(keyLowered) || keyLowered.contains(lowered) {
                return value
            }
        }
        return nil
    }

    private func vesselType(fromHull hull: String) -> String {
        if hull.hasPrefix("CVN") || hull.hasPrefix("CV") {
            return "carrier"
        }
        if hull.hasPrefix("DDG") || hull.hasPrefix("CG") {
            return "destroyer"
        }
        if hull.hasPrefix("SSN") || hull.hasPrefix("SSBN") || hull.hasPrefix("SSGN") {
            return "submarine"
        }
        if hull.hasPrefix("LHD") || hull.hasPrefix("LHA") || hull.hasPrefix("LPD") {
            return "amphibious"
        }
        return "vessel"
    }
    
    // MARK: - WorldMonitorService Protocol Extensions (New Endpoints)
    
    func gdeltEvents(for query: FeedQuery) async throws -> [GDELTEvent] {
        return try await GDELTService.shared.fetchRecentSignificantEvents(
            days: Int(query.window.interval / 86400),
            region: query.region == .global ? nil : query.region
        )
    }
    
    func ucdpConflicts(for query: FeedQuery) async throws -> [UCDPConflictEvent] {
        return try await UCDPService.shared.fetchActiveConflicts(
            region: query.region == .global ? nil : query.region
        )
    }
    
    func gpsJammingData(region: GPSJamRegion?) async throws -> [GPSJamHexCell] {
        return try await GPSJamService.shared.fetchJammingData(region: region)
    }
    
    func militaryBases(for region: RegionPreset) async -> [MilitaryBase] {
        return await MilitaryBasesService.shared.fetchBasesInRegion(region)
    }
    
    func c2Servers() async throws -> [FeodoC2Server] {
        return try await FeodoTrackerService.shared.fetchC2Servers(minSeverity: .medium)
    }
    
    func maliciousURLs() async throws -> [URLhausEntry] {
        return try await URLhausService.shared.fetchActiveURLs(limit: 100)
    }
    
    func c2Intel() async throws -> [C2IntelIOC] {
        return try await C2IntelService.shared.fetchHighConfidenceIOC()
    }
    
    func marketQuotes(indices: [MarketIndex]) async throws -> [YahooQuote] {
        return try await YahooFinanceService.shared.fetchQuotes(symbols: indices.map { $0.rawValue })
    }
    
    func cryptoAssets(coins: [CryptoCoin]) async throws -> [CryptoAsset] {
        return try await CoinGeckoService.shared.fetchMarketData(coins: coins)
    }
    
    func fearGreedIndex() async throws -> FearGreedIndex {
        return try await FearGreedService.shared.fetchCurrentIndex()
    }

    func internetConnectivity() async throws -> [CloudflareRadarData] {
        return try await CloudflareRadarService.shared.fetchConnectivityData()
    }
    
    func displacementData() async throws -> [DisplacementData] {
        return try await HAPIService.shared.fetchDisplacementByOrigin()
    }
    
    func travelAdvisories() async throws -> [TravelAdvisory] {
        return try await TravelAdvisoryService.shared.fetchAllAdvisories()
    }
    
    func airportDelays() async throws -> [AirportDelay] {
        return try await FAAAirportService.shared.fetchMajorAirportStatus()
    }
}

private struct USGSResponse: Decodable {
    let features: [USGSFeature]
}

private struct USGSFeature: Decodable {
    let id: String
    let properties: USGSProperties
    let geometry: USGSGeometry
}

private struct USGSProperties: Decodable {
    let mag: Double?
    let place: String
    let time: Int64?
    let url: String
}

private struct USGSGeometry: Decodable {
    let coordinates: [Double]
}

private struct EONETResponse: Decodable {
    let events: [EONETEvent]
}

private struct EONETEvent: Decodable {
    let id: String
    let title: String
    let categories: [EONETCategory]
    let geometry: [EONETGeometry]
}

private struct EONETCategory: Decodable {
    let id: String
}

private struct EONETGeometry: Decodable {
    let date: String
    let type: String
    let coordinates: [Double]
}

private struct GDACSResponse: Decodable {
    let features: [GDACSFeature]
}

private struct GDACSFeature: Decodable {
    let geometry: GDACSGeometry
    let properties: GDACSProperties
}

private struct GDACSGeometry: Decodable {
    let type: String
    let coordinates: [Double]
}

private struct GDACSProperties: Decodable {
    let eventtype: String
    let eventid: Int
    let name: String
    let description: String
    let alertlevel: String
    let fromdate: String
}

private struct RegionBounds {
    let south: Double
    let north: Double
    let west: Double
    let east: Double
}

private struct MilitaryFlightsEndpointResponse: Decodable {
    let flights: [MilitaryFlightDTO]
}

private struct MilitaryFlightDTO: Decodable {
    let id: String
    let callsign: String
    let location: GeoCoordinatesDTO?
    let altitude: Double
    let speed: Double
    let lastSeenAt: Double
}

private struct GeoCoordinatesDTO: Decodable {
    let latitude: Double
    let longitude: Double
}

private struct OpenSkyResponse: Decodable {
    let states: [[OpenSkyStateValue]]?
}

private enum OpenSkyStateValue: Decodable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .boolean(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .null
        }
    }
}

private extension OpenSkyStateValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .number(value):
            return value
        case let .string(value):
            return Double(value)
        default:
            return nil
        }
    }
}

private struct USNIFleetEndpointResponse: Decodable {
    let report: USNIFleetReportDTO?
}

private struct USNIFleetReportDTO: Decodable {
    let vessels: [USNIVesselDTO]
}

private struct USNIVesselDTO: Decodable {
    let name: String
    let hullNumber: String
    let vesselType: String
    let region: String
    let regionLat: Double
    let regionLon: Double
}

private struct MilitaryBasesEndpointResponse: Decodable {
    let totalInView: Int
}

private struct USNIPost: Decodable {
    let content: USNIPostContent
}

private struct USNIPostContent: Decodable {
    let rendered: String
}

private let usniRegionCoordinates: [String: CLLocationCoordinate2D] = [
    "Philippine Sea": CLLocationCoordinate2D(latitude: 18.0, longitude: 130.0),
    "South China Sea": CLLocationCoordinate2D(latitude: 14.0, longitude: 115.0),
    "East China Sea": CLLocationCoordinate2D(latitude: 28.0, longitude: 125.0),
    "Sea of Japan": CLLocationCoordinate2D(latitude: 40.0, longitude: 135.0),
    "Arabian Sea": CLLocationCoordinate2D(latitude: 18.0, longitude: 63.0),
    "Red Sea": CLLocationCoordinate2D(latitude: 20.0, longitude: 38.0),
    "Mediterranean Sea": CLLocationCoordinate2D(latitude: 35.0, longitude: 18.0),
    "Persian Gulf": CLLocationCoordinate2D(latitude: 26.5, longitude: 52.0),
    "Caribbean Sea": CLLocationCoordinate2D(latitude: 15.0, longitude: -73.0),
    "North Atlantic": CLLocationCoordinate2D(latitude: 45.0, longitude: -30.0),
    "Pacific Ocean": CLLocationCoordinate2D(latitude: 20.0, longitude: -150.0),
    "Western Pacific": CLLocationCoordinate2D(latitude: 20.0, longitude: 140.0),
    "Eastern Mediterranean": CLLocationCoordinate2D(latitude: 34.5, longitude: 33.0),
    "Western Mediterranean": CLLocationCoordinate2D(latitude: 37.0, longitude: 3.0),
    "Gulf of Oman": CLLocationCoordinate2D(latitude: 24.5, longitude: 58.5),
    "Gulf of Aden": CLLocationCoordinate2D(latitude: 12.0, longitude: 47.0),
    "Arabian Gulf": CLLocationCoordinate2D(latitude: 26.5, longitude: 52.0),
    "Indian Ocean": CLLocationCoordinate2D(latitude: -5.0, longitude: 75.0),
    "Bahrain": CLLocationCoordinate2D(latitude: 26.23, longitude: 50.55),
    "Yokosuka": CLLocationCoordinate2D(latitude: 35.29, longitude: 139.67),
    "Norfolk": CLLocationCoordinate2D(latitude: 36.95, longitude: -76.30),
    "San Diego": CLLocationCoordinate2D(latitude: 32.68, longitude: -117.15)
]
