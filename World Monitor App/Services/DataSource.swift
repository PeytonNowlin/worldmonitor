import Foundation

/// Represents all external data sources integrated into the app
/// Sources are organized by category for clarity
enum DataSource: String, CaseIterable, Identifiable {
    // MARK: - Natural Events & Disasters
    case usgs
    case nasaEONET
    case gdacs
    
    // MARK: - Conflict & Security
    case gdelt
    case ucdp
    
    // MARK: - Military & Maritime
    case openSky
    case usni
    case gpsJam
    case militaryBases
    
    // MARK: - Cyber Threat Intelligence
    case feodoTracker
    case urlhaus
    case c2IntelFeeds
    
    // MARK: - Economic & Market Data
    case yahooFinance
    case coinGecko
    case bis
    case fearGreed
    case mempoolSpace
    
    // MARK: - Infrastructure & Supply Chain
    case cloudflareRadar
    case unOchaHAPI
    
    // MARK: - Travel & Safety
    case usTravelAdvisory
    case faaAirport
    
    var id: String { rawValue }
    
    /// Display name for the data source
    var displayName: String {
        switch self {
        case .usgs: return "USGS Earthquakes"
        case .nasaEONET: return "NASA EONET"
        case .gdacs: return "GDACS"
        case .gdelt: return "GDELT"
        case .ucdp: return "UCDP"
        case .openSky: return "OpenSky"
        case .usni: return "USNI Fleet"
        case .gpsJam: return "GPS Jamming"
        case .militaryBases: return "Military Bases"
        case .feodoTracker: return "Feodo Tracker"
        case .urlhaus: return "URLhaus"
        case .c2IntelFeeds: return "C2Intel"
        case .yahooFinance: return "Yahoo Finance"
        case .coinGecko: return "CoinGecko"
        case .bis: return "BIS"
        case .fearGreed: return "Fear & Greed"
        case .mempoolSpace: return "Mempool.space"
        case .cloudflareRadar: return "Cloudflare Radar"
        case .unOchaHAPI: return "UN OCHA HAPI"
        case .usTravelAdvisory: return "US Travel Advisories"
        case .faaAirport: return "FAA Airport Status"
        }
    }
    
    /// Category for grouping in UI/settings
    var category: DataSourceCategory {
        switch self {
        case .usgs, .nasaEONET, .gdacs:
            return .naturalEvents
        case .gdelt, .ucdp:
            return .conflictSecurity
        case .openSky, .usni, .gpsJam, .militaryBases:
            return .militaryMaritime
        case .feodoTracker, .urlhaus, .c2IntelFeeds:
            return .cyberThreat
        case .yahooFinance, .coinGecko, .bis, .fearGreed, .mempoolSpace:
            return .economicMarkets
        case .cloudflareRadar, .unOchaHAPI:
            return .infrastructure
        case .usTravelAdvisory, .faaAirport:
            return .travelSafety
        }
    }
    
    /// Default cache TTL in seconds
    var defaultCacheTTL: TimeInterval {
        switch self {
        case .usgs: return 180      // 3 minutes
        case .nasaEONET: return 300  // 5 minutes
        case .gdacs: return 300      // 5 minutes
        case .gdelt: return 900     // 15 minutes
        case .ucdp: return 3600     // 1 hour
        case .openSky: return 60     // 1 minute
        case .usni: return 3600     // 1 hour
        case .gpsJam: return 3600    // 1 hour
        case .militaryBases: return 86400 // 24 hours
        case .feodoTracker: return 600   // 10 minutes
        case .urlhaus: return 900   // 15 minutes
        case .c2IntelFeeds: return 3600 // 1 hour
        case .yahooFinance: return 300   // 5 minutes
        case .coinGecko: return 120  // 2 minutes
        case .bis: return 21600     // 6 hours
        case .fearGreed: return 3600 // 1 hour
        case .mempoolSpace: return 900   // 15 minutes
        case .cloudflareRadar: return 600  // 10 minutes
        case .unOchaHAPI: return 86400   // 24 hours
        case .usTravelAdvisory: return 21600 // 6 hours
        case .faaAirport: return 300  // 5 minutes
        }
    }
    
    /// Whether this source requires an API key (all current sources are no-key)
    var requiresAPIKey: Bool {
        return false
    }
}

enum DataSourceCategory: String, CaseIterable {
    case naturalEvents = "Natural Events"
    case conflictSecurity = "Conflict & Security"
    case militaryMaritime = "Military & Maritime"
    case cyberThreat = "Cyber Threat Intel"
    case economicMarkets = "Economic & Markets"
    case infrastructure = "Infrastructure"
    case travelSafety = "Travel & Safety"
}
