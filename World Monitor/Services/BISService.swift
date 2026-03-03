import Foundation

/// Service for BIS (Bank for International Settlements) data
actor BISService {
    static let shared = BISService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.bis
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch policy rates for major economies
    func fetchPolicyRates() async throws -> [BISPolicyRate] {
        return try await cache.fetchWithCache(
            source: .bis,
            region: "policy-rates",
            maxAge: DataSource.bis.defaultCacheTTL
        ) {
            let countries = ["US", "XM", "JP", "GB", "CH", "AU", "CA", "SE", "NO", "NZ"].joined(separator: "+")
            let path = "/data/WS_CBPOL/M.\(countries)"
            var components = URLComponents(url: self.config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
            components?.queryItems = [
                URLQueryItem(name: "format", value: "csv"),
                URLQueryItem(name: "detail", value: "dataonly")
            ]
            guard let url = components?.url else {
                throw HTTPClientError.invalidURL
            }
            
            let data = try await self.httpClient.fetchData(url: url, source: .bis)
            
            // Parse BIS response (simplified)
            return self.parsePolicyRates(data)
        }
    }
    
    /// Fetch Real Effective Exchange Rates (REER)
    func fetchREER() async throws -> [BISREER] {
        return try await cache.fetchWithCache(
            source: .bis,
            region: "reer",
            maxAge: DataSource.bis.defaultCacheTTL
        ) {
            let url = config.baseURL.appendingPathComponent("/data/WS_REER/all/latest")
            
            let data = try await httpClient.fetchData(url: url, source: .bis)
            
            return self.parseREER(data)
        }
    }
    
    /// Get major central bank rates
    func fetchMajorCentralBankRates() async throws -> [BISPolicyRate] {
        let majorBanks = [
            ("US", "United States"),
            ("XM", "Euro Area"),
            ("JP", "Japan"),
            ("GB", "United Kingdom"),
            ("CH", "Switzerland"),
            ("AU", "Australia"),
            ("CA", "Canada"),
            ("SE", "Sweden"),
            ("NO", "Norway"),
            ("NZ", "New Zealand")
        ]
        let allRates = try await fetchPolicyRates()
        
        // Filter to major banks
        return allRates.filter { rate in
            majorBanks.contains { $0.0 == rate.countryCode }
        }.sorted { $0.rate > $1.rate }
    }
    
    /// Get summary statistics
    func fetchStats() async throws -> BISStats {
        let rates = try await fetchPolicyRates()
        let reer = try await fetchREER()
        
        let avgRate = rates.map { $0.rate }.reduce(0, +) / Double(rates.count)
        let negativeRateCountries = rates.filter { $0.rate < 0 }.count
        let hikingRates = rates.filter { ($0.rateChange ?? 0) > 0 }.count
        let cuttingRates = rates.filter { ($0.rateChange ?? 0) < 0 }.count
        
        let appreciating = reer.filter { $0.change12M > 5 }.count
        let depreciating = reer.filter { $0.change12M < -5 }.count
        
        return BISStats(
            countriesWithData: rates.count,
            averagePolicyRate: avgRate,
            negativeRateCountries: negativeRateCountries,
            countriesHikingRates: hikingRates,
            countriesCuttingRates: cuttingRates,
            appreciatingCurrencies: appreciating,
            depreciatingCurrencies: depreciating,
            lastUpdated: Date()
        )
    }
    
    // MARK: - Private Methods
    
    private func parsePolicyRates(_ data: Data) -> [BISPolicyRate] {
        guard let csv = String(data: data, encoding: .utf8) else {
            return []
        }
        
        let lines = csv
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard lines.count > 1 else { return [] }
        
        let header = csvColumns(from: lines[0])
        guard let refAreaIndex = header.firstIndex(of: "REF_AREA") ?? header.firstIndex(of: "Reference area"),
              let timeIndex = header.firstIndex(of: "TIME_PERIOD") ?? header.firstIndex(of: "Time period"),
              let valueIndex = header.firstIndex(of: "OBS_VALUE") ?? header.firstIndex(of: "Observation value") else {
            return []
        }
        
        var observations: [String: [(date: String, value: Double)]] = [:]
        for row in lines.dropFirst() {
            let columns = csvColumns(from: row)
            guard columns.count > max(refAreaIndex, timeIndex, valueIndex) else { continue }
            
            let code = columns[refAreaIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let date = columns[timeIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, !date.isEmpty, let value = Double(columns[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            observations[code, default: []].append((date: date, value: value))
        }
        
        return observations.compactMap { (code, values) in
            let sorted = values.sorted { $0.date < $1.date }
            guard let latest = sorted.last else { return nil }
            let previous = sorted.dropLast().last
            let countryName = bisCountryName(for: code)
            if countryName == nil { return nil }
            
            return BISPolicyRate(
                countryCode: code,
                countryName: countryName ?? code,
                rate: latest.value,
                rateChange: previous.map { latest.value - $0.value },
                effectiveDate: parseDate(latest.date) ?? Date(),
                frequency: "monthly"
            )
        }
    }
    
    private func parseREER(_ data: Data) -> [BISREER] {
        // Simplified parsing
        return []
    }
    
    private func bisCountryName(for code: String) -> String? {
        switch code {
        case "US":
            return "United States"
        case "XM":
            return "Euro Area"
        case "JP":
            return "Japan"
        case "GB":
            return "United Kingdom"
        case "CH":
            return "Switzerland"
        case "AU":
            return "Australia"
        case "CA":
            return "Canada"
        case "SE":
            return "Sweden"
        case "NO":
            return "Norway"
        case "NZ":
            return "New Zealand"
        default:
            return nil
        }
    }
    
    private func parseDate(_ value: String) -> Date? {
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.calendar = Calendar(identifier: .gregorian)
        monthFormatter.dateFormat = "yyyy-MM"
        if let monthDate = monthFormatter.date(from: value) {
            return monthDate
        }
        
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return dayFormatter.date(from: value)
    }
    
    private func csvColumns(from line: String) -> [String] {
        var columns: [String] = []
        var current = ""
        var inQuotes = false
        
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                columns.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll(keepingCapacity: false)
            } else {
                current.append(char)
            }
        }
        
        columns.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        
        return columns.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }
}

// MARK: - Statistics Model

struct BISStats: Codable {
    let countriesWithData: Int
    let averagePolicyRate: Double
    let negativeRateCountries: Int
    let countriesHikingRates: Int
    let countriesCuttingRates: Int
    let appreciatingCurrencies: Int
    let depreciatingCurrencies: Int
    let lastUpdated: Date
}
