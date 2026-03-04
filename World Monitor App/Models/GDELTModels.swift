import Foundation
import MapKit

/// GDELT Event from the GeoJSON API
struct GDELTEvent: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let latitude: Double
    let longitude: Double
    let eventDate: Date
    let eventType: String
    let actor1: String
    let actor2: String
    let goldsteinScale: Double // -10 to +10, conflict to cooperation
    let numMentions: Int
    let numSources: Int
    let numArticles: Int
    let sourceURL: String?
    let avgTone: Double // Sentiment score
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    /// Severity based on goldstein scale and mentions
    var severity: Int {
        // Goldstein scale: -10 (conflict) to +10 (cooperation)
        // Lower (more negative) = more severe
        let baseSeverity: Int
        if goldsteinScale <= -8 {
            baseSeverity = 5 // Extreme conflict
        } else if goldsteinScale <= -5 {
            baseSeverity = 4 // High conflict
        } else if goldsteinScale <= -2 {
            baseSeverity = 3 // Medium conflict
        } else if goldsteinScale < 0 {
            baseSeverity = 2 // Low conflict
        } else {
            baseSeverity = 1 // Cooperative
        }
        
        // Boost by mention count (virality)
        let mentionBoost = min(2, numMentions / 100)
        return min(5, baseSeverity + mentionBoost)
    }
    
    enum CodingKeys: String, CodingKey {
        case id = "GLOBALEVENTID"
        case title = "EventCode"
        case latitude = "ActionGeo_Lat"
        case longitude = "ActionGeo_Long"
        case eventDate = "SQLDATE"
        case eventType = "EventRootCode"
        case actor1 = "Actor1Name"
        case actor2 = "Actor2Name"
        case goldsteinScale = "GoldsteinScale"
        case numMentions = "NumMentions"
        case numSources = "NumSources"
        case numArticles = "NumArticles"
        case sourceURL = "SOURCEURL"
        case avgTone = "AvgTone"
    }
}

/// GDELT GKG (Global Knowledge Graph) Article
struct GDELTGKGArticle: Identifiable, Codable, Hashable {
    let id: String // GKG Record ID
    let publishDate: Date
    let sourceIdentifier: String
    let sourceCommonName: String
    let documentIdentifier: String
    let themes: [String]
    let locations: [GDELTLocation]
    let persons: [String]
    let organizations: [String]
    let tone: GDELTTone
    let socialImageEmbeds: [String] // Image URLs
    let socialVideoEmbeds: [String] // Video URLs
    let quote: String?
    
    /// Computed sentiment classification
    var sentiment: GDELTSentiment {
        if tone.tone < -5 {
            return .veryNegative
        } else if tone.tone < -2 {
            return .negative
        } else if tone.tone > 5 {
            return .veryPositive
        } else if tone.tone > 2 {
            return .positive
        } else {
            return .neutral
        }
    }
}

struct GDELTLocation: Codable, Hashable {
    let type: LocationType
    let fullName: String
    let countryCode: String
    let admin1Code: String
    let latitude: Double
    let longitude: Double
    let featureID: String
    
    enum LocationType: Int, Codable {
        case country = 1
        case usState = 2
        case usCity = 3
        case worldCity = 4
        case worldState = 5
    }
}

struct GDELTTone: Codable, Hashable {
    let tone: Double // Overall tone
    let positiveScore: Double
    let negativeScore: Double
    let polarity: Double
    let activityRefDensity: Double
    let selfGroupRefDensity: Double
    let wordCount: Int
}

enum GDELTSentiment: String {
    case veryNegative = "Very Negative"
    case negative = "Negative"
    case neutral = "Neutral"
    case positive = "Positive"
    case veryPositive = "Very Positive"
}

/// Root codes for GDELT event categorization
enum GDELTRootCode: String, CaseIterable {
    case makePublicStatement = "01"
    case appeal = "02"
    case expressIntentToCooperate = "03"
    case consult = "04"
    case engageInMaterialCooperation = "05"
    case engageInMaterialConflict = "06"
    case threaten = "07"
    case disapprove = "08"
    case reject = "09"
    case protest = "10"
    case rejectMaterialCooperation = "11"
    case rejectMaterialConflict = "12"
    case threatenMaterialConflict = "13"
    case protestDemanding = "14"
    case assault = "15"
    case fight = "16"
    case useForce = "17"
    case coerce = "18"
    case assaultWithWeapons = "19"
    case useUnconventionalMassViolence = "20"
    
    var displayName: String {
        switch self {
        case .makePublicStatement: return "Public Statement"
        case .appeal: return "Appeal"
        case .expressIntentToCooperate: return "Intent to Cooperate"
        case .consult: return "Consult"
        case .engageInMaterialCooperation: return "Material Cooperation"
        case .engageInMaterialConflict: return "Material Conflict"
        case .threaten: return "Threaten"
        case .disapprove: return "Disapprove"
        case .reject: return "Reject"
        case .protest: return "Protest"
        case .rejectMaterialCooperation: return "Reject Cooperation"
        case .rejectMaterialConflict: return "Reject Conflict"
        case .threatenMaterialConflict: return "Threaten Conflict"
        case .protestDemanding: return "Protest Demands"
        case .assault: return "Assault"
        case .fight: return "Fight"
        case .useForce: return "Use Force"
        case .coerce: return "Coerce"
        case .assaultWithWeapons: return "Armed Assault"
        case .useUnconventionalMassViolence: return "Mass Violence"
        }
    }
    
    var isConflict: Bool {
        switch self {
        case .engageInMaterialConflict, .threaten, .threatenMaterialConflict,
             .assault, .fight, .useForce, .coerce, .assaultWithWeapons, .useUnconventionalMassViolence:
            return true
        default:
            return false
        }
    }
    
    var isCooperation: Bool {
        switch self {
        case .expressIntentToCooperate, .consult, .engageInMaterialCooperation:
            return true
        default:
            return false
        }
    }
}

/// Response from GDELT GeoJSON API
struct GDELTGeoJSONResponse: Codable {
    let features: [GDELTGeoJSONFeature]
}

struct GDELTGeoJSONFeature: Codable {
    let type: String
    let properties: GDELTEvent
    let geometry: GDELTGeometry
}

struct GDELTGeometry: Codable {
    let type: String
    let coordinates: [Double]
}

/// Response from GDELT GKG API
struct GDELTGKGResponse: Codable {
    let data: [GDELTGKGRecord]
}

struct GDELTGKGRecord: Codable {
    let gkgRecordID: String
    let publishDate: Date
    let sourceCollectionIdentifier: String
    let sourceCommonName: String
    let documentIdentifier: String
    let themes: String // Pipe-delimited
    let locations: String // Hash-delimited locations
    let persons: String // Pipe-delimited
    let organizations: String // Pipe-delimited
    let toneData: String // Comma-delimited tone values
    
    func parseThemes() -> [String] {
        themes.split(separator: ";").map { String($0) }
    }
    
    func parsePersons() -> [String] {
        persons.split(separator: ",").map { String($0) }
    }
    
    func parseOrganizations() -> [String] {
        organizations.split(separator: ",").map { String($0) }
    }
    
    func parseLocations() -> [GDELTLocation] {
        // Format: Type#FullName#CountryCode#Admin1#Lat#Lon#FeatureID
        return locations.split(separator: ";").compactMap { locationStr in
            let parts = locationStr.split(separator: "#").map { String($0) }
            guard parts.count >= 7,
                  let typeInt = Int(parts[0]),
                  let lat = Double(parts[4]),
                  let lon = Double(parts[5]) else {
                return nil
            }
            
            return GDELTLocation(
                type: GDELTLocation.LocationType(rawValue: typeInt) ?? .worldCity,
                fullName: parts[1],
                countryCode: parts[2],
                admin1Code: parts[3],
                latitude: lat,
                longitude: lon,
                featureID: parts[6]
            )
        }
    }
    
    func parseTone() -> GDELTTone {
        let parts = toneData.split(separator: ",").compactMap { Double($0) }
        return GDELTTone(
            tone: parts[safe: 0] ?? 0,
            positiveScore: parts[safe: 1] ?? 0,
            negativeScore: parts[safe: 2] ?? 0,
            polarity: parts[safe: 3] ?? 0,
            activityRefDensity: parts[safe: 4] ?? 0,
            selfGroupRefDensity: parts[safe: 5] ?? 0,
            wordCount: Int(parts[safe: 6] ?? 0)
        )
    }
}

// MARK: - GDELT Query Parameters

struct GDELTQuery {
    var startDate: Date?
    var endDate: Date?
    var source: String?
    var theme: String?
    var location: GDELTLocationFilter?
    var maxRecords: Int = 250
    
    struct GDELTLocationFilter {
        let nearLatitude: Double
        let nearLongitude: Double
        let radiusKm: Double
    }
    
    /// Convert to query parameters for API
    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        
        if let start = startDate {
            items.append(URLQueryItem(name: "STARTDATETIME", value: formatter.string(from: start)))
        }
        if let end = endDate {
            items.append(URLQueryItem(name: "ENDDATETIME", value: formatter.string(from: end)))
        }
        if let source = source {
            items.append(URLQueryItem(name: "SOURCE", value: source))
        }
        if let theme = theme {
            items.append(URLQueryItem(name: "THEME", value: theme))
        }
        if let location = location {
            items.append(URLQueryItem(name: "NEARLAT", value: "\(location.nearLatitude)"))
            items.append(URLQueryItem(name: "NEARLON", value: "\(location.nearLongitude)"))
            items.append(URLQueryItem(name: "NEARDIST", value: "\(location.radiusKm)"))
        }
        items.append(URLQueryItem(name: "MAXROWS", value: "\(maxRecords)"))
        items.append(URLQueryItem(name: "FORMAT", value: "GeoJSON"))
        
        return items
    }
}

// MARK: - Collection Extensions

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
