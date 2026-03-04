import Foundation
import MapKit

// MARK: - Threat IOC Models

/// Base protocol for threat indicators
protocol ThreatIOC: Identifiable, Codable {
    var id: String { get }
    var firstSeen: Date { get }
    var lastSeen: Date { get }
    var threatType: ThreatType { get }
    var severity: ThreatSeverity { get }
    var countryCode: String? { get }
    var asn: String? { get }
}

enum ThreatType: String, Codable, CaseIterable {
    case c2Server = "C2 Server"
    case malwareHost = "Malware Host"
    case phishing = "Phishing"
    case maliciousURL = "Malicious URL"
    case botnet = "Botnet"
    case darkComet = "DarkComet"
    case heodo = "Heodo"
    case dridex = "Dridex"
    case trickbot = "TrickBot"
    case emotet = "Emotet"
    case unknown = "Unknown"
    
    var icon: String {
        switch self {
        case .c2Server: return "server.rack"
        case .malwareHost: return "ladybug.fill"
        case .phishing: return "envelope.badge.shield.half.filled"
        case .maliciousURL: return "link.badge.plus"
        case .botnet: return "network"
        case .darkComet: return "star.fill"
        case .heodo, .dridex, .trickbot, .emotet:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

enum ThreatSeverity: Int, Codable, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4
    
    var color: String {
        switch self {
        case .low: return "green"
        case .medium: return "yellow"
        case .high: return "orange"
        case .critical: return "red"
        }
    }
    
    static func < (lhs: ThreatSeverity, rhs: ThreatSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Feodo Tracker Models

/// C2 Server from Feodo Tracker (abuse.ch)
struct FeodoC2Server: ThreatIOC, Codable {
    let ipAddress: String
    let port: Int
    let threatType: ThreatType
    let malwareFamily: String
    let firstSeen: Date
    let lastSeen: Date
    let countryCode: String?
    let asn: String?
    let hostName: String?
    
    var severity: ThreatSeverity {
        switch malwareFamily.lowercased() {
        case "emotet", "trickbot":
            return .critical
        case "dridex", "heodo":
            return .high
        default:
            return .medium
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case ipAddress = "ip_address"
        case alternateIPAddress = "dst_ip"
        case fallbackIPAddress = "ip"
        case port
        case alternatePort = "dst_port"
        case threatTag = "tag"
        case malwareFamily = "malware"
        case alternateMalwareFamily = "malware_family"
        case firstSeen = "first_seen"
        case alternateFirstSeen = "first_seen_utc"
        case lastSeen = "last_seen"
        case alternateLastSeen = "last_online"
        case countryCode = "countrycode"
        case alternateCountryCode = "country_code"
        case asn
        case hostName = "hostname"
        case alternateHostName = "host"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let ip = try container.decodeIfPresent(String.self, forKey: .ipAddress), !ip.isEmpty {
            ipAddress = ip
        } else if let ip = try container.decodeIfPresent(String.self, forKey: .alternateIPAddress), !ip.isEmpty {
            ipAddress = ip
        } else {
            ipAddress = try container.decode(String.self, forKey: .fallbackIPAddress)
        }

        if let intPort = try container.decodeIfPresent(Int.self, forKey: .port) {
            port = intPort
        } else if let stringPort = try container.decodeIfPresent(String.self, forKey: .port), let intPort = Int(stringPort) {
            port = intPort
        } else if let intPort = try container.decodeIfPresent(Int.self, forKey: .alternatePort) {
            port = intPort
        } else if let stringPort = try container.decodeIfPresent(String.self, forKey: .alternatePort), let intPort = Int(stringPort) {
            port = intPort
        } else {
            port = 0
        }

        let tag = (try container.decodeIfPresent(String.self, forKey: .threatTag) ?? "").lowercased()
        threatType = FeodoC2Server.mapThreatType(tag: tag)

        if let malware = try container.decodeIfPresent(String.self, forKey: .malwareFamily), !malware.isEmpty {
            malwareFamily = malware
        } else {
            malwareFamily = try container.decodeIfPresent(String.self, forKey: .alternateMalwareFamily) ?? "unknown"
        }

        if let first = try container.decodeIfPresent(Date.self, forKey: .firstSeen) {
            firstSeen = first
        } else {
            firstSeen = try container.decodeIfPresent(Date.self, forKey: .alternateFirstSeen) ?? .distantPast
        }

        if let last = try container.decodeIfPresent(Date.self, forKey: .lastSeen) {
            lastSeen = last
        } else {
            lastSeen = try container.decodeIfPresent(Date.self, forKey: .alternateLastSeen) ?? firstSeen
        }

        if let cc = try container.decodeIfPresent(String.self, forKey: .countryCode), !cc.isEmpty {
            countryCode = cc
        } else {
            countryCode = try container.decodeIfPresent(String.self, forKey: .alternateCountryCode)
        }

        asn = try container.decodeIfPresent(String.self, forKey: .asn)

        if let host = try container.decodeIfPresent(String.self, forKey: .hostName), !host.isEmpty {
            hostName = host
        } else {
            hostName = try container.decodeIfPresent(String.self, forKey: .alternateHostName)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ipAddress, forKey: .ipAddress)
        try container.encode(port, forKey: .port)
        try container.encode(threatType.rawValue, forKey: .threatTag)
        try container.encode(malwareFamily, forKey: .malwareFamily)
        try container.encode(firstSeen, forKey: .firstSeen)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encodeIfPresent(countryCode, forKey: .countryCode)
        try container.encodeIfPresent(asn, forKey: .asn)
        try container.encodeIfPresent(hostName, forKey: .hostName)
    }
    
    var id: String { ipAddress }

    private static func mapThreatType(tag: String) -> ThreatType {
        switch tag {
        case "darkcomet":
            return .darkComet
        case "heodo":
            return .heodo
        case "dridex":
            return .dridex
        case "trickbot":
            return .trickbot
        case "emotet":
            return .emotet
        default:
            return .c2Server
        }
    }
}

struct FeodoTrackerResponse: Codable {
    let data: [FeodoC2Server]
    let meta: FeodoMeta
    
    struct FeodoMeta: Codable {
        let generated: Date
        let count: Int
    }
}

// MARK: - URLhaus Models

/// Malicious URL from URLhaus (abuse.ch)
struct URLhausEntry: ThreatIOC, Codable {
    let id: String
    let url: String
    let urlStatus: URLStatus
    let threatType: ThreatType
    let malwareFamily: String?
    let firstSeen: Date
    let lastSeen: Date
    let countryCode: String?
    let asn: String?
    let hostName: String
    let ipAddress: String?
    let tags: [String]
    
    enum URLStatus: String, Codable {
        case online = "online"
        case offline = "offline"
        case unknown = "unknown"
    }
    
    var severity: ThreatSeverity {
        if urlStatus == .online {
            return .high
        } else if urlStatus == .offline {
            return .medium
        }
        return .low
    }
    
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case url
        case urlStatus = "url_status"
        case threatType = "threat"
        case malwareFamily = "malware"
        case firstSeen = "date_added"
        case lastSeen = "last_seen"
        case countryCode = "country"
        case asn
        case hostName = "host"
        case ipAddress = "ip_address"
        case tags
    }
}

struct URLhausResponse: Codable {
    let urls: [URLhausEntry]
}

struct URLhausRecentResponse: Codable {
    let urls: [URLhausEntry]
}

// MARK: - C2IntelFeeds Models

/// Community-sourced C2 IOC from C2IntelFeeds (GitHub)
struct C2IntelIOC: ThreatIOC, Codable {
    let id: String
    let indicator: String // IP, domain, or URL
    let indicatorType: IndicatorType
    let threatType: ThreatType
    let malwareFamily: String
    let firstSeen: Date
    let lastSeen: Date
    let countryCode: String?
    let source: String // Which feed it came from
    let confidence: ConfidenceLevel
    
    enum IndicatorType: String, Codable {
        case ipv4 = "ipv4"
        case ipv6 = "ipv6"
        case domain = "domain"
        case url = "url"
        case md5 = "md5"
        case sha256 = "sha256"
    }
    
    enum ConfidenceLevel: String, Codable {
        case high = "high"
        case medium = "medium"
        case low = "low"
    }
    
    var severity: ThreatSeverity {
        switch confidence {
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }
    
    var asn: String? { nil } // Not available in C2Intel
}

// MARK: - Aggregated Threat Data

/// Aggregated threat intelligence summary
struct ThreatIntelligenceSummary {
    let timestamp: Date
    let totalActiveC2Servers: Int
    let totalMaliciousURLs: Int
    let byMalwareFamily: [String: Int]
    let byCountry: [String: Int]
    let topThreats: [any ThreatIOC]
    let recentAdditions: [any ThreatIOC]
}

/// Threat statistics for a specific country
struct CountryThreatStats {
    let countryCode: String
    let countryName: String
    let c2ServerCount: Int
    let maliciousURLCount: Int
    let topMalwareFamilies: [(family: String, count: Int)]
    let lastActiveThreat: Date?
}

// MARK: - GeoIP Helper

struct GeoIPInfo: Codable {
    let ip: String
    let countryCode: String?
    let countryName: String?
    let city: String?
    let latitude: Double?
    let longitude: Double?
    let asn: String?
    let organization: String?
    
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
