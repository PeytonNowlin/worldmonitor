import Foundation
import MapKit
import SwiftUI

enum MonitorVariant: String, CaseIterable, Identifiable, Codable {
    case world
    case tech
    case finance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .world: "World"
        case .tech: "Tech"
        case .finance: "Finance"
        }
    }
}

enum RegionPreset: String, CaseIterable, Identifiable, Codable {
    case global
    case americas
    case europe
    case mena
    case asia
    case africa

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: "Global"
        case .americas: "Americas"
        case .europe: "Europe"
        case .mena: "MENA"
        case .asia: "Asia"
        case .africa: "Africa"
        }
    }

    var apiKey: String { rawValue }
}

enum TimeWindow: String, CaseIterable, Identifiable, Codable {
    case oneHour
    case sixHours
    case twentyFourHours
    case sevenDays
    case fourteenDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour: "1h"
        case .sixHours: "6h"
        case .twentyFourHours: "24h"
        case .sevenDays: "7d"
        case .fourteenDays: "14d"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .oneHour:
            60 * 60
        case .sixHours:
            6 * 60 * 60
        case .twentyFourHours:
            24 * 60 * 60
        case .sevenDays:
            7 * 24 * 60 * 60
        case .fourteenDays:
            14 * 24 * 60 * 60
        }
    }
}

enum MapLayer: String, CaseIterable, Identifiable, Codable {
    case conflictZones
    case maritimeTraffic
    case energyInfrastructure
    case financialMarketSignals
    case transportCorridors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conflictZones:
            "Conflict Zones"
        case .maritimeTraffic:
            "Maritime"
        case .energyInfrastructure:
            "Energy"
        case .financialMarketSignals:
            "Markets"
        case .transportCorridors:
            "Corridors"
        }
    }

    var tint: Color {
        switch self {
        case .conflictZones:
            .red
        case .maritimeTraffic:
            .blue
        case .energyInfrastructure:
            .orange
        case .financialMarketSignals:
            .green
        case .transportCorridors:
            .purple
        }
    }
}

struct LayerVisibilityState: Codable, Hashable {
    var activeLayers: Set<MapLayer> = Set(MapLayer.allCases)

    func isVisible(_ layer: MapLayer) -> Bool {
        activeLayers.contains(layer)
    }

    mutating func toggle(_ layer: MapLayer) {
        if activeLayers.contains(layer) {
            activeLayers.remove(layer)
        } else {
            activeLayers.insert(layer)
        }
    }

    mutating func enableAll() {
        activeLayers = Set(MapLayer.allCases)
    }

    mutating func disableAll() {
        activeLayers = []
    }
}

struct MonitoringSnapshot: Codable, Equatable {
    let headline: String
    let riskScore: Int
    let activeAlerts: Int
    let newAlerts: Int
    let chokepoints: Int
    let macroBias: String
    let trend: String
    let findings: [String]
    let lastRefreshed: Date

    static let empty = MonitoringSnapshot(
        headline: "Waiting for live signals",
        riskScore: 45,
        activeAlerts: 0,
        newAlerts: 0,
        chokepoints: 0,
        macroBias: "Neutral",
        trend: "Stable",
        findings: [],
        lastRefreshed: .now
    )
}

struct FeedItem: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let body: String
    let severity: Int
    let source: String
    let publishedAt: Date

    init(id: String = UUID().uuidString, title: String, body: String, severity: Int, source: String, publishedAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.severity = severity
        self.source = source
        self.publishedAt = publishedAt
    }
}

struct NaturalEvent: Identifiable, Hashable {
    enum Category: String, Hashable {
        case earthquakes
        case severeStorms
        case wildfires
        case volcanoes
        case floods
        case landslides
        case drought
        case manmade
    }

    let id: String
    let title: String
    let category: Category
    let latitude: Double
    let longitude: Double
    let severity: Int
    let source: String
    let occurredAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MilitaryFlightSignal: Identifiable, Hashable {
    let id: String
    let callsign: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let lastSeenAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MilitaryVesselSignal: Identifiable, Hashable {
    let id: String
    let name: String
    let region: String
    let latitude: Double
    let longitude: Double
    let vesselType: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MilitaryOverview: Hashable {
    let flights: [MilitaryFlightSignal]
    let vessels: [MilitaryVesselSignal]
    let basesInView: Int

    static let empty = MilitaryOverview(flights: [], vessels: [], basesInView: 0)
}
