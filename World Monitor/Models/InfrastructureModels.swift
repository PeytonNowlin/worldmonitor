import Foundation

// MARK: - Cloudflare Radar Models

/// Internet connectivity data from Cloudflare Radar
struct CloudflareRadarData: Identifiable, Codable {
    let id: String
    let countryCode: String
    let countryName: String
    let connectivityScore: Double // 0-100
    let httpRequests: Int64
    let timestamp: Date
    let change1h: Double?
    let change24h: Double?
    
    var status: ConnectivityStatus {
        if connectivityScore > 90 {
            return .normal
        } else if connectivityScore > 70 {
            return .degraded
        } else {
            return .severe
        }
    }
    
    enum ConnectivityStatus: String {
        case normal = "Normal"
        case degraded = "Degraded"
        case severe = "Severe"
        
        var color: String {
            switch self {
            case .normal: return "green"
            case .degraded: return "yellow"
            case .severe: return "red"
            }
        }
    }
}

struct CloudflareOutageEvent: Identifiable, Codable {
    let id: String
    let countryCode: String
    let countryName: String
    let startTime: Date
    let endTime: Date?
    let severity: OutageSeverity
    let description: String?
    
    var isOngoing: Bool {
        endTime == nil
    }
    
    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }
    
    enum OutageSeverity: String, Codable {
        case minor = "Minor"
        case moderate = "Moderate"
        case major = "Major"
        case critical = "Critical"
    }
}

// MARK: - UN OCHA HAPI Models

/// Displacement data from UN OCHA HAPI
struct DisplacementData: Identifiable, Codable {
    let id: String
    let countryCode: String
    let countryName: String
    let refugees: Int
    let idps: Int // Internally Displaced Persons
    let asylumSeekers: Int
    let returnedRefugees: Int
    let returnedIDPs: Int
    let statelessPersons: Int
    let otherOfConcern: Int
    let dataDate: Date
    let source: String
    
    var totalDisplaced: Int {
        refugees + idps + asylumSeekers
    }
    
    var severity: DisplacementSeverity {
        let total = totalDisplaced
        if total > 5_000_000 {
            return .extreme
        } else if total > 1_000_000 {
            return .severe
        } else if total > 100_000 {
            return .high
        } else if total > 10_000 {
            return .moderate
        } else {
            return .low
        }
    }
    
    enum DisplacementSeverity: String {
        case extreme = "Extreme"
        case severe = "Severe"
        case high = "High"
        case moderate = "Moderate"
        case low = "Low"
    }
}

struct DisplacementStats {
    let totalRefugees: Int
    let totalIDPs: Int
    let topOriginCountries: [(country: String, count: Int)]
    let topHostCountries: [(country: String, count: Int)]
    let lastUpdated: Date
    
    var grandTotal: Int {
        totalRefugees + totalIDPs
    }
}

// MARK: - Travel & Safety Models

/// US State Department travel advisory
struct TravelAdvisory: Identifiable, Codable {
    let countryName: String
    let countryCode: String
    let advisoryLevel: AdvisoryLevel
    let advisoryText: String
    let lastUpdated: Date
    let specificWarnings: [String]
    let restrictedAreas: [String]?
    
    var id: String { countryCode }
    
    enum AdvisoryLevel: Int, Codable, Comparable {
        case level1 = 1 // Exercise Normal Precautions
        case level2 = 2 // Exercise Increased Caution
        case level3 = 3 // Reconsider Travel
        case level4 = 4 // Do Not Travel
        
        var description: String {
            switch self {
            case .level1: return "Exercise Normal Precautions"
            case .level2: return "Exercise Increased Caution"
            case .level3: return "Reconsider Travel"
            case .level4: return "Do Not Travel"
            }
        }
        
        var color: String {
            switch self {
            case .level1: return "blue"
            case .level2: return "yellow"
            case .level3: return "orange"
            case .level4: return "red"
            }
        }
        
        var isRisky: Bool {
            self >= .level3
        }
        
        static func < (lhs: AdvisoryLevel, rhs: AdvisoryLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}

struct AdvisoryStats {
    let totalCountries: Int
    let level1Count: Int
    let level2Count: Int
    let level3Count: Int
    let level4Count: Int
    let highRiskCountries: [TravelAdvisory]
    let lastUpdated: Date
}

/// FAA Airport status/delay
struct AirportDelay: Identifiable, Codable {
    let iata: String
    let icao: String
    let name: String
    let city: String
    let state: String?
    let country: String
    let status: AirportStatus
    let delayReason: String?
    let averageDelay: Int? // minutes
    let groundStop: Bool
    let groundStopEndTime: Date?
    let lastUpdated: Date
    
    var id: String { iata }
    
    enum AirportStatus: String, Codable {
        case normal = "Normal"
        case delay = "Delay"
        case groundStop = "Ground Stop"
        case closed = "Closed"
        
        var color: String {
            switch self {
            case .normal: return "green"
            case .delay: return "yellow"
            case .groundStop: return "orange"
            case .closed: return "red"
            }
        }
    }
    
    var hasSignificantDelay: Bool {
        status != .normal || (averageDelay ?? 0) > 30
    }
}

struct AirportStats {
    let totalMonitored: Int
    let normalCount: Int
    let delayedCount: Int
    let groundStopsCount: Int
    let closedCount: Int
    let worstAirports: [AirportDelay]
    let lastUpdated: Date
}

// MARK: - Geographic Helpers

struct GeoBounds {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
    
    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= minLat && latitude <= maxLat &&
        longitude >= minLon && longitude <= maxLon
    }
}
