// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Well-known cities and where they are, for a map that opens over one or
/// flies to one without the app keeping the coordinates:
///
///     ImmersiveMapView()
///         .cameraPosition(.city(.paris))
///
///     camera.fly(to: .city(.tokyo, zoom: 13))
///
/// Each coordinate is the city's centre, as its maps usually mark it. The
/// list is a convenience and not a gazetteer: a place it does not hold is an
/// `ImmersiveMapCameraPosition` with its own coordinates.
public enum ImmersiveMapCity: String, CaseIterable, Hashable, Sendable {
    case newYork
    case losAngeles
    case sanFrancisco
    case chicago
    case washington
    case boston
    case miami
    case seattle
    case lasVegas
    case toronto
    case vancouver
    case montreal
    case mexicoCity
    case rioDeJaneiro
    case saoPaulo
    case buenosAires
    case lima
    case bogota
    case santiago
    case london
    case paris
    case berlin
    case madrid
    case barcelona
    case rome
    case milan
    case amsterdam
    case vienna
    case prague
    case lisbon
    case athens
    case stockholm
    case copenhagen
    case oslo
    case helsinki
    case dublin
    case brussels
    case zurich
    case munich
    case warsaw
    case budapest
    case istanbul
    case moscow
    case saintPetersburg
    case kyiv
    case dubai
    case telAviv
    case cairo
    case capeTown
    case johannesburg
    case nairobi
    case lagos
    case marrakesh
    case tokyo
    case osaka
    case seoul
    case beijing
    case shanghai
    case hongKong
    case taipei
    case singapore
    case bangkok
    case kualaLumpur
    case jakarta
    case manila
    case hanoi
    case mumbai
    case delhi
    case sydney
    case melbourne
    case auckland

    /// The city's name in English.
    public var name: String { entry.name }

    /// The city's centre.
    public var coordinate: GeoCoordinate {
        GeoCoordinate(latitude: entry.latitude, longitude: entry.longitude)
    }

    private var entry: (name: String, latitude: Double, longitude: Double) {
        switch self {
        case .newYork: ("New York", 40.73, -73.98)
        case .losAngeles: ("Los Angeles", 34.0522, -118.2437)
        case .sanFrancisco: ("San Francisco", 37.7749, -122.4194)
        case .chicago: ("Chicago", 41.8781, -87.6298)
        case .washington: ("Washington", 38.9072, -77.0369)
        case .boston: ("Boston", 42.3601, -71.0589)
        case .miami: ("Miami", 25.7617, -80.1918)
        case .seattle: ("Seattle", 47.6062, -122.3321)
        case .lasVegas: ("Las Vegas", 36.1699, -115.1398)
        case .toronto: ("Toronto", 43.6532, -79.3832)
        case .vancouver: ("Vancouver", 49.2827, -123.1207)
        case .montreal: ("Montreal", 45.5019, -73.5674)
        case .mexicoCity: ("Mexico City", 19.4326, -99.1332)
        case .rioDeJaneiro: ("Rio de Janeiro", -22.9068, -43.1729)
        case .saoPaulo: ("São Paulo", -23.5505, -46.6333)
        case .buenosAires: ("Buenos Aires", -34.6037, -58.3816)
        case .lima: ("Lima", -12.0464, -77.0428)
        case .bogota: ("Bogotá", 4.711, -74.0721)
        case .santiago: ("Santiago", -33.4489, -70.6693)
        case .london: ("London", 51.5074, -0.1278)
        case .paris: ("Paris", 48.8566, 2.3522)
        case .berlin: ("Berlin", 52.52, 13.405)
        case .madrid: ("Madrid", 40.4168, -3.7038)
        case .barcelona: ("Barcelona", 41.3874, 2.1686)
        case .rome: ("Rome", 41.9028, 12.4964)
        case .milan: ("Milan", 45.4642, 9.19)
        case .amsterdam: ("Amsterdam", 52.3676, 4.9041)
        case .vienna: ("Vienna", 48.2082, 16.3738)
        case .prague: ("Prague", 50.0755, 14.4378)
        case .lisbon: ("Lisbon", 38.7223, -9.1393)
        case .athens: ("Athens", 37.9838, 23.7275)
        case .stockholm: ("Stockholm", 59.3293, 18.0686)
        case .copenhagen: ("Copenhagen", 55.6761, 12.5683)
        case .oslo: ("Oslo", 59.9139, 10.7522)
        case .helsinki: ("Helsinki", 60.1699, 24.9384)
        case .dublin: ("Dublin", 53.3498, -6.2603)
        case .brussels: ("Brussels", 50.8503, 4.3517)
        case .zurich: ("Zurich", 47.3769, 8.5417)
        case .munich: ("Munich", 48.1351, 11.582)
        case .warsaw: ("Warsaw", 52.2297, 21.0122)
        case .budapest: ("Budapest", 47.4979, 19.0402)
        case .istanbul: ("Istanbul", 41.0082, 28.9784)
        case .moscow: ("Moscow", 55.7558, 37.6173)
        case .saintPetersburg: ("Saint Petersburg", 59.9311, 30.3609)
        case .kyiv: ("Kyiv", 50.4501, 30.5234)
        case .dubai: ("Dubai", 25.2048, 55.2708)
        case .telAviv: ("Tel Aviv", 32.0853, 34.7818)
        case .cairo: ("Cairo", 30.0444, 31.2357)
        case .capeTown: ("Cape Town", -33.9249, 18.4241)
        case .johannesburg: ("Johannesburg", -26.2041, 28.0473)
        case .nairobi: ("Nairobi", -1.2921, 36.8219)
        case .lagos: ("Lagos", 6.5244, 3.3792)
        case .marrakesh: ("Marrakesh", 31.6295, -7.9811)
        case .tokyo: ("Tokyo", 35.6812, 139.7671)
        case .osaka: ("Osaka", 34.6937, 135.5023)
        case .seoul: ("Seoul", 37.5665, 126.978)
        case .beijing: ("Beijing", 39.9042, 116.4074)
        case .shanghai: ("Shanghai", 31.2304, 121.4737)
        case .hongKong: ("Hong Kong", 22.3193, 114.1694)
        case .taipei: ("Taipei", 25.033, 121.5654)
        case .singapore: ("Singapore", 1.3521, 103.8198)
        case .bangkok: ("Bangkok", 13.7563, 100.5018)
        case .kualaLumpur: ("Kuala Lumpur", 3.139, 101.6869)
        case .jakarta: ("Jakarta", -6.2088, 106.8456)
        case .manila: ("Manila", 14.5995, 120.9842)
        case .hanoi: ("Hanoi", 21.0278, 105.8342)
        case .mumbai: ("Mumbai", 19.076, 72.8777)
        case .delhi: ("Delhi", 28.6139, 77.209)
        case .sydney: ("Sydney", -33.8688, 151.2093)
        case .melbourne: ("Melbourne", -37.8136, 144.9631)
        case .auckland: ("Auckland", -36.8485, 174.7633)
        }
    }
}
