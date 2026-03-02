import Foundation
import MapKit

/// Service for military bases data
/// Uses static data embedded in the app
actor MilitaryBasesService {
    static let shared = MilitaryBasesService()
    
    private let cache = CacheManager.shared
    private var bases: [MilitaryBase] = []
    private var loaded = false
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch all military bases
    func fetchAllBases() async -> [MilitaryBase] {
        // Load from cache first
        if let cached: [MilitaryBase] = await cache.read(source: .militaryBases, maxAge: DataSource.militaryBases.defaultCacheTTL) {
            self.bases = cached
            self.loaded = true
            return cached
        }
        
        // Load static data
        let bases = loadStaticBases()
        self.bases = bases
        self.loaded = true
        
        // Cache the data
        await cache.write(source: .militaryBases, data: bases)
        
        return bases
    }
    
    /// Fetch bases filtered by region
    func fetchBasesInRegion(_ region: RegionPreset) async -> [MilitaryBase] {
        let allBases = await fetchAllBases()
        
        let (minLat, maxLat, minLon, maxLon) = boundsForRegion(region)
        
        return allBases.filter { base in
            base.latitude >= minLat && base.latitude <= maxLat &&
            base.longitude >= minLon && base.longitude <= maxLon
        }
    }
    
    /// Fetch bases by operator country
    func fetchBasesByOperator(_ country: String) async -> [MilitaryBase] {
        let allBases = await fetchAllBases()
        return allBases.filter { $0.operatorCountry == country }
    }
    
    /// Fetch bases by type
    func fetchBasesByType(_ type: MilitaryBase.BaseType) async -> [MilitaryBase] {
        let allBases = await fetchAllBases()
        return allBases.filter { $0.type == type }
    }
    
    /// Count bases in a region
    func countBasesInRegion(_ region: RegionPreset) async -> Int {
        let bases = await fetchBasesInRegion(region)
        return bases.count
    }
    
    /// Get statistics summary
    func fetchStats() async -> MilitaryBaseStats {
        let allBases = await fetchAllBases()
        
        var byOperator: [String: Int] = [:]
        var byType: [MilitaryBase.BaseType: Int] = [:]
        var byRegion: [String: Int] = [:]
        
        for base in allBases {
            byOperator[base.operatorCountry, default: 0] += 1
            byType[base.type, default: 0] += 1
            
            // Determine region
            let region = determineRegion(latitude: base.latitude, longitude: base.longitude)
            byRegion[region, default: 0] += 1
        }
        
        let majorInstallations = allBases
            .filter { $0.size == .major || $0.size == .large }
            .sorted { $0.personnel ?? 0 > $1.personnel ?? 0 }
        
        return MilitaryBaseStats(
            totalCount: allBases.count,
            byOperator: byOperator,
            byType: byType,
            byRegion: byRegion,
            majorInstallations: Array(majorInstallations.prefix(20))
        )
    }
    
    /// Find bases near a coordinate within radius (km)
    func fetchBasesNear(
        latitude: Double,
        longitude: Double,
        radiusKm: Double
    ) async -> [(base: MilitaryBase, distanceKm: Double)] {
        let allBases = await fetchAllBases()
        
        return allBases.compactMap { base in
            let distance = haversineDistance(
                lat1: latitude, lon1: longitude,
                lat2: base.latitude, lon2: base.longitude
            )
            guard distance <= radiusKm else { return nil }
            return (base, distance)
        }.sorted { $0.distanceKm < $1.distanceKm }
    }
    
    // MARK: - Private Methods
    
    private func loadStaticBases() -> [MilitaryBase] {
        // Return subset of major bases for now
        // In production, this would load from a bundled JSON file
        return [
            // United States Major Bases
            MilitaryBase(
                id: "us-norfolk",
                name: "Naval Station Norfolk",
                country: "United States",
                operatorCountry: "United States",
                latitude: 36.9500,
                longitude: -76.3100,
                type: .navy,
                size: .major,
                established: 1917,
                personnel: 45000,
                description: "World's largest naval station",
                majorUnits: ["Carrier Strike Group 10", "Destroyer Squadron 26"],
                capabilities: [.navalOperations, .airOperations, .logistics]
            ),
            MilitaryBase(
                id: "us-san-diego",
                name: "Naval Base San Diego",
                country: "United States",
                operatorCountry: "United States",
                latitude: 32.6800,
                longitude: -117.1500,
                type: .navy,
                size: .major,
                established: 1922,
                personnel: 24000,
                description: "Principal homeport of the Pacific Fleet",
                majorUnits: ["Carrier Strike Group 3", "Littoral Combat Ship Squadron 1"],
                capabilities: [.navalOperations, .airOperations, .logistics]
            ),
            MilitaryBase(
                id: "us-yokosuka",
                name: "Fleet Activities Yokosuka",
                country: "Japan",
                operatorCountry: "United States",
                latitude: 35.2800,
                longitude: 139.6700,
                type: .navy,
                size: .major,
                established: 1945,
                personnel: 11000,
                description: "Forward-deployed naval forces in Japan",
                majorUnits: ["Carrier Strike Group 5", "Destroyer Squadron 15"],
                capabilities: [.navalOperations, .airOperations, .missileDefense]
            ),
            MilitaryBase(
                id: "us-guantanamo",
                name: "Naval Station Guantanamo Bay",
                country: "Cuba",
                operatorCountry: "United States",
                latitude: 19.9000,
                longitude: -75.1600,
                type: .navy,
                size: .medium,
                established: 1903,
                personnel: 6000,
                description: "Oldest overseas US naval base",
                majorUnits: ["Joint Task Force Guantanamo"],
                capabilities: [.navalOperations, .intelligence]
            ),
            MilitaryBase(
                id: "us-bahrain",
                name: "Naval Support Activity Bahrain",
                country: "Bahrain",
                operatorCountry: "United States",
                latitude: 26.2300,
                longitude: 50.5500,
                type: .navy,
                size: .major,
                established: 1971,
                personnel: 8000,
                description: "US Fifth Fleet headquarters",
                majorUnits: ["US Naval Forces Central Command", "Carrier Strike Group"],
                capabilities: [.navalOperations, .airOperations, .intelligence]
            ),
            MilitaryBase(
                id: "us-ramstein",
                name: "Ramstein Air Base",
                country: "Germany",
                operatorCountry: "United States",
                latitude: 49.4400,
                longitude: 7.6000,
                type: .airForce,
                size: .major,
                established: 1953,
                personnel: 16000,
                description: "US Air Forces in Europe headquarters",
                majorUnits: ["86th Airlift Wing", "435th Air Ground Operations Wing"],
                capabilities: [.airOperations, .logistics, .medical]
            ),
            MilitaryBase(
                id: "us-camp-humphreys",
                name: "Camp Humphreys",
                country: "South Korea",
                operatorCountry: "United States",
                latitude: 36.9700,
                longitude: 127.0300,
                type: .army,
                size: .major,
                established: 1919,
                personnel: 28000,
                description: "Largest US overseas military installation",
                majorUnits: ["2nd Infantry Division", "8th Army"],
                capabilities: [.groundForces, .airOperations, .logistics, .medical]
            ),
            MilitaryBase(
                id: "us-diego-garcia",
                name: "Naval Support Facility Diego Garcia",
                country: "British Indian Ocean Territory",
                operatorCountry: "United States",
                latitude: -7.3100,
                longitude: 72.4100,
                type: .navy,
                size: .large,
                established: 1971,
                personnel: 3000,
                description: "Strategic island base in Indian Ocean",
                majorUnits: ["Maritime Prepositioning Squadron"],
                capabilities: [.navalOperations, .airOperations, .logistics, .intelligence]
            ),
            
            // Russia Major Bases
            MilitaryBase(
                id: "ru-sevastopol",
                name: "Sevastopol Naval Base",
                country: "Ukraine/Russia",
                operatorCountry: "Russia",
                latitude: 44.6000,
                longitude: 33.5200,
                type: .navy,
                size: .major,
                established: 1783,
                personnel: 25000,
                description: "Headquarters of Black Sea Fleet",
                majorUnits: ["Black Sea Fleet"],
                capabilities: [.navalOperations, .airOperations, .missileDefense]
            ),
            MilitaryBase(
                id: "ru-tartus",
                name: "Tartus Naval Facility",
                country: "Syria",
                operatorCountry: "Russia",
                latitude: 34.8900,
                longitude: 35.8700,
                type: .navy,
                size: .medium,
                established: 1971,
                personnel: 500,
                description: "Only Russian naval base in Mediterranean",
                majorUnits: ["Russian Navy Mediterranean Squadron"],
                capabilities: [.navalOperations, .logistics]
            ),
            MilitaryBase(
                id: "ru-khmeimim",
                name: "Khmeimim Air Base",
                country: "Syria",
                operatorCountry: "Russia",
                latitude: 35.4100,
                longitude: 35.9500,
                type: .airForce,
                size: .large,
                established: 2015,
                personnel: 4000,
                description: "Main Russian air base in Syria",
                majorUnits: ["Russian Aerospace Forces Syria"],
                capabilities: [.airOperations, .missileDefense, .intelligence]
            ),
            
            // China Major Bases
            MilitaryBase(
                id: "cn-djibouti",
                name: "PLA Support Base Djibouti",
                country: "Djibouti",
                operatorCountry: "China",
                latitude: 11.5800,
                longitude: 43.1300,
                type: .navy,
                size: .large,
                established: 2017,
                personnel: 2000,
                description: "China's first overseas military base",
                majorUnits: ["PLA Navy Gulf of Aden Escort Force"],
                capabilities: [.navalOperations, .airOperations, .logistics]
            ),
            MilitaryBase(
                id: "cn-sanya",
                name: "Yulin Naval Base",
                country: "China",
                operatorCountry: "China",
                latitude: 18.2000,
                longitude: 109.5500,
                type: .navy,
                size: .major,
                established: 1950,
                personnel: 15000,
                description: "South Sea Fleet headquarters, submarine base",
                majorUnits: ["South Sea Fleet", "Nuclear Submarine Force"],
                capabilities: [.navalOperations, .nuclearStorage, .missileDefense]
            ),
            
            // UK Major Bases
            MilitaryBase(
                id: "uk-akrotiri",
                name: "RAF Akrotiri",
                country: "Cyprus",
                operatorCountry: "United Kingdom",
                latitude: 34.7100,
                longitude: 32.9900,
                type: .airForce,
                size: .large,
                established: 1955,
                personnel: 3500,
                description: "RAF station in the Middle East",
                majorUnits: ["RAF Akrotiri", "Operation Shader forces"],
                capabilities: [.airOperations, .intelligence, .logistics]
            ),
            
            // France Major Bases
            MilitaryBase(
                id: "fr-djibouti",
                name: "5th Overseas Interarms Regiment",
                country: "Djibouti",
                operatorCountry: "France",
                latitude: 11.5700,
                longitude: 43.1500,
                type: .army,
                size: .medium,
                established: 1979,
                personnel: 1400,
                description: "French military presence in Horn of Africa",
                majorUnits: ["5th RIAOM"],
                capabilities: [.groundForces, .airOperations]
            ),
            
            // Turkey Major Bases
            MilitaryBase(
                id: "tr-qatar",
                name: "Turkish Armed Forces Qatar Base",
                country: "Qatar",
                operatorCountry: "Turkey",
                latitude: 25.3000,
                longitude: 51.2000,
                type: .joint,
                size: .medium,
                established: 2015,
                personnel: 3000,
                description: "Turkish base in the Gulf",
                majorUnits: ["Qatar-Turkish Combined Joint Force Command"],
                capabilities: [.groundForces, .airOperations]
            )
        ]
    }
    
    private func boundsForRegion(_ region: RegionPreset) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        switch region {
        case .global:
            return (-90, 90, -180, 180)
        case .americas:
            return (-60, 75, -170, -30)
        case .europe:
            return (35, 72, -25, 45)
        case .mena:
            return (12, 42, -20, 65)
        case .asia:
            return (-10, 80, 45, 180)
        case .africa:
            return (-40, 38, -25, 55)
        }
    }
    
    private func determineRegion(latitude: Double, longitude: Double) -> String {
        if longitude >= -170 && longitude <= -30 && latitude >= -60 && latitude <= 75 {
            return "Americas"
        } else if longitude >= -25 && longitude <= 45 && latitude >= 35 && latitude <= 72 {
            return "Europe"
        } else if longitude >= -20 && longitude <= 65 && latitude >= 12 && latitude <= 42 {
            return "MENA"
        } else if longitude >= 45 && longitude <= 180 && latitude >= -10 && latitude <= 80 {
            return "Asia-Pacific"
        } else if longitude >= -25 && longitude <= 55 && latitude >= -40 && latitude <= 38 {
            return "Africa"
        } else {
            return "Other"
        }
    }
    
    private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        
        return R * c
    }
}
