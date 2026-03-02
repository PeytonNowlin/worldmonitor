import Foundation

struct FeedQuery {
    let variant: MonitorVariant
    let region: RegionPreset
    let window: TimeWindow
}

protocol WorldMonitorService {
    func snapshot(for query: FeedQuery) async throws -> MonitoringSnapshot
    func headlines(for query: FeedQuery) async throws -> [FeedItem]
    func naturalEvents(for query: FeedQuery) async throws -> [NaturalEvent]
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

struct LiveWorldMonitorService: WorldMonitorService {
    static let shared = LiveWorldMonitorService()

    private static let eventCache = NaturalEventCache()
    private let session: URLSession = .shared

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

    private func loadAllEvents() async throws -> [NaturalEvent] {
        if let cached = await Self.eventCache.read(maxAge: 180) {
            return cached
        }

        async let usgs = fetchUSGSEvents()
        async let eonet = fetchEONETEvents()
        async let gdacs = fetchGDACSEvents()

        let merged = deduplicate(events: try await (usgs + eonet + gdacs))
            .sorted { $0.occurredAt > $1.occurredAt }

        await Self.eventCache.write(merged)
        return merged
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
