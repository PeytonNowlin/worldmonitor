import Foundation

// MARK: - Yahoo Finance Models

/// Market quote from Yahoo Finance
struct YahooQuote: Identifiable, Codable {
    let id: String // Symbol
    let symbol: String
    let name: String
    let price: Double
    let change: Double
    let changePercent: Double
    let volume: Int64
    let marketCap: Int64?
    let fiftyTwoWeekHigh: Double?
    let fiftyTwoWeekLow: Double?
    let previousClose: Double
    let open: Double
    let dayHigh: Double?
    let dayLow: Double?
    let timestamp: Date
    
    var id: String { symbol }
    
    var isPositive: Bool {
        change >= 0
    }
    
    enum CodingKeys: String, CodingKey {
        case symbol
        case name = "shortName"
        case price = "regularMarketPrice"
        case change = "regularMarketChange"
        case changePercent = "regularMarketChangePercent"
        case volume = "regularMarketVolume"
        case marketCap
        case fiftyTwoWeekHigh
        case fiftyTwoWeekLow
        case previousClose = "regularMarketPreviousClose"
        case open = "regularMarketOpen"
        case dayHigh = "regularMarketDayHigh"
        case dayLow = "regularMarketDayLow"
        case timestamp
    }
}

/// Chart data from Yahoo Finance
struct YahooChart: Codable {
    let symbol: String
    let timestamps: [Date]
    let opens: [Double]
    let highs: [Double]
    let lows: [Double]
    let closes: [Double]
    let volumes: [Int64]
    
    /// Calculate simple moving average
    func calculateSMA(period: Int) -> [Double] {
        guard period > 0 && closes.count >= period else { return [] }
        
        var sma: [Double] = []
        for i in (period - 1)..<closes.count {
            let sum = closes[(i - period + 1)...i].reduce(0, +)
            sma.append(sum / Double(period))
        }
        return sma
    }
}

/// Market index definitions
enum MarketIndex: String, CaseIterable {
    case sp500 = "^GSPC"
    case nasdaq = "^IXIC"
    case dowJones = "^DJI"
    case russell2000 = "^RUT"
    case vix = "^VIX"
    
    // International
    case ftse100 = "^FTSE"
    case dax = "^GDAXI"
    case cac40 = "^FCHI"
    case nikkei = "^N225"
    case hangSeng = "^HSI"
    case shanghai = "000001.SS"
    
    // Gulf Markets
    case tadawul = "^TASI"
    case dubai = "^DFMGI"
    case abuDhabi = "^FTFADGI"
    case qatar = "^QE Index"
    
    var displayName: String {
        switch self {
        case .sp500: return "S&P 500"
        case .nasdaq: return "NASDAQ"
        case .dowJones: return "Dow Jones"
        case .russell2000: return "Russell 2000"
        case .vix: return "VIX (Volatility)"
        case .ftse100: return "FTSE 100"
        case .dax: return "DAX"
        case .cac40: return "CAC 40"
        case .nikkei: return "Nikkei 225"
        case .hangSeng: return "Hang Seng"
        case .shanghai: return "Shanghai Composite"
        case .tadawul: return "Tadawul (Saudi)"
        case .dubai: return "DFM (Dubai)"
        case .abuDhabi: return "ADX (Abu Dhabi)"
        case .qatar: return "QE (Qatar)"
        }
    }
    
    var region: String {
        switch self {
        case .sp500, .nasdaq, .dowJones, .russell2000, .vix:
            return "Americas"
        case .ftse100, .dax, .cac40:
            return "Europe"
        case .nikkei, .hangSeng, .shanghai:
            return "Asia-Pacific"
        case .tadawul, .dubai, .abuDhabi, .qatar:
            return "Gulf"
        }
    }
}

// MARK: - CoinGecko Models

/// Cryptocurrency data from CoinGecko
struct CryptoAsset: Identifiable, Codable {
    let id: String
    let symbol: String
    let name: String
    let currentPrice: Double
    let priceChange24h: Double
    let priceChangePercentage24h: Double
    let marketCap: Double
    let volume24h: Double
    let circulatingSupply: Double
    let totalSupply: Double?
    let maxSupply: Double?
    let ath: Double // All-time high
    let athChangePercentage: Double
    let athDate: Date
    let lastUpdated: Date
    
    var isPositive: Bool {
        priceChange24h >= 0
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case symbol
        case name
        case currentPrice = "current_price"
        case priceChange24h = "price_change_24h"
        case priceChangePercentage24h = "price_change_percentage_24h"
        case marketCap = "market_cap"
        case volume24h = "total_volume"
        case circulatingSupply = "circulating_supply"
        case totalSupply = "total_supply"
        case maxSupply = "max_supply"
        case ath
        case athChangePercentage = "ath_change_percentage"
        case athDate = "ath_date"
        case lastUpdated = "last_updated"
    }
}

/// Stablecoin health data
struct StablecoinHealth: Identifiable, Codable {
    let id: String
    let symbol: String
    let name: String
    let pegCurrency: String
    let currentPrice: Double
    let idealPrice: Double
    var deviation: Double {
        abs(currentPrice - idealPrice) / idealPrice * 100
    }
    var status: StablecoinStatus {
        if deviation <= 0.5 {
            return .onPeg
        } else if deviation <= 1.0 {
            return .slightDepeg
        } else {
            return .depegged
        }
    }
    
    enum StablecoinStatus: String {
        case onPeg = "On Peg"
        case slightDepeg = "Slight Depeg"
        case depegged = "Depegged"
        
        var color: String {
            switch self {
            case .onPeg: return "green"
            case .slightDepeg: return "yellow"
            case .depegged: return "red"
            }
        }
    }
}

/// Popular crypto coins
enum CryptoCoin: String, CaseIterable {
    case bitcoin = "bitcoin"
    case ethereum = "ethereum"
    case solana = "solana"
    case xrp = "ripple"
    case cardano = "cardano"
    case polkadot = "polkadot"
    case dogecoin = "dogecoin"
    case chainlink = "chainlink"
    case polygon = "matic-network"
    case avalanche = "avalanche-2"
    
    var symbol: String {
        switch self {
        case .bitcoin: return "BTC"
        case .ethereum: return "ETH"
        case .solana: return "SOL"
        case .xrp: return "XRP"
        case .cardano: return "ADA"
        case .polkadot: return "DOT"
        case .dogecoin: return "DOGE"
        case .chainlink: return "LINK"
        case .polygon: return "MATIC"
        case .avalanche: return "AVAX"
        }
    }
    
    var displayName: String {
        switch self {
        case .bitcoin: return "Bitcoin"
        case .ethereum: return "Ethereum"
        case .solana: return "Solana"
        case .xrp: return "XRP"
        case .cardano: return "Cardano"
        case .polkadot: return "Polkadot"
        case .dogecoin: return "Dogecoin"
        case .chainlink: return "Chainlink"
        case .polygon: return "Polygon"
        case .avalanche: return "Avalanche"
        }
    }
}

/// Stablecoins to monitor
enum Stablecoin: String, CaseIterable {
    case tether = "tether"
    case usdc = "usd-coin"
    case dai = "dai"
    case fdusd = "first-digital-usd"
    case usde = "ethena-usde"
    
    var symbol: String {
        switch self {
        case .tether: return "USDT"
        case .usdc: return "USDC"
        case .dai: return "DAI"
        case .fdusd: return "FDUSD"
        case .usde: return "USDe"
        }
    }
    
    var targetPeg: Double {
        1.0 // All pegged to USD
    }
}

// MARK: - BIS Models

/// BIS (Bank for International Settlements) policy rate
struct BISPolicyRate: Identifiable, Codable {
    let id: String // Country code
    let countryCode: String
    let countryName: String
    let rate: Double // Current policy rate
    let rateChange: Double? // Change from previous
    let effectiveDate: Date
    let frequency: String // Monthly, quarterly, etc.
    
    var isPositiveRate: Bool {
        rate > 0
    }
    
    var id: String { countryCode }
}

/// BIS Real Effective Exchange Rate
struct BISREER: Identifiable, Codable {
    let id: String
    let countryCode: String
    let countryName: String
    let value: Double // Index value (base = 100)
    let change1M: Double
    let change12M: Double
    let date: Date
    
    var id: String { countryCode }
    
    var trend: REERTrend {
        if change12M > 5 {
            return .appreciating
        } else if change12M < -5 {
            return .depreciating
        } else {
            return .stable
        }
    }
    
    enum REERTrend: String {
        case appreciating = "Appreciating"
        case stable = "Stable"
        case depreciating = "Depreciating"
    }
}

// MARK: - Fear & Greed Models

/// Fear and Greed Index from Alternative.me
struct FearGreedIndex: Codable {
    let value: Int // 0-100
    let valueClassification: String
    let timestamp: Date
    let updateTimestamp: Date
    
    var classification: FearGreedClassification {
        FearGreedClassification(rawValue: valueClassification) ?? .neutral
    }
    
    var id: String { timestamp.description }
}

enum FearGreedClassification: String, CaseIterable {
    case extremeFear = "Extreme Fear"
    case fear = "Fear"
    case neutral = "Neutral"
    case greed = "Greed"
    case extremeGreed = "Extreme Greed"
    
    var color: String {
        switch self {
        case .extremeFear: return "dark_red"
        case .fear: return "red"
        case .neutral: return "gray"
        case .greed: return "green"
        case .extremeGreed: return "dark_green"
        }
    }
    
    var sentiment: String {
        switch self {
        case .extremeFear, .fear:
            return "Bearish"
        case .neutral:
            return "Neutral"
        case .greed, .extremeGreed:
            return "Bullish"
        }
    }
}

struct FearGreedHistory: Codable {
    let data: [FearGreedDataPoint]
}

struct FearGreedDataPoint: Codable {
    let value: Int
    let valueClassification: String
    let timestamp: String
    let timeUntilUpdate: String
}

// MARK: - Mempool.space Models

/// Bitcoin hashrate data
struct BitcoinHashrate: Codable {
    let currentHashrate: Double // EH/s
    let currentDifficulty: Double
    let difficultyChange: Double // Percentage
    let difficultyEpoch: Int
    let remainingBlocksToDifficultyAdjustment: Int
    let estimatedDifficultyChange: Double
    let timestamp: Date
    
    enum CodingKeys: String, CodingKey {
        case currentHashrate = "currentHashrate"
        case currentDifficulty = "currentDifficulty"
        case difficultyChange = "difficultyChange"
        case difficultyEpoch = "difficultyEpoch"
        case remainingBlocksToDifficultyAdjustment
        case estimatedDifficultyChange
        case timestamp
    }
}

/// Bitcoin network statistics
struct BitcoinNetworkStats: Codable {
    let hashrate: Double
    let difficulty: Double
    let mempoolSize: Int // MB
    let unconfirmedTxs: Int
    let avgFeeRate: Double // sats/vByte
    let avgBlockTime: Double // minutes
}

// MARK: - Market Summary

/// Complete market summary
struct MarketSummary: Codable {
    let timestamp: Date
    let indices: [YahooQuote]
    let crypto: [CryptoAsset]
    let stablecoins: [StablecoinHealth]
    let fearGreed: FearGreedIndex?
    let bitcoinHashrate: BitcoinHashrate?
    let bisRates: [BISPolicyRate]
    
    /// Overall market sentiment
    var overallSentiment: String {
        let fearGreedValue = fearGreed?.classification ?? .neutral
        let cryptoPositive = crypto.filter { $0.isPositive }.count
        let totalCrypto = crypto.count
        
        if fearGreedValue == .extremeGreed || fearGreedValue == .greed &&
           Double(cryptoPositive) / Double(totalCrypto) > 0.7 {
            return "Bullish"
        } else if fearGreedValue == .extremeFear || fearGreedValue == .fear &&
                  Double(cryptoPositive) / Double(totalCrypto) < 0.3 {
            return "Bearish"
        } else {
            return "Neutral"
        }
    }
}
