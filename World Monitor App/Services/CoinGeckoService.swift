import Foundation

/// Service for CoinGecko cryptocurrency data
actor CoinGeckoService {
    static let shared = CoinGeckoService()
    
    private let httpClient = HTTPClient.shared
    private let cache = CacheManager.shared
    private let config = EndpointConfigurations.coinGecko
    
    // Rate limiter for CoinGecko free tier (~10-30 calls/minute)
    private let rateLimiter = RateLimiter(tokensPerSecond: 0.5, maxTokens: 5)
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch cryptocurrency market data
    func fetchMarketData(
        coins: [CryptoCoin] = CryptoCoin.allCases,
        currency: String = "usd"
    ) async throws -> [CryptoAsset] {
        await rateLimiter.waitForToken()
        
        return try await cache.fetchWithCache(
            source: .coinGecko,
            region: currency,
            maxAge: DataSource.coinGecko.defaultCacheTTL
        ) {
            let ids = coins.map { $0.rawValue }.joined(separator: ",")
            
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ids", value: ids),
                URLQueryItem(name: "vs_currency", value: currency),
                URLQueryItem(name: "order", value: "market_cap_desc"),
                URLQueryItem(name: "per_page", value: "\(coins.count)"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "sparkline", value: "false"),
                URLQueryItem(name: "price_change_percentage", value: "24h")
            ]
            
            var components = URLComponents(
                url: self.config.baseURL.appendingPathComponent("/coins/markets"),
                resolvingAgainstBaseURL: true
            )
            components?.queryItems = queryItems
            
            guard let url = components?.url else {
                throw HTTPClientError.invalidURL
            }
            
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            
            let assets: [CryptoAsset] = try await self.httpClient.fetch(
                url: url,
                source: .coinGecko,
                retries: 3,
                decoder: decoder
            )
            
            return assets
        }
    }
    
    /// Fetch stablecoin peg health
    func fetchStablecoinHealth(currency: String = "usd") async throws -> [StablecoinHealth] {
        await rateLimiter.waitForToken()

        return try await cache.fetchWithCache(
            source: .coinGecko,
            region: "stablecoins_\(currency.lowercased())",
            maxAge: DataSource.coinGecko.defaultCacheTTL
        ) {
            let stablecoins = Stablecoin.allCases
            let ids = stablecoins.map { $0.rawValue }.joined(separator: ",")

            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ids", value: ids),
                URLQueryItem(name: "vs_currency", value: currency),
                URLQueryItem(name: "order", value: "market_cap_desc"),
                URLQueryItem(name: "per_page", value: "\(stablecoins.count)"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "sparkline", value: "false")
            ]

            var components = URLComponents(
                url: self.config.baseURL.appendingPathComponent("/coins/markets"),
                resolvingAgainstBaseURL: true
            )
            components?.queryItems = queryItems

            guard let url = components?.url else {
                throw HTTPClientError.invalidURL
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            let coins: [StablecoinMarketCoin] = try await self.httpClient.fetch(
                url: url,
                source: .coinGecko,
                retries: 3,
                decoder: decoder
            )

            return coins.compactMap { coin in
                guard let currentPrice = coin.currentPrice else { return nil }
                return StablecoinHealth(
                    id: coin.id,
                    symbol: coin.symbol.uppercased(),
                    name: coin.name,
                    pegCurrency: currency.uppercased(),
                    currentPrice: currentPrice,
                    idealPrice: 1.0
                )
            }
        }
    }
    
    /// Fetch global crypto market statistics
    func fetchGlobalStats() async throws -> GlobalCryptoStats {
        await rateLimiter.waitForToken()
        
        let url = config.baseURL.appendingPathComponent("/global")
        
        let data = try await httpClient.fetchData(url: url, source: .coinGecko)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let data = json["data"] as? [String: Any] {
            
            let marketCap = data["total_market_cap"] as? [String: Double]
            let volume = data["total_volume"] as? [String: Double]
            let dominance = data["market_cap_percentage"] as? [String: Double]
            
            return GlobalCryptoStats(
                totalMarketCapUSD: marketCap?["usd"] ?? 0,
                totalVolume24hUSD: volume?["usd"] ?? 0,
                bitcoinDominance: dominance?["btc"] ?? 0,
                ethereumDominance: dominance?["eth"] ?? 0,
                marketCapChange24h: data["market_cap_change_percentage_24h_usd"] as? Double ?? 0,
                activeCryptocurrencies: data["active_cryptocurrencies"] as? Int ?? 0,
                activeMarkets: data["active_markets"] as? Int ?? 0
            )
        }
        
        throw HTTPClientError.decodingError("Failed to parse global stats")
    }
    
    /// Get price for a specific coin
    func fetchPrice(coinId: String, currency: String = "usd") async throws -> Double {
        await rateLimiter.waitForToken()
        
        let url = config.baseURL.appendingPathComponent("/simple/price")
        
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "ids", value: coinId),
            URLQueryItem(name: "vs_currencies", value: currency)
        ]
        
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.queryItems = queryItems
        
        guard let finalURL = components?.url else {
            throw HTTPClientError.invalidURL
        }
        
        let data = try await httpClient.fetchData(url: finalURL, source: .coinGecko)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Double]],
           let coinData = json[coinId],
           let price = coinData[currency] {
            return price
        }
        
        throw HTTPClientError.decodingError("Price not found")
    }
    
    /// Search for coins
    func searchCoins(query: String) async throws -> [CoinSearchResult] {
        await rateLimiter.waitForToken()
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = config.baseURL.appendingPathComponent("/search?query=\(encodedQuery)")
        
        let data = try await httpClient.fetchData(url: url, source: .coinGecko)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let coins = json["coins"] as? [[String: Any]] {
            
            return coins.compactMap { coin in
                guard let id = coin["id"] as? String,
                      let name = coin["name"] as? String,
                      let symbol = coin["symbol"] as? String else {
                    return nil
                }
                
                return CoinSearchResult(
                    id: id,
                    name: name,
                    symbol: symbol.uppercased(),
                    thumb: coin["thumb"] as? String
                )
            }
        }
        
        return []
    }
}

// MARK: - Supporting Types

struct CoinGeckoCoin: Codable {
    let id: String
    let symbol: String
    let name: String
    let currentPrice: Double
    
    enum CodingKeys: String, CodingKey {
        case id
        case symbol
        case name
        case currentPrice = "current_price"
    }
}

private struct StablecoinMarketCoin: Codable {
    let id: String
    let symbol: String
    let name: String
    let currentPrice: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case symbol
        case name
        case currentPrice = "current_price"
    }
}

struct GlobalCryptoStats: Codable {
    let totalMarketCapUSD: Double
    let totalVolume24hUSD: Double
    let bitcoinDominance: Double
    let ethereumDominance: Double
    let marketCapChange24h: Double
    let activeCryptocurrencies: Int
    let activeMarkets: Int
    
    var formattedMarketCap: String {
        formatLargeNumber(totalMarketCapUSD)
    }
    
    var formattedVolume: String {
        formatLargeNumber(totalVolume24hUSD)
    }
}

struct CoinSearchResult: Identifiable, Codable {
    let id: String
    let name: String
    let symbol: String
    let thumb: String?
}

private func formatLargeNumber(_ number: Double) -> String {
    let trillion = 1_000_000_000_000.0
    let billion = 1_000_000_000.0
    let million = 1_000_000.0
    
    if number >= trillion {
        return String(format: "%.2fT", number / trillion)
    } else if number >= billion {
        return String(format: "%.2fB", number / billion)
    } else if number >= million {
        return String(format: "%.2fM", number / million)
    } else {
        return String(format: "%.0f", number)
    }
}
