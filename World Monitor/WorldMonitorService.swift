import Foundation

struct FeedQuery {
    let variant: MonitorVariant
    let region: RegionPreset
    let window: TimeWindow
}

protocol WorldMonitorService {
    func snapshot(for query: FeedQuery) async throws -> MonitoringSnapshot
    func headlines(for query: FeedQuery) async throws -> [FeedItem]
}

struct MockWorldMonitorService: WorldMonitorService {
    static let shared = MockWorldMonitorService()

    func snapshot(for query: FeedQuery) async throws -> MonitoringSnapshot {
        try await Task.sleep(nanoseconds: 200_000_000)

        let bias = query.variant == .finance ? "Bearish" : (query.variant == .tech ? "Bullish" : "Mixed")
        let baseScore = variantScore(for: query.variant, region: query.region)
        return MonitoringSnapshot(
            headline: headline(for: query.variant),
            riskScore: baseScore,
            activeAlerts: Int.random(in: 6...18),
            newAlerts: Int.random(in: 0...6),
            chokepoints: Int.random(in: 1...9),
            macroBias: bias,
            trend: trend(for: query.variant, score: baseScore),
            findings: findings(for: query.region),
            lastRefreshed: .now
        )
    }

    func headlines(for query: FeedQuery) async throws -> [FeedItem] {
        try await Task.sleep(nanoseconds: 150_000_000)

        return [
            FeedItem(
                title: headline(for: query.variant),
                body: "Live intelligence packet received for \(query.region.title.lowercased()) during the last \(query.window.title).",
                severity: 4,
                source: "World Monitor",
                publishedAt: .now.addingTimeInterval(-300)
            ),
            FeedItem(
                title: "Transport corridor strain detected",
                body: "Increased congestion appears across regional logistics hubs and selected ports.",
                severity: 3,
                source: "Signal Index",
                publishedAt: .now.addingTimeInterval(-1_100)
            ),
            FeedItem(
                title: "Sentiment shifts on energy derivatives",
                body: "Derivative positioning suggests elevated volatility in near-term contracts.",
                severity: 2,
                source: "Market Desk",
                publishedAt: .now.addingTimeInterval(-1_900)
            ),
            FeedItem(
                title: "Geopolitical watch alert",
                body: "New reports indicate elevated risk in maritime and border-adjacent routes.",
                severity: 5,
                source: "Field Relay",
                publishedAt: .now.addingTimeInterval(-2_800)
            )
        ]
    }

    private func variantScore(for variant: MonitorVariant, region: RegionPreset) -> Int {
        let base: Int
        switch variant {
        case .world:
            base = 67
        case .tech:
            base = 56
        case .finance:
            base = 71
        case .happy:
            base = 32
        }
        switch region {
        case .global:
            return base
        case .americas, .europe, .mena, .asia, .africa:
            return base + Int.random(in: -4...9)
        }
    }

    private func headline(for variant: MonitorVariant) -> String {
        switch variant {
        case .world:
            "Global operations: multi-domain movement detected"
        case .tech:
            "Technology sector: critical supply chain updates"
        case .finance:
            "Finance risk desk: liquidity and policy sensitivity"
        case .happy:
            "Signal baseline: low-intensity baseline monitoring"
        }
    }

    private func trend(for variant: MonitorVariant, score: Int) -> String {
        if score > 80 {
            return "Escalating"
        } else if score > 60 {
            return "Rising"
        } else if score > 40 {
            return "Stable"
        } else {
            return "Cooling"
        }
    }

    private func findings(for region: RegionPreset) -> [String] {
        switch region {
        case .global:
            [
                "Cross-theater movements rising in eastern corridors",
                "Oil transport and tanker activity above recent average",
                "Public sentiment turning alert in two major capitals"
            ]
        case .americas:
            [
                "Shipping pressure continues at the Panama transshipment lanes",
                "Commodities sentiment softens around energy and metals"
            ]
        case .europe:
            [
                "Aviation activity rerouting has increased around two airports",
                "Grid and cyberwatch signals indicate elevated sensitivity"
            ]
        case .mena:
            [
                "Border security posture shows elevated readiness in northern sectors",
                "Energy chokepoint risk remains above baseline"
            ]
        case .asia:
            [
                "Maritime route density remains volatile in selected straits",
                "Regional logistics delays have increased over the last 24 hours"
            ]
        case .africa:
            [
                "Weather and conflict overlap in transport-critical districts",
                "Food security dispatches increased across two monitoring belts"
            ]
        }
    }
}
