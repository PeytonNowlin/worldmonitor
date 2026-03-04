import Foundation
import MapKit

/// UCDP (Uppsala Conflict Data Program) conflict event
struct UCDPConflictEvent: Identifiable, Codable, Hashable {
    let id: String // Conflict ID
    let conflictName: String
    let location: String
    let latitude: Double
    let longitude: Double
    let startDate: Date
    let endDate: Date?
    let deaths: Int
    let deathsCivilians: Int
    let typeOfConflict: ConflictType
    let conflictIntensity: ConflictIntensity
    let year: Int
    let cumulativeDeaths: Int?
    let sideA: String
    let sideB: String
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    var isActive: Bool {
        endDate == nil || endDate! > Date()
    }
    
    /// Severity based on deaths and intensity
    var severity: Int {
        switch conflictIntensity {
        case .minor:
            return deaths > 100 ? 3 : 2
        case .war:
            return deaths > 10000 ? 5 : 4
        case .unknown:
            return min(5, max(1, deaths / 1000))
        }
    }
    
    enum ConflictType: String, Codable {
        case extrasystemic = "1"
        case interstate = "2"
        case intrastate = "3"
        case internationalizedIntrastate = "4"
        
        var displayName: String {
            switch self {
            case .extrasystemic: return "Extrasystemic"
            case .interstate: return "Interstate"
            case .intrastate: return "Civil War"
            case .internationalizedIntrastate: return "Internationalized Civil War"
            }
        }
    }
    
    enum ConflictIntensity: String, Codable {
        case minor = "1"
        case war = "2"
        case unknown = "-1"
        
        var displayName: String {
            switch self {
            case .minor: return "Minor Conflict"
            case .war: return "War"
            case .unknown: return "Unknown"
            }
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id = "ConflictId"
        case conflictName = "ConflictName"
        case location = "Location"
        case latitude = "Latitude"
        case longitude = "Longitude"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case deaths = "Deaths"
        case deathsCivilians = "DeathsCivilians"
        case typeOfConflict = "TypeOfConflict"
        case conflictIntensity = "IntensityLevel"
        case year = "Year"
        case cumulativeDeaths = "CumulativeDeaths"
        case sideA = "SideA"
        case sideB = "SideB"
    }
}

/// UCDP API Response
struct UCDPResponse: Codable {
    let result: [UCDPConflictEvent]
    let totalCount: Int
    let pageCount: Int
    
    enum CodingKeys: String, CodingKey {
        case result = "Result"
        case totalCount = "TotalCount"
        case pageCount = "PageCount"
    }
}

/// UCDP Version information for auto-discovery
struct UCDPVersionInfo {
    let version: String
    let lastUpdated: Date
    let apiBasePath: String
}

// MARK: - UCDP Country Constants

/// Countries with curated conflict data in UCDP
enum UCDPCountry: String, CaseIterable {
    case afghanistan = "AFG"
    case myanmar = "MMR"
    case ethiopia = "ETH"
    case yemen = "YEM"
    case syria = "SYR"
    case ukraine = "UKR"
    case mali = "MLI"
    case sudan = "SDN"
    case nigeria = "NGA"
    case iraq = "IRQ"
    case somalia = "SOM"
    case southSudan = "SSD"
    case colombia = "COL"
    case drCongo = "COD"
    case centralAfricanRepublic = "CAF"
    case libya = "LBY"
    case pakistan = "PAK"
    case india = "IND"
    case israel = "ISR"
    case palestine = "PSE"
    case turkey = "TUR"
    
    var displayName: String {
        switch self {
        case .afghanistan: return "Afghanistan"
        case .myanmar: return "Myanmar"
        case .ethiopia: return "Ethiopia"
        case .yemen: return "Yemen"
        case .syria: return "Syria"
        case .ukraine: return "Ukraine"
        case .mali: return "Mali"
        case .sudan: return "Sudan"
        case .nigeria: return "Nigeria"
        case .iraq: return "Iraq"
        case .somalia: return "Somalia"
        case .southSudan: return "South Sudan"
        case .colombia: return "Colombia"
        case .drCongo: return "DR Congo"
        case .centralAfricanRepublic: return "Central African Republic"
        case .libya: return "Libya"
        case .pakistan: return "Pakistan"
        case .india: return "India"
        case .israel: return "Israel"
        case .palestine: return "Palestine"
        case .turkey: return "Turkey"
        }
    }
}
