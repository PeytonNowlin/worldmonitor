import Foundation

/// Service for Yahoo Finance market data
actor YahooFinanceService {
    static let shared = YahooFinanceService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.yahooFinance
    
    // Rate limiter for Yahoo Finance (be gentle)
    private let rateLimiter = RateLimiter(tokensPerSecond: 2, maxTokens: 10)
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch quote for a symbol
    func fetchQuote(symbol: String) async throws -> YahooQuote {
        await rateLimiter.waitForToken()
        
        return try await cache.fetchWithCache(
            source: .yahooFinance,
            region: symbol,
            maxAge: DataSource.yahooFinance.defaultCacheTTL
        ) {
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "symbols", value: symbol),
                URLQueryItem(name: "fields", value: "regularMarketPrice,regularMarketChange,regularMarketChangePercent,regularMarketVolume,marketCap,shortName")
            ]
            
            var components = URLComponents(
                url: self.config.baseURL.appendingPathComponent("/finance/chart/\(symbol)"),
                resolvingAgainstBaseURL: true
            )
            components?.queryItems = queryItems
            
            guard let url = components?.url else {
                throw HTTPClientError.invalidURL
            }
            
            // Yahoo uses a different response structure
            let data = try await self.httpClient.fetchData(url: url, source: .yahooFinance)
            
            // Parse Yahoo's specific response format
            // Note: This is a simplified parser - Yahoo's API is complex
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let chart = json["chart"] as? [String: Any],
               let result = chart["result"] as? [[String: Any]],
               let firstResult = result.first,
               let meta = firstResult["meta"] as? [String: Any] {
                
                let price = meta["regularMarketPrice"] as? Double ?? 0
                let previousClose = meta["previousClose"] as? Double ?? price
                let change = price - previousClose
                let changePercent = previousClose > 0 ? (change / previousClose) * 100 : 0
                
                return YahooQuote(
                    symbol: symbol,
                    name: meta["shortName"] as? String ?? symbol,
                    price: price,
                    change: change,
                    changePercent: changePercent,
                    volume: meta["regularMarketVolume"] as? Int64 ?? 0,
                    marketCap: meta["marketCap"] as? Int64,
                    fiftyTwoWeekHigh: meta["fiftyTwoWeekHigh"] as? Double,
                    fiftyTwoWeekLow: meta["fiftyTwoWeekLow"] as? Double,
                    previousClose: previousClose,
                    open: meta["regularMarketOpen"] as? Double ?? previousClose,
                    dayHigh: meta["regularMarketDayHigh"] as? Double,
                    dayLow: meta["regularMarketDayLow"] as? Double,
                    timestamp: Date()
                )
            }
            
            throw HTTPClientError.decodingError("Failed to parse Yahoo Finance response")
        }
    }
    
    /// Fetch quotes for multiple symbols with staggered requests
    func fetchQuotes(symbols: [String]) async throws -> [YahooQuote] {
        var quotes: [YahooQuote] = []
        
        // Stagger requests to avoid rate limiting
        for symbol in symbols {
            do {
                let quote = try await fetchQuote(symbol: symbol)
                quotes.append(quote)
                // Small delay between requests
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            } catch {
                // Skip failed symbols but continue
                continue
            }
        }
        
        return quotes
    }
    
    /// Fetch major market indices
    func fetchMajorIndices() async throws -> [YahooQuote] {
        let indices: [MarketIndex] = [.sp500, .nasdaq, .dowJones, .vix]
        return try await fetchQuotes(symbols: indices.map { $0.rawValue })
    }
    
    /// Fetch international indices
    func fetchInternationalIndices() async throws -> [YahooQuote] {
        let indices: [MarketIndex] = [.ftse100, .dax, .cac40, .nikkei, .hangSeng]
        return try await fetchQuotes(symbols: indices.map { $0.rawValue })
    }
    
    /// Fetch Gulf market indices
    func fetchGulfIndices() async throws -> [YahooQuote] {
        let indices: [MarketIndex] = [.tadawul, .dubai, .abuDhabi, .qatar]
        return try await fetchQuotes(symbols: indices.map { $0.rawValue })
    }
    
    /// Fetch chart data for a symbol
    func fetchChart(symbol: String, range: ChartRange = .oneMonth) async throws -> YahooChart {
        await rateLimiter.waitForToken()
        
        let interval: String
        switch range {
        case .oneDay: interval = "1m"
        case .oneWeek: interval = "5m"
        case .oneMonth: interval = "30m"
        case .threeMonths: interval = "1h"
        case .sixMonths: interval = "1d"
        case .oneYear: interval = "1d"
        case .fiveYears: interval = "1wk"
        }
        
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "range", value: range.rawValue)
        ]
        
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("/finance/chart/\(symbol)"),
            resolvingAgainstBaseURL: true
        )
        components?.queryItems = queryItems
        
        guard let url = components?.url else {
            throw HTTPClientError.invalidURL
        }
        
        let data = try await httpClient.fetchData(url: url, source: .yahooFinance)
        
        // Parse chart data
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let chart = json["chart"] as? [String: Any],
           let result = chart["result"] as? [[String: Any]],
           let firstResult = result.first {
            
            let timestamps = (firstResult["timestamp"] as? [Int] ?? []).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            
            if let indicators = firstResult["indicators"] as? [String: Any],
               let quote = indicators["quote"] as? [[String: Any]],
               let quoteData = quote.first {
                
                let opens = quoteData["open"] as? [Double] ?? []
                let highs = quoteData["high"] as? [Double] ?? []
                let lows = quoteData["low"] as? [Double] ?? []
                let closes = quoteData["close"] as? [Double] ?? []
                let volumes = (quoteData["volume"] as? [Int] ?? []).map { Int64($0) }
                
                return YahooChart(
                    symbol: symbol,
                    timestamps: timestamps,
                    opens: opens,
                    highs: highs,
                    lows: lows,
                    closes: closes,
                    volumes: volumes
                )
            }
        }
        
        throw HTTPClientError.decodingError("Failed to parse chart data")
    }
    
    /// Search for stocks by query
    func search(query: String) async throws -> [StockSearchResult] {
        await rateLimiter.waitForToken()
        
        let url = URL(string: "https://query2.finance.yahoo.com/v1/finance/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&lang=en-US&region=US&quotesCount=10&newsCount=0")!
        
        let data = try await httpClient.fetchData(url: url, source: .yahooFinance)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let quotes = json["quotes"] as? [[String: Any]] {
            
            return quotes.compactMap { quote in
                guard let symbol = quote["symbol"] as? String,
                      let name = quote["shortname"] as? String ?? quote["longname"] as? String else {
                    return nil
                }
                
                return StockSearchResult(
                    symbol: symbol,
                    name: name,
                    exchange: quote["exchange"] as? String,
                    sector: quote["sector"] as? String
                )
            }
        }
        
        return []
    }
}

// MARK: - Supporting Types

enum ChartRange: String {
    case oneDay = "1d"
    case oneWeek = "5d"
    case oneMonth = "1mo"
    case threeMonths = "3mo"
    case sixMonths = "6mo"
    case oneYear = "1y"
    case fiveYears = "5y"
}

struct StockSearchResult: Identifiable, Codable {
    var id = UUID()
    let symbol: String
    let name: String
    let exchange: String?
    let sector: String?
}
