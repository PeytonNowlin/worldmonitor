import Foundation

/// Service for US State Department Travel Advisories
actor TravelAdvisoryService {
    static let shared = TravelAdvisoryService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.usTravelAdvisory
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch all travel advisories
    func fetchAllAdvisories() async throws -> [TravelAdvisory] {
        return try await cache.fetchWithCache(
            source: .usTravelAdvisory,
            maxAge: DataSource.usTravelAdvisory.defaultCacheTTL
        ) {
            // State Department advisories page. The legacy JSON endpoint is currently
            // guarded by anti-bot content; this HTML page remains publicly accessible.
            let url = URL(string: "https://travel.state.gov/content/travel/en/traveladvisories/traveladvisories.html")!
            
            let data = try await self.httpClient.fetchData(url: url, source: .usTravelAdvisory)
            
            return self.parseAdvisories(data)
        }
    }
    
    /// Fetch advisory for specific country
    func fetchAdvisory(countryCode: String) async throws -> TravelAdvisory? {
        let allAdvisories = try await fetchAllAdvisories()
        return allAdvisories.first { $0.countryCode.uppercased() == countryCode.uppercased() }
    }
    
    /// Get high-risk countries (Level 3 and 4)
    func fetchHighRiskCountries() async throws -> [TravelAdvisory] {
        let allAdvisories = try await fetchAllAdvisories()
        return allAdvisories
            .filter { $0.advisoryLevel.isRisky }
            .sorted { $0.advisoryLevel > $1.advisoryLevel }
    }
    
    /// Get Level 4 (Do Not Travel) countries
    func fetchDoNotTravelList() async throws -> [TravelAdvisory] {
        let allAdvisories = try await fetchAllAdvisories()
        return allAdvisories.filter { $0.advisoryLevel == .level4 }
    }
    
    /// Get statistics
    func fetchStats() async throws -> AdvisoryStats {
        let allAdvisories = try await fetchAllAdvisories()
        
        let counts = allAdvisories.reduce(into: [TravelAdvisory.AdvisoryLevel: Int]()) { counts, advisory in
            counts[advisory.advisoryLevel, default: 0] += 1
        }
        
        let highRisk = allAdvisories.filter { $0.advisoryLevel.isRisky }
            .sorted { $0.advisoryLevel > $1.advisoryLevel }
        
        return AdvisoryStats(
            totalCountries: allAdvisories.count,
            level1Count: counts[.level1] ?? 0,
            level2Count: counts[.level2] ?? 0,
            level3Count: counts[.level3] ?? 0,
            level4Count: counts[.level4] ?? 0,
            highRiskCountries: highRisk,
            lastUpdated: Date()
        )
    }
    
    /// Search advisories by country name
    func searchAdvisories(query: String) async throws -> [TravelAdvisory] {
        let allAdvisories = try await fetchAllAdvisories()
        let lowerQuery = query.lowercased()
        
        return allAdvisories.filter { advisory in
            advisory.countryName.lowercased().contains(lowerQuery) ||
            advisory.countryCode.lowercased() == lowerQuery
        }
    }
    
    /// Get advisories by level
    func fetchByLevel(_ level: TravelAdvisory.AdvisoryLevel) async throws -> [TravelAdvisory] {
        let allAdvisories = try await fetchAllAdvisories()
        return allAdvisories.filter { $0.advisoryLevel == level }
    }
    
    // MARK: - Private Methods
    
    private func parseAdvisories(_ data: Data) -> [TravelAdvisory] {
        // Prefer JSON if available, keep parser for backward compatibility.
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return json.compactMap { item -> TravelAdvisory? in
                    guard let countryCode = item["country_code"] as? String ??
                          item["iso3"] as? String,
                          let countryName = item["country_name"] as? String ??
                          item["name"] as? String,
                          let levelInt = item["advisory_level"] as? Int ??
                          item["level"] as? Int else {
                        return nil
                    }
                    
                    let level = TravelAdvisory.AdvisoryLevel(rawValue: levelInt) ?? .level1
                    
                    return TravelAdvisory(
                        countryName: countryName,
                        countryCode: countryCode,
                        advisoryLevel: level,
                        advisoryText: item["advisory_text"] as? String ?? "",
                        lastUpdated: Date(),
                        specificWarnings: item["warnings"] as? [String] ?? [],
                        restrictedAreas: item["restricted_areas"] as? [String]
                    )
                }
            }
        } catch {
            // Fall through to HTML parsing.
        }

        return parseAdvisoriesFromHTML(data)
    }

    private func parseAdvisoriesFromHTML(_ data: Data) -> [TravelAdvisory] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        guard let rowRegex = try? NSRegularExpression(
            pattern: #"<tr[^>]*>(.*?)</tr>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }

        let nsHTML = html as NSString
        let rowMatches = rowRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
        guard !rowMatches.isEmpty else { return [] }

        let countryRegex = try? NSRegularExpression(
            pattern: #"<th[^>]*>\s*<a[^>]*>(.*?)</a>\s*</th>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        let levelRegex = try? NSRegularExpression(
            pattern: #"level-badge-(\d)"#,
            options: [.caseInsensitive]
        )
        let dateRegex = try? NSRegularExpression(
            pattern: #"<td>\s*<p>\s*(\d{2}/\d{2}/\d{4})\s*</p>\s*</td>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        let pillRegex = try? NSRegularExpression(
            pattern: #"<span[^>]*tsg-utility-risk-pill[^>]*>(.*?)</span>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM/dd/yyyy"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let locale = Locale(identifier: "en_US_POSIX")

        return rowMatches.compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            let rowHTML = nsHTML.substring(with: match.range(at: 1))
            let nsRow = rowHTML as NSString
            let rowRange = NSRange(location: 0, length: nsRow.length)

            guard let countryRegex,
                  let countryMatch = countryRegex.firstMatch(in: rowHTML, options: [], range: rowRange),
                  countryMatch.numberOfRanges >= 2 else {
                return nil
            }
            let countryName = cleanHTML(nsRow.substring(with: countryMatch.range(at: 1)))
            guard !countryName.isEmpty else { return nil }

            guard let levelRegex,
                  let levelMatch = levelRegex.firstMatch(in: rowHTML, options: [], range: rowRange),
                  levelMatch.numberOfRanges >= 2 else {
                return nil
            }
            let levelString = nsRow.substring(with: levelMatch.range(at: 1))

            guard let dateRegex,
                  let dateMatch = dateRegex.firstMatch(in: rowHTML, options: [], range: rowRange),
                  dateMatch.numberOfRanges >= 2 else {
                return nil
            }
            let dateString = cleanHTML(nsRow.substring(with: dateMatch.range(at: 1)))

            guard let levelInt = Int(levelString),
                  let level = TravelAdvisory.AdvisoryLevel(rawValue: levelInt) else {
                return nil
            }

            var warnings: [String] = []
            if let pillRegex {
                let warningMatches = pillRegex.matches(
                    in: rowHTML,
                    options: [],
                    range: rowRange
                )
                warnings = warningMatches.compactMap { warningMatch in
                    guard warningMatch.numberOfRanges >= 2 else { return nil }
                    let warning = cleanHTML(nsRow.substring(with: warningMatch.range(at: 1)))
                    return warning.isEmpty ? nil : warning
                }
            }

            let normalizedName = countryName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { return nil }

            let parsedDate = dateFormatter.date(from: dateString) ?? Date()
            let countryCode = resolveCountryCode(for: normalizedName, locale: locale)
            return TravelAdvisory(
                countryName: normalizedName,
                countryCode: countryCode,
                advisoryLevel: level,
                advisoryText: level.description,
                lastUpdated: parsedDate,
                specificWarnings: warnings,
                restrictedAreas: nil
            )
        }
    }

    private func cleanHTML(_ value: String) -> String {
        var cleaned = value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveCountryCode(for countryName: String, locale: Locale) -> String {
        let overrides: [String: String] = [
            "Burma": "MM",
            "Cabo Verde": "CV",
            "Congo, Democratic Republic of the": "CD",
            "Congo, Republic of the": "CG",
            "Cote d'Ivoire": "CI",
            "Korea, North": "KP",
            "Korea, South": "KR",
            "Russia": "RU",
            "Syria": "SY",
            "Venezuela": "VE"
        ]
        if let override = overrides[countryName] {
            return override
        }

        let normalizedTarget = normalize(countryName)
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard let localizedName = locale.localizedString(forRegionCode: code) else { continue }
            if normalize(localizedName) == normalizedTarget {
                return code
            }
        }

        let fallback = countryName.prefix(3).uppercased()
        return fallback.isEmpty ? "UNK" : String(fallback)
    }

    private func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }
}
