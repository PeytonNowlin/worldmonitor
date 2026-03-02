import SwiftUI
import Combine
import MapKit

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

    func refresh() async {
        isRefreshing = true
        hasError = false
        defer { isRefreshing = false }

        let query = FeedQuery(variant: selectedVariant, region: selectedRegion, window: selectedWindow)
        async let snapshotTask = try? service.snapshot(for: query)
        async let feedTask = try? service.headlines(for: query)
        async let eventsTask = try? service.naturalEvents(for: query)
        async let militaryTask = try? service.militaryOverview(for: query)

        let fetchedSnapshot = await snapshotTask
        let fetchedFeed = await feedTask
        let fetchedEvents = await eventsTask
        let fetchedMilitary = await militaryTask

        if let fetchedSnapshot {
            self.snapshot = fetchedSnapshot
        }
        if let fetchedFeed, !fetchedFeed.isEmpty {
            self.headlines = fetchedFeed
        }
        if let fetchedEvents {
            self.naturalEvents = fetchedEvents
        }
        if let fetchedMilitary {
            self.militaryOverview = fetchedMilitary
        }

        if fetchedSnapshot == nil, fetchedFeed == nil, fetchedEvents == nil, fetchedMilitary == nil {
            hasError = true
        }
    }

    func startLiveMode() {
        guard !liveEnabled else { return }
        liveEnabled = true
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                await refresh()
            }
        }
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
    @StateObject private var viewModel: DashboardViewModel
    @State private var mapCameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
        )
    )

    init(viewModel: DashboardViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: DashboardViewModel())
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerBar
                        mainSurface(isWide: proxy.size.width > 900)
                        intelligenceStrip
                        liveFeedPanel
                    }
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("World Monitor")
            .task { await viewModel.refresh() }
            .onAppear { viewModel.startLiveMode() }
            .onDisappear { viewModel.stopLiveMode() }
        }
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Global Intelligence Dashboard")
                    .font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)

                    Text("Updated: \(viewModel.snapshot.lastRefreshed.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Picker("Variant", selection: $viewModel.selectedVariant) { ForEach(MonitorVariant.allCases) { variant in
                    Text(variant.title).tag(variant)
                }}
                .pickerStyle(.segmented)
                .onChange(of: viewModel.selectedVariant) { _, value in
                    viewModel.setVariant(value)
                }

                Picker("Region", selection: $viewModel.selectedRegion) {
                    ForEach(RegionPreset.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.selectedRegion) { _, value in
                    viewModel.setRegion(value)
                }

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
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func mainSurface(isWide: Bool) -> some View {
        Group {
            if isWide {
                HStack(alignment: .top, spacing: 12) {
                    mapPanel.frame(maxWidth: .infinity)
                    sidePanelColumn.frame(width: 320)
                }
            } else {
                VStack(spacing: 12) {
                    mapPanel
                    sidePanelColumn
                }
            }
        }
    }

    private var mapPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Interactive World Map")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.layerVisibility.activeLayers.count) Layers Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .bottomLeading) {
                Map(position: $mapCameraPosition) {
                    ForEach(viewModel.naturalEvents) { event in
                        Annotation(event.title, coordinate: event.coordinate) {
                            Circle()
                                .fill(color(for: event))
                                .frame(width: markerSize(for: event), height: markerSize(for: event))
                                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
                        }
                    }
                    if viewModel.layerVisibility.isVisible(.conflictZones) {
                        ForEach(viewModel.militaryOverview.flights) { flight in
                            Annotation(flight.callsign, coordinate: flight.coordinate) {
                                Image(systemName: "airplane.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.red)
                                    .padding(2)
                                    .background(.white.opacity(0.7), in: Circle())
                            }
                        }
                    }
                    if viewModel.layerVisibility.isVisible(.maritimeTraffic) {
                        ForEach(viewModel.militaryOverview.vessels) { vessel in
                            Annotation(vessel.name, coordinate: vessel.coordinate) {
                                Image(systemName: "ferry.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.blue)
                                    .padding(4)
                                    .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.snapshot.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(viewModel.naturalEvents.count) natural | \(viewModel.militaryOverview.flights.count) flights | \(viewModel.militaryOverview.vessels.count) vessels")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
            }
            .frame(height: 320)

            HStack {
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
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                }
            }

            HStack {
                Button("Enable all", action: viewModel.resetLayerDefaults)
                Button("Disable all", action: viewModel.resetLayerState)
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sidePanelColumn: some View {
        VStack(spacing: 10) {
            DashboardCardView(
                title: "Strategic Risk",
                value: "\(viewModel.snapshot.riskScore) / 100",
                trend: viewModel.snapshot.trend,
                color: viewModel.snapshot.riskScore > 70 ? .orange : .green
            )
            DashboardCardView(
                title: "Country Instability Index",
                value: "\(viewModel.snapshot.activeAlerts) Active Alerts",
                trend: "\(viewModel.snapshot.newAlerts) new in \(viewModel.selectedWindow.title)",
                color: .red
            )
            DashboardCardView(
                title: "Infrastructure Cascade",
                value: "\(viewModel.snapshot.chokepoints) Chokepoints",
                trend: "\(viewModel.militaryOverview.basesInView) bases in view",
                color: .yellow
            )
            DashboardCardView(
                title: "Macro Radar",
                value: viewModel.snapshot.macroBias,
                trend: "Last window: \(viewModel.selectedWindow.title)",
                color: .blue
            )
        }
    }

    private var intelligenceStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Intelligence Findings")
                    .font(.headline)
                Spacer()
                if viewModel.isRefreshing {
                    ProgressView().scaleEffect(0.75)
                }
            }

            if viewModel.hasError {
                Text("Live data temporarily unavailable.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.snapshot.findings, id: \.self) { finding in
                        Text(finding)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
