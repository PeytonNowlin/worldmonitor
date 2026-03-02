import Foundation
import Combine

/// Errors that can occur during HTTP operations
enum HTTPClientError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(String)
    case rateLimited(retryAfter: TimeInterval)
    case circuitBreakerOpen
    case maxRetriesExceeded
    case unavailable
    
    var isRetryable: Bool {
        switch self {
        case .httpError(let code):
            return (500...599).contains(code) || code == 429
        case .invalidResponse, .unavailable:
            return true
        case .rateLimited:
            return true
        case .circuitBreakerOpen, .maxRetriesExceeded, .invalidURL, .decodingError:
            return false
        }
    }
}

/// Circuit breaker states
private enum CircuitBreakerState {
    case closed      // Normal operation
    case open        // Failing, reject requests
    case halfOpen    // Testing if recovered
}

/// Manages circuit breaker state for a data source
private actor CircuitBreaker {
    private var state: CircuitBreakerState = .closed
    private var failureCount = 0
    private var lastFailureTime: Date?
    
    private let failureThreshold = 5
    private let recoveryTimeout: TimeInterval = 60
    
    func canExecute() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= recoveryTimeout {
                state = .halfOpen
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }
    
    func recordSuccess() {
        failureCount = 0
        state = .closed
    }
    
    func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()
        
        if failureCount >= failureThreshold {
            state = .open
        }
    }
}

/// Shared HTTP client with retry logic and circuit breaker pattern
class HTTPClient {
    static let shared = HTTPClient()
    
    private let session: URLSession
    private var circuitBreakers: [DataSource: CircuitBreaker] = [:]
    private let decoder: JSONDecoder
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601
        
        // Initialize circuit breakers for all sources
        for source in DataSource.allCases {
            circuitBreakers[source] = CircuitBreaker()
        }
    }
    
    /// Fetch and decode JSON with automatic retry and circuit breaker
    func fetch<T: Decodable>(
        url: URL,
        source: DataSource,
        retries: Int = 3,
        decoder: JSONDecoder? = nil
    ) async throws -> T {
        let circuitBreaker = circuitBreakers[source]!
        
        // Check circuit breaker
        guard await circuitBreaker.canExecute() else {
            throw HTTPClientError.circuitBreakerOpen
        }
        
        let decoderToUse = decoder ?? self.decoder
        var lastError: Error?
        
        for attempt in 0..<retries {
            do {
                let result: T = try await performRequest(url: url, decoder: decoderToUse)
                await circuitBreaker.recordSuccess()
                return result
            } catch let error as HTTPClientError {
                lastError = error
                
                // Don't retry non-retryable errors
                if !error.isRetryable {
                    await circuitBreaker.recordFailure()
                    throw error
                }
                
                // Handle rate limiting with backoff
                if case .rateLimited(let retryAfter) = error {
                    let waitTime = max(retryAfter, pow(2.0, Double(attempt)))
                    try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                } else {
                    // Exponential backoff: 1s, 2s, 4s
                    let backoff = pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            } catch {
                lastError = error
                await circuitBreaker.recordFailure()
                throw error
            }
        }
        
        // Max retries exceeded
        await circuitBreaker.recordFailure()
        throw lastError ?? HTTPClientError.maxRetriesExceeded
    }
    
    /// Execute a fetch operation with circuit breaker protection
    func fetchWithCircuitBreaker<T>(
        source: DataSource,
        operation: () async throws -> T
    ) async throws -> T {
        let circuitBreaker = circuitBreakers[source]!
        
        guard await circuitBreaker.canExecute() else {
            throw HTTPClientError.circuitBreakerOpen
        }
        
        do {
            let result = try await operation()
            await circuitBreaker.recordSuccess()
            return result
        } catch {
            await circuitBreaker.recordFailure()
            throw error
        }
    }
    
    /// Simple GET request returning raw Data
    func fetchData(url: URL, source: DataSource) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        
        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) } ?? 60
            throw HTTPClientError.rateLimited(retryAfter: retryAfter)
        default:
            throw HTTPClientError.httpError(statusCode: httpResponse.statusCode)
        }
    }
    
    // MARK: - Private Methods
    
    private func performRequest<T: Decodable>(url: URL, decoder: JSONDecoder) async throws -> T {
        let data = try await fetchData(url: url, source: .usgs) // Source doesn't matter here
        
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPClientError.decodingError(error.localizedDescription)
        }
    }
}

// MARK: - Rate Limiter

/// Token bucket rate limiter for per-source rate limiting
actor RateLimiter {
    private var tokens: Double
    private let maxTokens: Double
    private let refillRate: Double // tokens per second
    private var lastRefill: Date
    
    init(tokensPerSecond: Double, maxTokens: Double? = nil) {
        self.refillRate = tokensPerSecond
        self.maxTokens = maxTokens ?? tokensPerSecond
        self.tokens = self.maxTokens
        self.lastRefill = Date()
    }
    
    /// Attempt to consume a token, returns true if allowed
    func tryConsume() -> Bool {
        refillTokens()
        
        if tokens >= 1 {
            tokens -= 1
            return true
        }
        return false
    }
    
    /// Wait until a token is available
    func waitForToken() async {
        while !tryConsume() {
            let waitTime = 1.0 / refillRate
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
    }
    
    private func refillTokens() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let newTokens = elapsed * refillRate
        
        tokens = min(maxTokens, tokens + newTokens)
        lastRefill = now
    }
}

// MARK: - Convenience Extensions

extension HTTPClient {
    /// Fetch with source-specific rate limiting
    func fetchWithRateLimit<T: Decodable>(
        url: URL,
        source: DataSource,
        rateLimiter: RateLimiter,
        retries: Int = 3
    ) async throws -> T {
        await rateLimiter.waitForToken()
        return try await fetch(url: url, source: source, retries: retries)
    }
}
