import Foundation

/// Generic cache entry with metadata
private struct CacheEntry<T: Codable>: Codable {
    let data: T
    let timestamp: Date
    let source: String
    let region: String?
}

/// Actor-based cache manager with multi-tier caching
actor CacheManager {
    static let shared = CacheManager()
    
    // MARK: - Properties
    
    /// In-memory cache for hot data
    private var memoryCache: [String: Any] = [:]
    
    /// UserDefaults key for persisted cache
    private let persistenceKey = "com.worldmonitor.cache"
    
    /// Track cache statistics
    private var stats: CacheStats = CacheStats()
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Read data from cache if not expired
    func read<T: Codable>(
        source: DataSource,
        region: String? = nil,
        maxAge: TimeInterval? = nil
    ) -> T? {
        let key = cacheKey(for: source, region: region)
        let ttl = maxAge ?? source.defaultCacheTTL
        
        // Try memory cache first
        if let entry = memoryCache[key] as? CacheEntry<T> {
            if Date().timeIntervalSince(entry.timestamp) <= ttl {
                stats.recordHit(source: source, tier: .memory)
                return entry.data
            } else {
                // Expired - remove from memory
                memoryCache.removeValue(forKey: key)
            }
        }
        
        // Try persisted cache
        if let entry: CacheEntry<T> = loadFromPersistence(key: key) {
            if Date().timeIntervalSince(entry.timestamp) <= ttl {
                // Promote to memory cache
                memoryCache[key] = entry
                stats.recordHit(source: source, tier: .disk)
                return entry.data
            } else {
                // Expired - remove from persistence
                removeFromPersistence(key: key)
            }
        }
        
        stats.recordMiss(source: source)
        return nil
    }
    
    /// Write data to cache (memory and persistence)
    func write<T: Codable>(
        source: DataSource,
        region: String? = nil,
        data: T
    ) {
        let key = cacheKey(for: source, region: region)
        let entry = CacheEntry(
            data: data,
            timestamp: Date(),
            source: source.rawValue,
            region: region
        )
        
        // Write to memory
        memoryCache[key] = entry
        
        // Write to persistence
        saveToPersistence(key: key, entry: entry)
    }
    
    /// Clear cache for a specific source
    func clear(source: DataSource) {
        // Clear memory cache entries for this source
        let prefix = "\(source.rawValue)_"
        let memoryKeysToRemove = memoryCache.keys.filter { $0.hasPrefix(prefix) }
        for key in memoryKeysToRemove {
            memoryCache.removeValue(forKey: key)
        }
        
        // Clear persistence
        clearPersistenceForSource(source: source)
        
        stats.recordClear(source: source)
    }
    
    /// Clear all cache
    func clearAll() {
        memoryCache.removeAll()
        UserDefaults.standard.removeObject(forKey: persistenceKey)
        stats.recordClearAll()
    }
    
    /// Get cache statistics
    func getStats() -> CacheStats {
        return stats
    }
    
    /// Get stale data if available (for fallback when fetch fails)
    func readStale<T: Codable>(
        source: DataSource,
        region: String? = nil
    ) -> T? {
        let key = cacheKey(for: source, region: region)
        
        // Try memory first
        if let entry = memoryCache[key] as? CacheEntry<T> {
            stats.recordStaleHit(source: source)
            return entry.data
        }
        
        // Try persistence
        if let entry: CacheEntry<T> = loadFromPersistence(key: key) {
            stats.recordStaleHit(source: source)
            return entry.data
        }
        
        return nil
    }
    
    /// Check if cache entry exists and is fresh
    func isFresh(
        source: DataSource,
        region: String? = nil,
        maxAge: TimeInterval? = nil
    ) -> Bool {
        let key = cacheKey(for: source, region: region)
        let ttl = maxAge ?? source.defaultCacheTTL
        
        if let entry = memoryCache[key] as? CacheEntry<AnyCodable> {
            return Date().timeIntervalSince(entry.timestamp) <= ttl
        }
        
        if let entry: CacheEntry<AnyCodable> = loadFromPersistence(key: key) {
            return Date().timeIntervalSince(entry.timestamp) <= ttl
        }
        
        return false
    }
    
    // MARK: - Private Methods
    
    private func cacheKey(for source: DataSource, region: String?) -> String {
        if let region = region {
            return "\(source.rawValue)_\(region)"
        }
        return source.rawValue
    }
    
    private func saveToPersistence<T: Codable>(key: String, entry: CacheEntry<T>) {
        var persistedCache = UserDefaults.standard.dictionary(forKey: persistenceKey) ?? [:]
        
        if let data = try? JSONEncoder().encode(entry) {
            persistedCache[key] = data.base64EncodedString()
            UserDefaults.standard.set(persistedCache, forKey: persistenceKey)
        }
    }
    
    private func loadFromPersistence<T: Codable>(key: String) -> CacheEntry<T>? {
        guard let persistedCache = UserDefaults.standard.dictionary(forKey: persistenceKey),
              let base64String = persistedCache[key] as? String,
              let data = Data(base64Encoded: base64String) else {
            return nil
        }
        
        return try? JSONDecoder().decode(CacheEntry<T>.self, from: data)
    }
    
    private func removeFromPersistence(key: String) {
        var persistedCache = UserDefaults.standard.dictionary(forKey: persistenceKey) ?? [:]
        persistedCache.removeValue(forKey: key)
        UserDefaults.standard.set(persistedCache, forKey: persistenceKey)
    }
    
    private func clearPersistenceForSource(source: DataSource) {
        guard var persistedCache = UserDefaults.standard.dictionary(forKey: persistenceKey) else {
            return
        }
        
        let prefix = "\(source.rawValue)_"
        let persistedKeysToRemove = persistedCache.keys.filter { $0.hasPrefix(prefix) || $0 == source.rawValue }
        for key in persistedKeysToRemove {
            persistedCache.removeValue(forKey: key)
        }
        
        UserDefaults.standard.set(persistedCache, forKey: persistenceKey)
    }
    
    private func loadPersistedCache() {
        // Only metadata is loaded - actual data loaded on demand
        // This keeps memory usage low
    }
}

// MARK: - Cache Statistics

struct CacheStats {
    private(set) var memoryHits: [String: Int] = [:]
    private(set) var diskHits: [String: Int] = [:]
    private(set) var misses: [String: Int] = [:]
    private(set) var staleHits: [String: Int] = [:]
    private(set) var clears: [String: Int] = [:]
    private(set) var totalClears: Int = 0
    
    mutating func recordHit(source: DataSource, tier: CacheTier) {
        let key = source.rawValue
        switch tier {
        case .memory:
            memoryHits[key, default: 0] += 1
        case .disk:
            diskHits[key, default: 0] += 1
        }
    }
    
    mutating func recordMiss(source: DataSource) {
        misses[source.rawValue, default: 0] += 1
    }
    
    mutating func recordStaleHit(source: DataSource) {
        staleHits[source.rawValue, default: 0] += 1
    }
    
    mutating func recordClear(source: DataSource) {
        clears[source.rawValue, default: 0] += 1
    }
    
    mutating func recordClearAll() {
        totalClears += 1
    }
    
    var totalHits: Int {
        memoryHits.values.reduce(0, +) + diskHits.values.reduce(0, +)
    }
    
    var totalMisses: Int {
        misses.values.reduce(0, +)
    }
    
    var hitRate: Double {
        let total = totalHits + totalMisses
        guard total > 0 else { return 0 }
        return Double(totalHits) / Double(total)
    }
}

enum CacheTier {
    case memory
    case disk
}

// MARK: - Helper Types

/// Type erasure helper for cache operations
private struct AnyCodable: Codable {
    let value: Any
    
    init<T: Codable>(_ value: T) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        // This is a placeholder - actual decoding happens with concrete types
        self.value = ()
    }
    
    func encode(to encoder: Encoder) throws {
        // This is a placeholder - actual encoding happens with concrete types
    }
}

// MARK: - Convenience Extensions

extension CacheManager {
    /// Cache-aware fetch with stale fallback
    func fetchWithCache<T: Codable>(
        source: DataSource,
        region: String? = nil,
        maxAge: TimeInterval? = nil,
        fetch: () async throws -> T
    ) async throws -> T {
        // Try fresh cache first
        if let cached: T = read(source: source, region: region, maxAge: maxAge) {
            return cached
        }
        
        // Fetch fresh data
        do {
            let data = try await fetch()
            write(source: source, region: region, data: data)
            return data
        } catch {
            // Try stale fallback
            if let stale: T = readStale(source: source, region: region) {
                return stale
            }
            throw error
        }
    }
}
