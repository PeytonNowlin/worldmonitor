import Foundation

/// Configuration for all data source endpoints
struct EndpointConfiguration {
    let baseURL: URL
    let timeout: TimeInterval
    let retryPolicy: RetryPolicy
    
    struct RetryPolicy {
        let maxRetries: Int
        let baseDelay: TimeInterval
        let maxDelay: TimeInterval
        let exponentialBase: Double
    }
}

/// Static configuration for all supported data sources
enum EndpointConfigurations {
    
    // MARK: - Natural Events
    
    static var usgs: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://earthquake.usgs.gov")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    static var nasaEONET: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://eonet.gsfc.nasa.gov/api/v3")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    static var gdacs: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://www.gdacs.org/gdacsapi")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    // MARK: - Conflict & Security
    
    static var gdelt: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://api.gdeltproject.org")!,
            timeout: 30,
            retryPolicy: EndpointConfiguration.RetryPolicy(
                maxRetries: 3,
                baseDelay: 1.0,
                maxDelay: 10.0,
                exponentialBase: 2.0
            )
        )
    }
    
    static var ucdp: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://ucdpapi.pcr.uu.se/api")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    // MARK: - Military & Maritime
    
    static var openSky: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://opensky-network.org")!,
            timeout: 30,
            retryPolicy: EndpointConfiguration.RetryPolicy(
                maxRetries: 3,
                baseDelay: 2.0,
                maxDelay: 30.0,
                exponentialBase: 2.0
            )
        )
    }
    
    static var usni: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://news.usni.org")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    static var gpsJam: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://gpsjam.org")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    // MARK: - Cyber Threat Intelligence
    
    static var feodoTracker: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://feodotracker.abuse.ch")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    static var urlhaus: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://urlhaus-api.abuse.ch")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    static var c2IntelFeeds: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://raw.githubusercontent.com")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    // MARK: - Economic & Market Data
    
    static var yahooFinance: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://query1.finance.yahoo.com/v8")!,
            timeout: 30,
            retryPolicy: EndpointConfiguration.RetryPolicy(
                maxRetries: 3,
                baseDelay: 0.5,
                maxDelay: 10.0,
                exponentialBase: 2.0
            )
        )
    }
    
    static var coinGecko: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://api.coingecko.com/api/v3")!,
            timeout: 30,
            retryPolicy: EndpointConfiguration.RetryPolicy(
                maxRetries: 5,
                baseDelay: 2.0,
                maxDelay: 60.0,
                exponentialBase: 2.0
            )
        )
    }
    
    static var bis: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://stats.bis.org/api/v1")!,
            timeout: 60,
            retryPolicy: .default
        )
    }
    
    static var fearGreed: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://api.alternative.me")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    static var mempoolSpace: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://mempool.space/api/v1")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    // MARK: - Infrastructure & Supply Chain
    
    static var cloudflareRadar: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://api.cloudflare.com/client/v4")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    static var unOchaHAPI: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://api.humdata.org/api/v1")!,
            timeout: 60,
            retryPolicy: .default
        )
    }
    
    // MARK: - Travel & Safety
    
    static var usTravelAdvisory: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://travel.state.gov")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    static var faaAirport: EndpointConfiguration {
        EndpointConfiguration(
            baseURL: URL(string: "https://nasstatus.faa.gov/api")!,
            timeout: 30,
            retryPolicy: .default
        )
    }
    
    // MARK: - Helper Methods
    
    static func configuration(for source: DataSource) -> EndpointConfiguration {
        switch source {
        case .usgs: return usgs
        case .nasaEONET: return nasaEONET
        case .gdacs: return gdacs
        case .gdelt: return gdelt
        case .ucdp: return ucdp
        case .openSky: return openSky
        case .usni: return usni
        case .gpsJam: return gpsJam
        case .militaryBases: return usni // Uses same base for now
        case .feodoTracker: return feodoTracker
        case .urlhaus: return urlhaus
        case .c2IntelFeeds: return c2IntelFeeds
        case .yahooFinance: return yahooFinance
        case .coinGecko: return coinGecko
        case .bis: return bis
        case .fearGreed: return fearGreed
        case .mempoolSpace: return mempoolSpace
        case .cloudflareRadar: return cloudflareRadar
        case .unOchaHAPI: return unOchaHAPI
        case .usTravelAdvisory: return usTravelAdvisory
        case .faaAirport: return faaAirport
        }
    }
}

// MARK: - Retry Policy Defaults

extension EndpointConfiguration.RetryPolicy {
    static var `default`: EndpointConfiguration.RetryPolicy {
        EndpointConfiguration.RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 30.0,
            exponentialBase: 2.0
        )
    }
    
    static var aggressive: EndpointConfiguration.RetryPolicy {
        EndpointConfiguration.RetryPolicy(
            maxRetries: 5,
            baseDelay: 0.5,
            maxDelay: 60.0,
            exponentialBase: 2.0
        )
    }
    
    static var gentle: EndpointConfiguration.RetryPolicy {
        EndpointConfiguration.RetryPolicy(
            maxRetries: 2,
            baseDelay: 2.0,
            maxDelay: 30.0,
            exponentialBase: 2.0
        )
    }
}

// MARK: - URL Construction Helpers

extension EndpointConfiguration {
    /// Build a URL with the given path and query items
    func url(path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        components?.queryItems = queryItems
        return components?.url
    }
}
