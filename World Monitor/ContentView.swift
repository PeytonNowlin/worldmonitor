import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var selectedVariant: MonitorVariant = .world
    @Published var selectedRegion: RegionPreset = .global
    @Published var selectedWindow: TimeWindow = .twentyFourHours
    @Published var snapshot: MonitoringSnapshot = .empty
    @Published var headlines: [FeedItem] = []
    @Published var layerVisibility: LayerVisibilityState = LayerVisibilityState()
    @Published var isRefreshing = false
    @Published var hasError = false
    @Published var liveEnabled = false

    private let service: WorldMonitorService
    private var tickerTask: Task<Void, Never>?

    init(service: WorldMonitorService = MockWorldMonitorService.shared) {
        self.service = service
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

        do {
            let query = FeedQuery(variant: selectedVariant, region: selectedRegion, window: selectedWindow)
            async let snapshot = service.snapshot(for: query)
            async let feed = service.headlines(for: query)
            let fetched = try await (snapshot, feed)
            self.snapshot = fetched.0
            self.headlines = fetched.1
        } catch {
            hasError = true
            self.snapshot = .empty
            self.headlines = []
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

    init(viewModel: DashboardViewModel = DashboardViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
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

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.black.opacity(0.75), .blue.opacity(0.5), .teal.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 10) {
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 52))
                    Text(viewModel.snapshot.headline)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal)
                    Text("Map overlays update based on selected filters")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding()
            }
            .frame(height: 300)

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
                trend: viewModel.snapshot.macroBias,
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
