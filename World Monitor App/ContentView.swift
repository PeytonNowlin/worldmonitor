import SwiftUI
import Combine
import MapKit

enum AppRefreshRate: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .oneMinute: return "1 Minute"
        case .fiveMinutes: return "5 Minutes"
        case .tenMinutes: return "10 Minutes"
        }
    }
}

enum DashboardSection: String, CaseIterable {
    case core
    case conflictSecurity
    case cyberThreats
    case market
    case infrastructure
    case travelSafety

    var title: String {
        switch self {
        case .core:
            "Core"
        case .conflictSecurity:
            "Conflict"
        case .cyberThreats:
            "Cyber"
        case .market:
            "Market"
        case .infrastructure:
            "Infrastructure"
        case .travelSafety:
            "Travel"
        }
    }
}

enum DashboardSectionLoadState: String {
    case idle
    case stale
    case refreshing
    case fresh
    case failed

    var color: Color {
        switch self {
        case .idle:
            return .secondary
        case .stale:
            return .orange
        case .refreshing:
            return .blue
        case .fresh:
            return .green
        case .failed:
            return .red
        }
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var selectedVariant: MonitorVariant = .world
    @Published var selectedRegion: RegionPreset = .global
    @Published var selectedWindow: TimeWindow = .twentyFourHours
    @Published var snapshot: MonitoringSnapshot = .empty
    @Published var headlines: [FeedItem] = []
    @Published var layerVisibility: LayerVisibilityState = LayerVisibilityState()
    @Published var naturalEvents: [NaturalEvent] = []
    @Published var militaryOverview: MilitaryOverview = .empty
    @Published var isRefreshing = false
    @Published var hasError = false
    @Published var liveEnabled = false
    @Published var sectionLoadState: [DashboardSection: DashboardSectionLoadState] = Dictionary(
        uniqueKeysWithValues: DashboardSection.allCases.map { ($0, .idle) }
    )
    @Published var isManualRefreshDisabled = false

    // Track individual data source failures for partial error detection
    @Published var snapshotFailed = false
    @Published var headlinesFailed = false
    @Published var naturalEventsFailed = false
    @Published var militaryOverviewFailed = false
    @Published var cyberIntelFailed = false
    @Published var marketDataFailed = false
    @Published var travelSafetyFailed = false

    // MARK: - Conflict & Security Data
    // MARK: - Military Data
    @Published var militaryBases: [MilitaryBase] = []

    // MARK: - Cyber Threat Data
    @Published var c2Servers: [FeodoC2Server] = []

    // MARK: - Market Data
    @Published var marketIndices: [YahooQuote] = []
    @Published var cryptoAssets: [CryptoAsset] = []
    @Published var fearGreed: FearGreedIndex?
    @Published var policyRates: [BISPolicyRate] = []
    @Published var bitcoinHashrate: BitcoinHashrate?

    // MARK: - Infrastructure Data
    @Published var internetConnectivity: [CloudflareRadarData] = []
    @Published var displacementData: [DisplacementData] = []

    // MARK: - Travel & Safety Data
    @Published var travelAdvisories: [TravelAdvisory] = []

    // MARK: - New Layer Visibility
    @Published var showCyberThreats: Bool = false
    @Published var showMilitaryBases: Bool = false

    private struct CacheKey: Hashable {
        let bucket: String
        let context: String
    }

    private struct CacheEntry {
        let fetchedAt: Date
        let payload: Any
    }

    private static let coreFreshnessWindow: TimeInterval = 5
    private static let backgroundFreshnessWindow: TimeInterval = 30
    private var cacheByKey: [CacheKey: CacheEntry] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshVersion = 0

    // Visible map region for viewport culling
    @Published var visibleMapRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
    )

    // Performance limits
    private let maxVisibleFlights = 100
    private let maxVisibleVessels = 50
    private let maxVisibleEvents = 50

    // Filtered military data based on visible region with limits
    var visibleFlights: [MilitaryFlightSignal] {
        guard !militaryOverview.flights.isEmpty else { return [] }
        let visible = militaryOverview.flights.filter { flight in
            visibleMapRegion.contains(flight.coordinate)
        }
        // Prioritize by altitude (higher = more significant) and limit
        return visible.sorted { $0.altitude > $1.altitude }.prefix(maxVisibleFlights).map { $0 }
    }

    var visibleVessels: [MilitaryVesselSignal] {
        guard !militaryOverview.vessels.isEmpty else { return [] }
        let visible = militaryOverview.vessels.filter { vessel in
            visibleMapRegion.contains(vessel.coordinate)
        }
        // Limit vessels to prevent map clutter
        return visible.prefix(maxVisibleVessels).map { $0 }
    }

    var visibleNaturalEvents: [NaturalEvent] {
        guard !naturalEvents.isEmpty else { return [] }
        let visible = naturalEvents.filter { event in
            visibleMapRegion.contains(event.coordinate)
        }
        // Prioritize by severity and limit
        return visible.sorted { $0.severity > $1.severity }.prefix(maxVisibleEvents).map { $0 }
    }

    var visibleMilitaryBases: [MilitaryBase] {
        guard !militaryBases.isEmpty else { return [] }
        return militaryBases.filter { base in
            visibleMapRegion.contains(base.coordinate)
        }
    }

    var visibleC2Servers: [FeodoC2Server] {
        guard !c2Servers.isEmpty else { return [] }
        // Filter to high/critical severity servers for map display
        // (exact coordinates not available, will display at country center)
        return c2Servers.filter { $0.severity >= .high }.prefix(50).map { $0 }
    }

    private let service: WorldMonitorService
    private var tickerTask: Task<Void, Never>?

    init(service: WorldMonitorService) {
        self.service = service
    }

    init() {
        self.service = LiveWorldMonitorService.shared
    }

    func setVariant(_ variant: MonitorVariant) {
        selectedVariant = variant
        Task { await refresh() }
    }

    func setRegion(_ region: RegionPreset) {
        selectedRegion = region
        Task { await refresh() }
    }

    func setWindow(_ window: TimeWindow) {
        selectedWindow = window
        Task { await refresh() }
    }

    func triggerManualRefresh() {
        guard !isManualRefreshDisabled else { return }
        isManualRefreshDisabled = true
        Task { await refresh() }
        Task {
            try? await Task.sleep(for: .seconds(120))
            await MainActor.run {
                self.isManualRefreshDisabled = false
            }
        }
    }

    func refresh() async {
        refreshVersion += 1
        let version = refreshVersion
        refreshTask?.cancel()

        isRefreshing = true
        sectionLoadState = Dictionary(uniqueKeysWithValues: DashboardSection.allCases.map { ($0, .refreshing) })
        hasError = false
        snapshotFailed = false
        headlinesFailed = false
        naturalEventsFailed = false
        militaryOverviewFailed = false
        cyberIntelFailed = false
        marketDataFailed = false
        travelSafetyFailed = false

        refreshTask = Task { [weak self] in
            await self?.performRefresh(version: version)
        }
    }

    func cancelRefreshes() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        for section in DashboardSection.allCases {
            sectionLoadState[section] = .idle
        }
    }

    private func performRefresh(version: Int) async {
        defer {
            let stillCurrent = isCurrentVersion(version)
            if stillCurrent {
                isRefreshing = false
                refreshTask = nil
            } else {
                // Reset section states to idle when task becomes stale or is cancelled
                for section in DashboardSection.allCases {
                    if sectionLoadState[section] == .refreshing {
                        sectionLoadState[section] = .idle
                    }
                }
            }
        }

        guard isCurrentVersion(version) else { return }

        let query = FeedQuery(variant: selectedVariant, region: selectedRegion, window: selectedWindow)
        let cacheContext = cacheContext(for: query)

        guard !Task.isCancelled, isCurrentVersion(version) else { return }

        let coreBuckets = ["snapshot", "headlines", "naturalEvents", "militaryOverview"]
        let conflictBuckets = ["militaryBases"]
        let cyberBuckets = ["c2Servers"]
        let marketBuckets = ["marketIndices", "cryptoAssets", "fearGreed", "policyRates", "bitcoinHashrate"]
        let infrastructureBuckets = ["connectivity", "displacement"]
        let travelBuckets = ["advisories"]

        let shouldRefreshCore = !hasAllSectionCache(buckets: coreBuckets, context: cacheContext, maxAge: Self.coreFreshnessWindow)
        let shouldRefreshConflictSecurity = !hasAllSectionCache(
            buckets: conflictBuckets,
            context: cacheContext,
            maxAge: Self.backgroundFreshnessWindow
        )
        let shouldRefreshCyber = !hasAllSectionCache(
            buckets: cyberBuckets,
            context: cacheContext,
            maxAge: Self.backgroundFreshnessWindow
        )
        let shouldRefreshMarket = !hasAllSectionCache(
            buckets: marketBuckets,
            context: cacheContext,
            maxAge: Self.backgroundFreshnessWindow
        )
        let shouldRefreshInfrastructure = !hasAllSectionCache(
            buckets: infrastructureBuckets,
            context: cacheContext,
            maxAge: Self.backgroundFreshnessWindow
        )
        let shouldRefreshTravelSafety = !hasAllSectionCache(
            buckets: travelBuckets,
            context: cacheContext,
            maxAge: Self.backgroundFreshnessWindow
        )

        if let cachedSnapshot: MonitoringSnapshot = readCached(bucket: "snapshot", context: cacheContext, maxAge: Self.coreFreshnessWindow) {
            snapshot = cachedSnapshot
        }
        if let cachedHeadlines: [FeedItem] = readCached(bucket: "headlines", context: cacheContext, maxAge: Self.coreFreshnessWindow),
           !cachedHeadlines.isEmpty {
            headlines = cachedHeadlines
        }
        if let cachedNaturalEvents: [NaturalEvent] = readCached(bucket: "naturalEvents", context: cacheContext, maxAge: Self.coreFreshnessWindow) {
            naturalEvents = cachedNaturalEvents
        }
        if let cachedMilitary: MilitaryOverview = readCached(bucket: "militaryOverview", context: cacheContext, maxAge: Self.coreFreshnessWindow) {
            militaryOverview = cachedMilitary
        }
        if let cachedMilitaryBases: [MilitaryBase] = readCached(bucket: "militaryBases", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            militaryBases = cachedMilitaryBases
        }
        if let cachedC2Servers: [FeodoC2Server] = readCached(bucket: "c2Servers", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            c2Servers = cachedC2Servers
        }
        if let cachedMarketIndices: [YahooQuote] = readCached(bucket: "marketIndices", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            marketIndices = cachedMarketIndices
        }
        if let cachedCryptoAssets: [CryptoAsset] = readCached(bucket: "cryptoAssets", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            cryptoAssets = cachedCryptoAssets
        }
        if let cachedFearGreed: FearGreedIndex = readCached(bucket: "fearGreed", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            fearGreed = cachedFearGreed
        }
        if let cachedPolicyRates: [BISPolicyRate] = readCached(bucket: "policyRates", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            policyRates = cachedPolicyRates
        }
        if let cachedBitcoinHashrate: BitcoinHashrate = readCached(bucket: "bitcoinHashrate", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            bitcoinHashrate = cachedBitcoinHashrate
        }
        if let cachedConnectivity: [CloudflareRadarData] = readCached(bucket: "connectivity", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            internetConnectivity = cachedConnectivity
        }
        if let cachedDisplacement: [DisplacementData] = readCached(bucket: "displacement", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            displacementData = cachedDisplacement
        }
        if let cachedAdvisories: [TravelAdvisory] = readCached(bucket: "advisories", context: cacheContext, maxAge: Self.backgroundFreshnessWindow) {
            travelAdvisories = cachedAdvisories
        }

        sectionLoadState[.core] = shouldRefreshCore
            ? (hasAnySectionCache(buckets: coreBuckets, context: cacheContext, maxAge: Self.coreFreshnessWindow) ? .stale : .refreshing)
            : .fresh
        sectionLoadState[.conflictSecurity] = shouldRefreshConflictSecurity
            ? (hasAnySectionCache(buckets: conflictBuckets, context: cacheContext, maxAge: Self.backgroundFreshnessWindow) ? .stale : .refreshing)
            : .fresh
        sectionLoadState[.cyberThreats] = shouldRefreshCyber
            ? (hasAnySectionCache(buckets: cyberBuckets, context: cacheContext, maxAge: Self.backgroundFreshnessWindow) ? .stale : .refreshing)
            : .fresh
        sectionLoadState[.market] = shouldRefreshMarket
            ? (hasAnySectionCache(buckets: marketBuckets, context: cacheContext, maxAge: Self.backgroundFreshnessWindow) ? .stale : .refreshing)
            : .fresh
        sectionLoadState[.infrastructure] = shouldRefreshInfrastructure
            ? (hasAnySectionCache(buckets: infrastructureBuckets, context: cacheContext, maxAge: Self.backgroundFreshnessWindow) ? .stale : .refreshing)
            : .fresh
        sectionLoadState[.travelSafety] = shouldRefreshTravelSafety
            ? (hasAnySectionCache(buckets: travelBuckets, context: cacheContext, maxAge: Self.backgroundFreshnessWindow) ? .stale : .refreshing)
            : .fresh

        if !(
            shouldRefreshCore ||
            shouldRefreshConflictSecurity ||
            shouldRefreshCyber ||
            shouldRefreshMarket ||
            shouldRefreshInfrastructure ||
            shouldRefreshTravelSafety
        ) {
            return
        }

        if shouldRefreshCore {
            sectionLoadState[.core] = .refreshing
            async let snapshotTask: MonitoringSnapshot? = safeCall { try await self.service.snapshot(for: query) }
            async let feedTask: [FeedItem]? = safeCall { try await self.service.headlines(for: query) }
            async let eventsTask: [NaturalEvent]? = safeCall { try await self.service.naturalEvents(for: query) }
            async let militaryTask: MilitaryOverview? = safeCall { try await self.service.militaryOverview(for: query) }

            let fetchedSnapshot = await snapshotTask
            let fetchedFeed = await feedTask
            let fetchedEvents = await eventsTask
            let fetchedMilitary = await militaryTask

            if Task.isCancelled || !isCurrentVersion(version) { return }

            let newSnapshotFailed = fetchedSnapshot == nil
            let newHeadlinesFailed = fetchedFeed == nil
            let newNaturalEventsFailed = fetchedEvents == nil
            let newMilitaryOverviewFailed = fetchedMilitary == nil

            // Final guard before mutating state: ensure we're still the current version
            guard isCurrentVersion(version) else { return }

            snapshotFailed = newSnapshotFailed
            headlinesFailed = newHeadlinesFailed
            naturalEventsFailed = newNaturalEventsFailed
            militaryOverviewFailed = newMilitaryOverviewFailed
            hasError = newSnapshotFailed || newHeadlinesFailed || newNaturalEventsFailed || newMilitaryOverviewFailed

            if let fetchedSnapshot {
                snapshot = fetchedSnapshot
                writeCache(bucket: "snapshot", context: cacheContext, value: fetchedSnapshot)
            }
            if let fetchedHeadlines = fetchedFeed, !fetchedHeadlines.isEmpty {
                headlines = fetchedHeadlines
                writeCache(bucket: "headlines", context: cacheContext, value: fetchedHeadlines)
            }
            if let fetchedEvents {
                naturalEvents = fetchedEvents
                writeCache(bucket: "naturalEvents", context: cacheContext, value: fetchedEvents)
            }
            if let fetchedMilitary {
                militaryOverview = fetchedMilitary
                writeCache(bucket: "militaryOverview", context: cacheContext, value: fetchedMilitary)
            }
            sectionLoadState[.core] = hasError ? .failed : .fresh
        }

        if shouldRefreshConflictSecurity {
            sectionLoadState[.conflictSecurity] = .refreshing
            async let basesTask: [MilitaryBase]? = safeCall { await self.service.militaryBases(for: self.selectedRegion) }
            let fetchedBases = await basesTask
            if !isCurrentVersion(version) || Task.isCancelled { return }

            // Final guard before mutating state: ensure we're still the current version
            guard isCurrentVersion(version) else { return }

            if let fetchedBases {
                militaryBases = fetchedBases
                writeCache(bucket: "militaryBases", context: cacheContext, value: fetchedBases)
            }
            let conflictSecurityFailed = fetchedBases?.isEmpty ?? true
            sectionLoadState[.conflictSecurity] = conflictSecurityFailed ? .failed : .fresh
        }

        if shouldRefreshCyber {
            sectionLoadState[.cyberThreats] = .refreshing
            async let c2Task: [FeodoC2Server]? = safeCall { try await self.service.c2Servers() }

            let fetchedC2 = await c2Task
            if !isCurrentVersion(version) || Task.isCancelled { return }

            let newCyberIntelFailed = fetchedC2 == nil

            // Final guard before mutating state: ensure we're still the current version
            guard isCurrentVersion(version) else { return }

            cyberIntelFailed = newCyberIntelFailed
            if let fetchedC2 {
                c2Servers = fetchedC2
                writeCache(bucket: "c2Servers", context: cacheContext, value: fetchedC2)
            }
            sectionLoadState[.cyberThreats] = newCyberIntelFailed ? .failed : .fresh
        }

        if shouldRefreshMarket {
            sectionLoadState[.market] = .refreshing
            async let indicesTask: [YahooQuote]? = safeCall { try await self.service.marketQuotes(indices: [.sp500, .nasdaq, .vix]) }
            async let cryptoTask: [CryptoAsset]? = safeCall { try await self.service.cryptoAssets(coins: [.bitcoin, .ethereum, .solana]) }
            let fetchedIndices = await indicesTask
            let fetchedCrypto = await cryptoTask
            if !isCurrentVersion(version) || Task.isCancelled { return }

            async let fearGreedTask: FearGreedIndex? = safeCall { try await self.service.fearGreedIndex() }
            let fetchedFearGreed = await fearGreedTask
            if !isCurrentVersion(version) || Task.isCancelled { return }

            async let policyRatesTask: [BISPolicyRate]? = safeCall { try await self.service.policyRates() }
            async let hashrateTask: BitcoinHashrate? = safeCall { try await self.service.bitcoinHashrate() }
            let fetchedPolicyRates = await policyRatesTask
            let fetchedHashrate = await hashrateTask
            if !isCurrentVersion(version) || Task.isCancelled { return }

            let hasIndices = !(fetchedIndices?.isEmpty ?? true)
            let hasCrypto = !(fetchedCrypto?.isEmpty ?? true)
            let newMarketDataFailed = !hasIndices && !hasCrypto

            // Final guard before mutating state: ensure we're still the current version
            guard isCurrentVersion(version) else { return }

            marketDataFailed = newMarketDataFailed

            if let fetchedIndices {
                marketIndices = fetchedIndices
                writeCache(bucket: "marketIndices", context: cacheContext, value: fetchedIndices)
            }
            if let fetchedCrypto {
                cryptoAssets = fetchedCrypto
                writeCache(bucket: "cryptoAssets", context: cacheContext, value: fetchedCrypto)
            }
            if let fetchedFearGreed {
                fearGreed = fetchedFearGreed
                writeCache(bucket: "fearGreed", context: cacheContext, value: fetchedFearGreed)
            }
            if let fetchedPolicyRates {
                policyRates = fetchedPolicyRates
                writeCache(bucket: "policyRates", context: cacheContext, value: fetchedPolicyRates)
            }
            if let fetchedHashrate {
                bitcoinHashrate = fetchedHashrate
                writeCache(bucket: "bitcoinHashrate", context: cacheContext, value: fetchedHashrate)
            }
            sectionLoadState[.market] = marketDataFailed ? .failed : .fresh
        }

        if shouldRefreshInfrastructure {
            sectionLoadState[.infrastructure] = .refreshing
            async let connectivityTask: [CloudflareRadarData]? = safeCall { try await self.service.internetConnectivity() }
            async let displacementTask: [DisplacementData]? = safeCall { try await self.service.displacementData() }
            let fetchedConnectivity = await connectivityTask
            let fetchedDisplacement = await displacementTask
            if !isCurrentVersion(version) || Task.isCancelled { return }

            if let fetchedConnectivity {
                internetConnectivity = fetchedConnectivity
                writeCache(bucket: "connectivity", context: cacheContext, value: fetchedConnectivity)
            }
            if let fetchedDisplacement {
                displacementData = fetchedDisplacement
                writeCache(bucket: "displacement", context: cacheContext, value: fetchedDisplacement)
            }
            sectionLoadState[.infrastructure] = (fetchedConnectivity == nil && fetchedDisplacement == nil) ? .failed : .fresh
        }

        if shouldRefreshTravelSafety {
            sectionLoadState[.travelSafety] = .refreshing
            async let advisoriesTask: [TravelAdvisory]? = safeCall { try await self.service.travelAdvisories() }
            let fetchedAdvisories = await advisoriesTask
            if !isCurrentVersion(version) || Task.isCancelled { return }

            let newTravelSafetyFailed = fetchedAdvisories == nil || fetchedAdvisories?.isEmpty == true

            // Final guard before mutating state: ensure we're still the current version
            guard isCurrentVersion(version) else { return }

            travelSafetyFailed = newTravelSafetyFailed
            if let fetchedAdvisories {
                travelAdvisories = fetchedAdvisories
                writeCache(bucket: "advisories", context: cacheContext, value: fetchedAdvisories)
            }
            sectionLoadState[.travelSafety] = newTravelSafetyFailed ? .failed : .fresh
        }

        if snapshotFailed && headlinesFailed && naturalEventsFailed && militaryOverviewFailed {
            snapshot = .empty
            headlines = []
            naturalEvents = []
            militaryOverview = .empty
            sectionLoadState[.core] = .failed
        }
    }

    private func isCurrentVersion(_ version: Int) -> Bool {
        refreshVersion == version && refreshTask != nil
    }

    private func cacheContext(for query: FeedQuery) -> String {
        "\(query.variant)-\(query.region)-\(query.window)"
    }

    private func makeCacheKey(bucket: String, context: String) -> CacheKey {
        CacheKey(bucket: bucket, context: context)
    }

    private func hasAnySectionCache(buckets: [String], context: String, maxAge: TimeInterval) -> Bool {
        buckets.contains { bucket in
            let key = makeCacheKey(bucket: bucket, context: context)
            guard let entry = cacheByKey[key] else { return false }
            return Date().timeIntervalSince(entry.fetchedAt) <= maxAge
        }
    }

    private func hasAllSectionCache(buckets: [String], context: String, maxAge: TimeInterval) -> Bool {
        buckets.allSatisfy { bucket in
            let key = makeCacheKey(bucket: bucket, context: context)
            guard let entry = cacheByKey[key] else { return false }
            return Date().timeIntervalSince(entry.fetchedAt) <= maxAge
        }
    }

    private func writeCache<T>(bucket: String, context: String, value: T) {
        cacheByKey[makeCacheKey(bucket: bucket, context: context)] = CacheEntry(
            fetchedAt: .now,
            payload: value
        )
    }

    private func readCached<T>(bucket: String, context: String, maxAge: TimeInterval) -> T? {
        let key = makeCacheKey(bucket: bucket, context: context)
        guard let entry = cacheByKey[key] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) <= maxAge else {
            cacheByKey.removeValue(forKey: key)
            return nil
        }
        return entry.payload as? T
    }

    private func safeCall<T>(_ operation: @escaping () async throws -> T) async -> T? {
        do {
            return try await operation()
        } catch {
            return nil
        }
    }

    private var currentRefreshRate: AppRefreshRate {
        let rawValue = UserDefaults.standard.integer(forKey: "appRefreshRate")
        return AppRefreshRate(rawValue: rawValue) ?? .oneMinute
    }

    func restartTicker() {
        tickerTask?.cancel()
        if !liveEnabled { return }
        tickerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.currentRefreshRate.rawValue))
                if Task.isCancelled { return }
                await refresh()
            }
        }
    }

    func startLiveMode() {
        guard !liveEnabled else { return }
        liveEnabled = true
        restartTicker()
    }

    func stopLiveMode() {
        liveEnabled = false
        tickerTask?.cancel()
        tickerTask = nil
    }

    func toggleLayer(_ layer: MapLayer) {
        layerVisibility.toggle(layer)
    }

    func resetLayerDefaults() {
        layerVisibility.enableAll()
    }

    func resetLayerState() {
        layerVisibility.disableAll()
    }
}

struct DashboardCardView: View {
    let title: String
    let value: String
    let trend: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
            Text(trend)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ContentView: View {
    private enum MapSelection: Identifiable {
        case flight(MilitaryFlightSignal)
        case vessel(MilitaryVesselSignal)

        var id: String {
            switch self {
            case .flight(let flight):
                return "flight-\(flight.id)"
            case .vessel(let vessel):
                return "vessel-\(vessel.id)"
            }
        }
    }

    @StateObject private var viewModel: DashboardViewModel
    @State private var mapCameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
        )
    )
    @State private var selectedTab = 0
    @State private var selectedMapTarget: MapSelection?

    init(viewModel: DashboardViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: DashboardViewModel())
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            dashboardTab
                .tabItem {
                    Label("Dashboard", systemImage: "chart.xyaxis.line")
                }
                .tag(0)

            mapTab
                .tabItem {
                    Label("Map", systemImage: "map")
                }
                .tag(1)
                
            SettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .task { await viewModel.refresh() }
        .onAppear { viewModel.startLiveMode() }
        .onDisappear {
            viewModel.cancelRefreshes()
            viewModel.stopLiveMode()
        }
        .sheet(item: $selectedMapTarget) { target in
            mapTargetDetailSheet(for: target)
                .presentationDetents([.height(280), .medium])
        }
    }

    private var dashboardTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerBar
                    sidePanelColumn
                    intelligenceStrip
                    liveFeedPanel
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("World Monitor")
        }
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Global Intelligence Dashboard")
                    .font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    Button(action: {
                        viewModel.triggerManualRefresh()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(viewModel.isManualRefreshDisabled ? Color.gray.opacity(0.15) : Color.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(viewModel.isManualRefreshDisabled ? Color.gray : Color.blue)
                    }
                    .disabled(viewModel.isManualRefreshDisabled || viewModel.isRefreshing)

                    Text("Updated: \(viewModel.snapshot.lastRefreshed.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                Picker("Variant", selection: $viewModel.selectedVariant) { ForEach(MonitorVariant.allCases) { variant in
                    Text(variant.title).tag(variant)
                }}
                .pickerStyle(.segmented)
                .onChange(of: viewModel.selectedVariant) { _, value in
                    viewModel.setVariant(value)
                }

                HStack(spacing: 10) {
                    Picker("Region", selection: $viewModel.selectedRegion) {
                        ForEach(RegionPreset.allCases) { region in
                            Text(region.title).tag(region)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: viewModel.selectedRegion) { _, value in
                        viewModel.setRegion(value)
                    }

                    Spacer()

                    Picker("Window", selection: $viewModel.selectedWindow) {
                        ForEach(TimeWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: viewModel.selectedWindow) { _, value in
                        viewModel.setWindow(value)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var mapTab: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $mapCameraPosition) {
                    ForEach(viewModel.visibleNaturalEvents) { event in
                        Annotation(event.title, coordinate: event.coordinate) {
                            Circle()
                                .fill(color(for: event))
                                .frame(width: markerSize(for: event), height: markerSize(for: event))
                                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
                        }
                    }
                    if viewModel.layerVisibility.isVisible(.conflictZones) {
                        ForEach(viewModel.visibleFlights) { flight in
                            Annotation(flight.callsign, coordinate: flight.coordinate) {
                                Button {
                                    selectedMapTarget = .flight(flight)
                                } label: {
                                    Image(systemName: "airplane.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.red)
                                        .padding(2)
                                        .background(.white.opacity(0.7), in: Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if viewModel.layerVisibility.isVisible(.maritimeTraffic) {
                        ForEach(viewModel.visibleVessels) { vessel in
                            Annotation(vessel.name, coordinate: vessel.coordinate) {
                                Button {
                                    selectedMapTarget = .vessel(vessel)
                                } label: {
                                    Image(systemName: "ferry.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.blue)
                                        .padding(4)
                                        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if viewModel.showMilitaryBases {
                        ForEach(viewModel.visibleMilitaryBases) { base in
                            Annotation(base.name, coordinate: base.coordinate) {
                                Image(systemName: base.type.icon)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.purple)
                                    .background(.white.opacity(0.8), in: Circle())
                            }
                        }
                    }
                    if viewModel.showCyberThreats {
                        ForEach(viewModel.visibleC2Servers) { server in
                            if let coordinate = countryCoordinate(for: server.countryCode) {
                                Annotation(server.ipAddress, coordinate: coordinate) {
                                    Image(systemName: "server.rack")
                                        .font(.system(size: 12))
                                        .foregroundStyle(c2ServerColor(for: server))
                                        .background(.white.opacity(0.8), in: Circle())
                                }
                            }
                        }
                    }
                }
                .onMapCameraChange { context in
                    viewModel.visibleMapRegion = context.region
                }

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.snapshot.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text("\(viewModel.visibleNaturalEvents.count)/\(viewModel.naturalEvents.count) natural | \(viewModel.visibleFlights.count)/\(viewModel.militaryOverview.flights.count) flights | \(viewModel.visibleVessels.count)/\(viewModel.militaryOverview.vessels.count) vessels | \(viewModel.visibleMilitaryBases.count) bases | \(viewModel.visibleC2Servers.count) C2s")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                    VStack(spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(MapLayer.allCases) { layer in
                                    Button {
                                        viewModel.toggleLayer(layer)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(viewModel.layerVisibility.isVisible(layer) ? layer.tint : Color.secondary)
                                                .frame(width: 8, height: 8)
                                            Text(layer.title)
                                                .font(.caption2)
                                                .lineLimit(1)
                                        }
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(viewModel.layerVisibility.isVisible(layer) ? layer.tint.opacity(0.15) : Color(.secondarySystemBackground), in: Capsule())
                                    }
                                }

                                Button {
                                    viewModel.showMilitaryBases.toggle()
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(viewModel.showMilitaryBases ? .purple : Color.secondary)
                                            .frame(width: 8, height: 8)
                                        Text("Bases")
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(viewModel.showMilitaryBases ? Color.purple.opacity(0.15) : Color(.secondarySystemBackground), in: Capsule())
                                }

                                Button {
                                    viewModel.showCyberThreats.toggle()
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(viewModel.showCyberThreats ? .red : Color.secondary)
                                            .frame(width: 8, height: 8)
                                        Text("Cyber")
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(viewModel.showCyberThreats ? Color.red.opacity(0.15) : Color(.secondarySystemBackground), in: Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 14)

                        HStack {
                            Button("Enable all", action: viewModel.resetLayerDefaults)
                            Button("Disable all", action: viewModel.resetLayerState)
                            Spacer()
                            Text("\(viewModel.layerVisibility.activeLayers.count) Layers Active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 14)
                    }
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Global Map")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var sidePanelColumn: some View {
        VStack(spacing: 10) {
            // Original cards (compact)
            HStack(spacing: 8) {
                CompactDashboardCard(
                    title: "Risk",
                    value: "\(viewModel.snapshot.riskScore)",
                    trend: viewModel.snapshot.trend,
                    color: viewModel.snapshot.riskScore > 70 ? .orange : .green
                )
                CompactDashboardCard(
                    title: "Alerts",
                    value: "\(viewModel.snapshot.activeAlerts)",
                    trend: "+\(viewModel.snapshot.newAlerts)",
                    color: .red
                )
            }

            // New panels
            marketDataPanel
            cyberThreatPanel
            travelSafetyPanel
        }
    }

    private var intelligenceStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Intelligence Findings")
                    .font(.headline)
                Spacer()
                if viewModel.isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.75)
                        Text("Refreshing")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(DashboardSection.allCases, id: \.self) { section in
                        if let state = viewModel.sectionLoadState[section],
                           state == .stale || state == .refreshing || state == .failed {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(state.color)
                                    .frame(width: 6, height: 6)
                                
                                Text(section.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(state.color)
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(state.color.opacity(0.15), in: Capsule())
                            .overlay(
                                Capsule().stroke(state.color.opacity(0.3), lineWidth: 0.5)
                            )
                        }
                    }
                }
            }

            let anyError = viewModel.hasError || viewModel.cyberIntelFailed || viewModel.marketDataFailed || viewModel.travelSafetyFailed
            if anyError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live data partially unavailable.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if viewModel.snapshotFailed {
                                Label("Snapshot", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if viewModel.headlinesFailed {
                                Label("Headlines", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if viewModel.naturalEventsFailed {
                                Label("Events", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if viewModel.militaryOverviewFailed {
                                Label("Military", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if viewModel.cyberIntelFailed {
                                Label("Cyber", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if viewModel.marketDataFailed {
                                Label("Market", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if viewModel.travelSafetyFailed {
                                Label("Travel", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.snapshot.findings, id: \.self) { finding in
                        Text(finding)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - New Dashboard Panels

    private var marketDataPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Market Intelligence")
                    .font(.headline)
                Spacer()
                if let fearGreed = viewModel.fearGreed {
                    Label(fearGreed.classification.rawValue, systemImage: "gauge.with.dots.needle")
                        .font(.caption)
                        .foregroundStyle(fearGreedColor(fearGreed.classification))
                }
            }

            // Market Indices
            HStack(spacing: 12) {
                ForEach(viewModel.marketIndices.prefix(3)) { quote in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quote.symbol)
                            .font(.caption2.weight(.semibold))
                        Text(String(format: "%.2f", quote.price))
                            .font(.subheadline.monospaced())
                        Text(String(format: "%+.2f%%", quote.changePercent))
                            .font(.caption2)
                            .foregroundStyle(quote.isPositive ? .green : .red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            // Crypto Assets
            HStack(spacing: 12) {
                ForEach(viewModel.cryptoAssets.prefix(3)) { asset in
                    HStack(spacing: 4) {
                        Text(asset.symbol.uppercased())
                            .font(.caption2.weight(.semibold))
                        Text(String(format: "%.2f", asset.currentPrice))
                            .font(.caption.monospaced())
                        Text(String(format: "%+.1f%%", asset.priceChangePercentage24h))
                            .font(.caption2)
                            .foregroundStyle(asset.isPositive ? .green : .red)
                    }
                }
            }

            Divider()

            // Major Policy Rates
            VStack(alignment: .leading, spacing: 6) {
                Text("Major Central Bank Policy Rates")
                    .font(.caption.weight(.semibold))

                if viewModel.policyRates.isEmpty {
                    Text("Policy rate data pending")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.policyRates.prefix(8)) { rate in
                        HStack {
                            Text(rate.countryName)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.2f%%", rate.rate))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                            if let change = rate.rateChange {
                                Text(String(format: "%+.2f", change))
                                    .font(.caption2)
                                    .foregroundStyle(change >= 0 ? .green : .red)
                            }
                        }
                    }
                }
            }

            Divider()

            // Bitcoin Hashrate
            if let hashrate = viewModel.bitcoinHashrate {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bitcoin Network")
                        .font(.caption.weight(.semibold))

                    HStack {
                        Text("Hashrate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f EH/s", hashrate.currentHashrate))
                            .font(.caption2.monospaced())
                    }

                    HStack {
                        Text("Difficulty")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f", hashrate.currentDifficulty))
                            .font(.caption2.monospaced())
                            .foregroundStyle(hashrateColor(hashrate.difficultyChange))
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var cyberThreatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cyber Threat Intel")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.c2Servers.count) C2s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // C2 Server Summary
            HStack(spacing: 16) {
                ThreatStatBadge(
                    icon: "server.rack",
                    count: viewModel.c2Servers.count,
                    label: "C2 Servers",
                    color: .red
                )
            }

            Divider()

            // Top Malware Families
            if !viewModel.c2Servers.isEmpty {
                let families = Dictionary(grouping: viewModel.c2Servers) { $0.malwareFamily }
                    .mapValues { $0.count }
                    .sorted { $0.value > $1.value }
                    .prefix(3)

                ForEach(Array(families), id: \.key) { family, count in
                    HStack {
                        Circle()
                            .fill(.red.opacity(0.7))
                            .frame(width: 6, height: 6)
                        Text(family)
                            .font(.caption)
                        Spacer()
                        Text("\(count) servers")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !viewModel.cyberIntelFailed {
                Label("No active high-risk C2 servers", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var travelSafetyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Travel & Safety")
                    .font(.headline)
                Spacer()
                let highRisk = viewModel.travelAdvisories.filter { $0.advisoryLevel.isRisky }.count
                if highRisk > 0 {
                    Label("\(highRisk) High Risk", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // Do Not Travel Countries
            let doNotTravel = viewModel.travelAdvisories.filter { $0.advisoryLevel == .level4 }
            if !doNotTravel.isEmpty {
                Text("Do Not Travel: \(doNotTravel.prefix(3).map { $0.countryCode }.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !viewModel.travelSafetyFailed {
                Label("No new 'Do Not Travel' advisories.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Helper Views

    struct ThreatStatBadge: View {
        let icon: String
        let count: Int
        let label: String
        let color: Color

        var body: some View {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text("\(count)")
                    .font(.headline)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    struct CompactDashboardCard: View {
        let title: String
        let value: String
        let trend: String
        let color: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                Text(trend)
                    .font(.caption2)
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Helper Functions

    private func fearGreedColor(_ classification: FearGreedClassification) -> Color {
        switch classification {
        case .extremeFear: return .red
        case .fear: return .orange
        case .neutral: return .gray
        case .greed: return .green
        case .extremeGreed: return .green
        }
    }

    private func hashrateColor(_ change: Double) -> Color {
        if change >= 0 {
            return .green
        }
        return .red
    }

    private func color(for event: NaturalEvent) -> Color {
        switch event.severity {
        case 5:
            return .red
        case 4:
            return .orange
        case 3:
            return .yellow
        default:
            return .blue
        }
    }

    private func markerSize(for event: NaturalEvent) -> CGFloat {
        switch event.severity {
        case 5:
            return 16
        case 4:
            return 13
        case 3:
            return 11
        default:
            return 9
        }
    }

    @ViewBuilder
    private func mapTargetDetailSheet(for target: MapSelection) -> some View {
        switch target {
        case .flight(let flight):
            mapEntityDetailCard(
                title: flight.callsign.isEmpty ? "Unknown Callsign" : flight.callsign,
                systemImage: "airplane",
                tint: .red,
                rows: [
                    ("ICAO", flight.id.uppercased()),
                    ("Altitude", "\(Int(flight.altitude.rounded())) m"),
                    ("Speed", "\(Int(flight.speed.rounded())) m/s"),
                    ("Last Seen", flight.lastSeenAt.formatted(date: .abbreviated, time: .shortened)),
                    ("Latitude", String(format: "%.4f", flight.latitude)),
                    ("Longitude", String(format: "%.4f", flight.longitude))
                ]
            )
        case .vessel(let vessel):
            mapEntityDetailCard(
                title: vessel.name,
                systemImage: "ferry.fill",
                tint: .blue,
                rows: [
                    ("ID", vessel.id),
                    ("Type", vessel.vesselType.isEmpty ? "Unknown" : vessel.vesselType),
                    ("Region", vessel.region.isEmpty ? "Unknown" : vessel.region),
                    ("Latitude", String(format: "%.4f", vessel.latitude)),
                    ("Longitude", String(format: "%.4f", vessel.longitude))
                ]
            )
        }
    }

    private func mapEntityDetailCard(
        title: String,
        systemImage: String,
        tint: Color,
        rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }

            ForEach(rows, id: \.0) { key, value in
                HStack {
                    Text(key)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(value)
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - C2 Server Helpers
    private func c2ServerColor(for server: FeodoC2Server) -> Color {
        switch server.severity {
        case .critical:
            return .red
        case .high:
            return .orange
        case .medium:
            return .yellow
        case .low:
            return .green
        }
    }

    private func countryCoordinate(for countryCode: String?) -> CLLocationCoordinate2D? {
        guard let code = countryCode?.uppercased() else { return nil }
        // Approximate country centers for major countries with C2 activity
        let coordinates: [String: CLLocationCoordinate2D] = [
            "US": CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
            "CN": CLLocationCoordinate2D(latitude: 35.8617, longitude: 104.1954),
            "RU": CLLocationCoordinate2D(latitude: 61.5240, longitude: 105.3188),
            "DE": CLLocationCoordinate2D(latitude: 51.1657, longitude: 10.4515),
            "NL": CLLocationCoordinate2D(latitude: 52.1326, longitude: 5.2913),
            "GB": CLLocationCoordinate2D(latitude: 55.3781, longitude: -3.4360),
            "FR": CLLocationCoordinate2D(latitude: 46.2276, longitude: 2.2137),
            "BR": CLLocationCoordinate2D(latitude: -14.2350, longitude: -51.9253),
            "IN": CLLocationCoordinate2D(latitude: 20.5937, longitude: 78.9629),
            "JP": CLLocationCoordinate2D(latitude: 36.2048, longitude: 138.2529),
            "CA": CLLocationCoordinate2D(latitude: 56.1304, longitude: -106.3468),
            "AU": CLLocationCoordinate2D(latitude: -25.2744, longitude: 133.7751),
            "KR": CLLocationCoordinate2D(latitude: 35.9078, longitude: 127.7669),
            "IT": CLLocationCoordinate2D(latitude: 41.8719, longitude: 12.5674),
            "SG": CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198),
            "HK": CLLocationCoordinate2D(latitude: 22.3193, longitude: 114.1694),
            "UA": CLLocationCoordinate2D(latitude: 48.3794, longitude: 31.1656),
            "RO": CLLocationCoordinate2D(latitude: 45.9432, longitude: 24.9668),
            "PL": CLLocationCoordinate2D(latitude: 51.9194, longitude: 19.1451),
            "CZ": CLLocationCoordinate2D(latitude: 49.8175, longitude: 15.4730),
            "BG": CLLocationCoordinate2D(latitude: 42.7339, longitude: 25.4858),
            "HU": CLLocationCoordinate2D(latitude: 47.1625, longitude: 19.5033),
            "AT": CLLocationCoordinate2D(latitude: 47.5162, longitude: 14.5501),
            "CH": CLLocationCoordinate2D(latitude: 46.8182, longitude: 8.2275),
            "SE": CLLocationCoordinate2D(latitude: 60.1282, longitude: 18.6435),
            "NO": CLLocationCoordinate2D(latitude: 60.4720, longitude: 8.4689),
            "FI": CLLocationCoordinate2D(latitude: 61.9241, longitude: 25.7482),
            "DK": CLLocationCoordinate2D(latitude: 56.2639, longitude: 9.5018),
            "ES": CLLocationCoordinate2D(latitude: 40.4637, longitude: -3.7492),
            "PT": CLLocationCoordinate2D(latitude: 39.3999, longitude: -8.2245),
            "BE": CLLocationCoordinate2D(latitude: 50.5039, longitude: 4.4699),
            "IE": CLLocationCoordinate2D(latitude: 53.1424, longitude: -7.6921),
            "TR": CLLocationCoordinate2D(latitude: 38.9637, longitude: 35.2433),
            "IL": CLLocationCoordinate2D(latitude: 31.0461, longitude: 34.8516),
            "SA": CLLocationCoordinate2D(latitude: 23.8859, longitude: 45.0792),
            "AE": CLLocationCoordinate2D(latitude: 23.4241, longitude: 53.8478),
            "ZA": CLLocationCoordinate2D(latitude: -30.5595, longitude: 22.9375),
            "NG": CLLocationCoordinate2D(latitude: 9.0820, longitude: 8.6753),
            "EG": CLLocationCoordinate2D(latitude: 26.0975, longitude: 30.8178),
            "ID": CLLocationCoordinate2D(latitude: -0.7893, longitude: 113.9213),
            "TH": CLLocationCoordinate2D(latitude: 15.8700, longitude: 100.9925),
            "VN": CLLocationCoordinate2D(latitude: 14.0583, longitude: 108.2772),
            "MY": CLLocationCoordinate2D(latitude: 4.2105, longitude: 101.9758),
            "PH": CLLocationCoordinate2D(latitude: 12.8797, longitude: 121.7740),
            "MX": CLLocationCoordinate2D(latitude: 23.6345, longitude: -102.5528),
            "AR": CLLocationCoordinate2D(latitude: -38.4161, longitude: -63.6167),
            "CL": CLLocationCoordinate2D(latitude: -35.6751, longitude: -71.5430),
            "CO": CLLocationCoordinate2D(latitude: 4.5709, longitude: -74.2973),
            "PE": CLLocationCoordinate2D(latitude: -9.1900, longitude: -75.0152),
            "VE": CLLocationCoordinate2D(latitude: 6.4238, longitude: -66.5897),
            "PK": CLLocationCoordinate2D(latitude: 30.3753, longitude: 69.3451),
            "BD": CLLocationCoordinate2D(latitude: 23.6850, longitude: 90.3563),
            "TW": CLLocationCoordinate2D(latitude: 23.6978, longitude: 120.9605),
            "KZ": CLLocationCoordinate2D(latitude: 48.0196, longitude: 66.9237),
            "IR": CLLocationCoordinate2D(latitude: 32.4279, longitude: 53.6880),
            "IQ": CLLocationCoordinate2D(latitude: 33.2232, longitude: 43.6793),
            "SY": CLLocationCoordinate2D(latitude: 34.8021, longitude: 38.9968),
            "AF": CLLocationCoordinate2D(latitude: 33.9391, longitude: 67.7100),
            "MM": CLLocationCoordinate2D(latitude: 21.9139, longitude: 95.9560),
            "KP": CLLocationCoordinate2D(latitude: 40.3399, longitude: 127.5101),
            "BY": CLLocationCoordinate2D(latitude: 53.7098, longitude: 27.9534),
            "MD": CLLocationCoordinate2D(latitude: 47.4116, longitude: 28.3699),
            "GE": CLLocationCoordinate2D(latitude: 42.3154, longitude: 43.3569),
            "AM": CLLocationCoordinate2D(latitude: 40.0691, longitude: 45.0382),
            "AZ": CLLocationCoordinate2D(latitude: 40.1431, longitude: 47.5769),
            "LT": CLLocationCoordinate2D(latitude: 55.1694, longitude: 23.8813),
            "LV": CLLocationCoordinate2D(latitude: 56.8796, longitude: 24.6032),
            "EE": CLLocationCoordinate2D(latitude: 58.5953, longitude: 25.0136),
            "SK": CLLocationCoordinate2D(latitude: 48.6690, longitude: 19.6990),
            "SI": CLLocationCoordinate2D(latitude: 46.1512, longitude: 14.9955),
            "HR": CLLocationCoordinate2D(latitude: 45.1000, longitude: 15.2000),
            "RS": CLLocationCoordinate2D(latitude: 44.0165, longitude: 21.0059),
            "BA": CLLocationCoordinate2D(latitude: 43.9159, longitude: 17.6791),
            "MK": CLLocationCoordinate2D(latitude: 41.6086, longitude: 21.7453),
            "AL": CLLocationCoordinate2D(latitude: 41.1533, longitude: 20.1683),
            "GR": CLLocationCoordinate2D(latitude: 39.0742, longitude: 21.8243),
            "CY": CLLocationCoordinate2D(latitude: 35.1264, longitude: 33.4299),
            "MT": CLLocationCoordinate2D(latitude: 35.9375, longitude: 14.3754),
            "IS": CLLocationCoordinate2D(latitude: 64.9631, longitude: -19.0208),
            "NZ": CLLocationCoordinate2D(latitude: -40.9006, longitude: 174.8869)
        ]
        return coordinates[code]
    }

    private var liveFeedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live News Feed")
                .font(.headline)

            ForEach(viewModel.headlines) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(item.severity > 3 ? .red : .orange)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.subheadline)
                        Text(item.body)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SettingsView: View {
    @AppStorage("appRefreshRate") private var refreshRate: AppRefreshRate = .oneMinute
    @AppStorage("appTheme") private var appTheme: AppTheme = .dark
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("App Preferences"), footer: Text("Adjusting the refresh rate will change how often data is updated in live mode.")) {
                    Picker("Theme", selection: $appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }

                    Picker("Refresh Rate", selection: $refreshRate) {
                        ForEach(AppRefreshRate.allCases) { rate in
                            Text(rate.title).tag(rate)
                        }
                    }
                    .onChange(of: refreshRate) { _, _ in
                        viewModel.restartTicker()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - MKCoordinateRegion Extensions

extension MKCoordinateRegion {
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let north = center.latitude + span.latitudeDelta / 2
        let south = center.latitude - span.latitudeDelta / 2
        let east = center.longitude + span.longitudeDelta / 2
        let west = center.longitude - span.longitudeDelta / 2

        // Handle longitude wrapping around the antimeridian
        var normalizedEast = east
        var normalizedWest = west
        var normalizedLon = coordinate.longitude

        if east > 180 || west < -180 {
            // Region crosses antimeridian
            if coordinate.longitude < 0 {
                normalizedLon = coordinate.longitude + 360
            }
            if east < 0 {
                normalizedEast = east + 360
            }
            if west < 0 {
                normalizedWest = west + 360
            }
        }

        return coordinate.latitude >= south && coordinate.latitude <= north &&
               normalizedLon >= normalizedWest && normalizedLon <= normalizedEast
    }
}
