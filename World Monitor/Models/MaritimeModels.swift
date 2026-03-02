import Foundation
import MapKit

// MARK: - GPS Jamming Models

/// GPS/GNSS interference data from gpsjam.org
struct GPSJamData: Codable {
    let timestamp: Date
    let hexCells: [GPSJamHexCell]
    
    enum CodingKeys: String, CodingKey {
        case timestamp
        case hexCells = "data"
    }
}

/// Individual H3 hex cell with GPS jamming data
struct GPSJamHexCell: Identifiable, Codable {
    let id: String // H3 cell ID
    let h3Index: String
    let aircraftCount: Int
    let aircraftWithBadGps: Int
    let interferencePercent: Double
    let regionTag: String?
    let centerLatitude: Double
    let centerLongitude: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }
    
    /// Classification of interference level
    var interferenceLevel: GPSJamLevel {
        if interferencePercent > 10 {
            return .high
        } else if interferencePercent > 2 {
            return .medium
        } else {
            return .low
        }
    }
    
    var isSignificant: Bool {
        aircraftCount >= 3 && interferencePercent > 2
    }
    
    enum CodingKeys: String, CodingKey {
        case h3Index
        case aircraftCount
        case aircraftWithBadGps
        case interferencePercent
        case regionTag
        case centerLatitude
        case centerLongitude
    }
    
    var id: String { h3Index }
}

enum GPSJamLevel: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    
    var color: String {
        switch self {
        case .low: return "green"
        case .medium: return "orange"
        case .high: return "red"
        }
    }
    
    var minPercent: Double {
        switch self {
        case .low: return 0
        case .medium: return 2
        case .high: return 10
        }
    }
}

/// Named conflict regions for GPS jamming
enum GPSJamRegion: String, CaseIterable {
    case iranIraq = "Iran-Iraq"
    case ukraineRussia = "Ukraine-Russia"
    case levant = "Levant"
    case baltic = "Baltic"
    case mediterranean = "Mediterranean"
    case blackSea = "Black Sea"
    case arctic = "Arctic"
    case caucasus = "Caucasus"
    case centralAsia = "Central Asia"
    case hornOfAfrica = "Horn of Africa"
    case koreanPeninsula = "Korean Peninsula"
    case southChinaSea = "South China Sea"
    
    var boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        switch self {
        case .iranIraq:
            return (24, 40, 43, 65)
        case .ukraineRussia:
            return (44, 60, 22, 45)
        case .levant:
            return (30, 37, 32, 43)
        case .baltic:
            return (53, 61, 15, 32)
        case .mediterranean:
            return (30, 45, -10, 40)
        case .blackSea:
            return (40, 48, 27, 42)
        case .arctic:
            return (66, 85, -180, 180)
        case .caucasus:
            return (37, 45, 35, 52)
        case .centralAsia:
            return (35, 55, 50, 85)
        case .hornOfAfrica:
            return (0, 18, 35, 55)
        case .koreanPeninsula:
            return (33, 44, 123, 132)
        case .southChinaSea:
            return (0, 25, 100, 125)
        }
    }
    
    func contains(latitude: Double, longitude: Double) -> Bool {
        let box = boundingBox
        return latitude >= box.minLat && latitude <= box.maxLat &&
               longitude >= box.minLon && longitude <= box.maxLon
    }
}

// MARK: - Military Base Models

/// Military base with full details
struct MilitaryBase: Identifiable, Codable {
    let id: String
    let name: String
    let country: String
    let operatorCountry: String // Country that operates the base
    let latitude: Double
    let longitude: Double
    let type: BaseType
    let size: BaseSize
    let established: Int? // Year established
    let personnel: Int? // Estimated personnel count
    let description: String?
    let majorUnits: [String] // Major units stationed
    let capabilities: [Capability]
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    enum BaseType: String, Codable, CaseIterable {
        case army = "Army"
        case navy = "Navy"
        case airForce = "Air Force"
        case marine = "Marine Corps"
        case joint = "Joint"
        case coastGuard = "Coast Guard"
        case specialOperations = "Special Operations"
        case intelligence = "Intelligence"
        case logistics = "Logistics"
        
        var icon: String {
            switch self {
            case .army: return "shield.fill"
            case .navy: return "water.waves"
            case .airForce: return "airplane"
            case .marine: return "person.fill"
            case .joint: return "star.fill"
            case .coastGuard: return "lifepreserver"
            case .specialOperations: return "eye.fill"
            case .intelligence: return "antenna.radiowaves.left.and.right"
            case .logistics: return "shippingbox.fill"
            }
        }
    }
    
    enum BaseSize: String, Codable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"
        case major = "Major"
        
        var relativeScale: Double {
            switch self {
            case .small: return 0.5
            case .medium: return 1.0
            case .large: return 1.5
            case .major: return 2.0
            }
        }
    }
    
    enum Capability: String, Codable {
        case airOperations = "Air Operations"
        case navalOperations = "Naval Operations"
        case groundForces = "Ground Forces"
        case nuclearStorage = "Nuclear Storage"
        case missileDefense = "Missile Defense"
        case intelligence = "Intelligence"
        case specialOperations = "Special Operations"
        case logistics = "Logistics"
        case training = "Training"
        case medical = "Medical"
        case cyber = "Cyber Operations"
    }
}

/// Summary statistics for military bases
struct MilitaryBaseStats {
    let totalCount: Int
    let byOperator: [String: Int] // Country -> count
    let byType: [MilitaryBase.BaseType: Int]
    let byRegion: [String: Int]
    let majorInstallations: [MilitaryBase]
}

// MARK: - Military Operator Constants

enum MilitaryOperator: String, CaseIterable {
    case unitedStates = "United States"
    case russia = "Russia"
    case china = "China"
    case unitedKingdom = "United Kingdom"
    case france = "France"
    case germany = "Germany"
    case turkey = "Turkey"
    case israel = "Israel"
    case iran = "Iran"
    case india = "India"
    case pakistan = "Pakistan"
    case japan = "Japan"
    case southKorea = "South Korea"
    
    var flag: String {
        switch self {
        case .unitedStates: return "🇺🇸"
        case .russia: return "🇷🇺"
        case .china: return "🇨🇳"
        case .unitedKingdom: return "🇬🇧"
        case .france: return "🇫🇷"
        case .germany: return "🇩🇪"
        case .turkey: return "🇹🇷"
        case .israel: return "🇮🇱"
        case .iran: return "🇮🇷"
        case .india: return "🇮🇳"
        case .pakistan: return "🇵🇰"
        case .japan: return "🇯🇵"
        case .southKorea: return "🇰🇷"
        }
    }
}
