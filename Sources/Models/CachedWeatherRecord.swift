import Foundation
import SwiftData

/// SwiftData persistence for a location's cached `CachedWeather` payload. One record per
/// `SavedLocation.id`, per PRD Section 8. The payload itself is stored as an encoded JSON
/// blob (`payloadData`) rather than as SwiftData relationships, since `CachedWeather` and its
/// nested types are plain Codable structs, not `@Model` classes - this keeps the encode/decode
/// boundary at the WeatherStore/WeatherService layer instead of spreading persistence concerns
/// into the model structs themselves.
@Model
final class CachedWeatherRecord {
    @Attribute(.unique) var locationId: UUID
    var fetchedAt: Date
    var payloadData: Data

    init(locationId: UUID, fetchedAt: Date, payloadData: Data) {
        self.locationId = locationId
        self.fetchedAt = fetchedAt
        self.payloadData = payloadData
    }

    /// Decodes the stored payload. Returns `nil` (rather than throwing) if the on-disk shape
    /// no longer matches `CachedWeather` (e.g. after a model change across app versions) -
    /// callers should treat that the same as a cache miss and re-fetch.
    func decodedPayload() -> CachedWeather? {
        try? JSONDecoder.clearSkyDefault.decode(CachedWeather.self, from: payloadData)
    }

    static func encode(_ payload: CachedWeather) throws -> Data {
        try JSONEncoder.clearSkyDefault.encode(payload)
    }
}

extension JSONEncoder {
    /// Shared encoder for `CachedWeather` payloads - ISO 8601 dates keep the encoded blob
    /// stable and human-readable if ever inspected directly.
    static let clearSkyDefault: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let clearSkyDefault: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
