import Foundation

// MARK: - Unit convention
//
// All measurements in this file are stored as Foundation `Measurement<Unit>` values
// (e.g. `Measurement<UnitTemperature>`, `Measurement<UnitSpeed>`, `Measurement<UnitLength>`).
// `Measurement` is natively `Codable`, unit-tagged, and easy to convert/display in either
// Fahrenheit/Celsius, mph/kph, etc. at render time via `.converted(to:)` - so these payloads
// stay unit-agnostic and Settings' F/C toggle (Phase 3) never has to touch this layer.
//
// WeatherKit's own descriptive enums (WeatherCondition, WeatherSeverity, MoonPhase,
// UVIndex.ExposureCategory) are NOT stored directly. Instead each is captured as a stable
// `rawValue`-style code string (e.g. "partlyCloudy") plus a human-readable description,
// captured at fetch time. This keeps the persisted/cached model decoupled from the WeatherKit
// framework (only WeatherService.swift imports WeatherKit) and trivially Codable/SwiftData-safe.

/// Current-moment conditions for a location. Mirrors PRD Section 8's
/// `CachedWeather.currentConditions`.
struct CurrentConditions: Codable, Equatable {
    var date: Date
    var temperature: Measurement<UnitTemperature>
    var feelsLike: Measurement<UnitTemperature>
    var conditionCode: String
    var conditionDescription: String
    var symbolName: String
    var humidity: Double
    var windSpeed: Measurement<UnitSpeed>
    var windDirection: Measurement<UnitAngle>
    var uvIndexValue: Int
    var uvIndexCategory: String
    var isDaylight: Bool
}

/// One hour of the hourly forecast. Mirrors PRD Section 8's `CachedWeather.hourly`.
struct HourlyEntry: Codable, Equatable, Identifiable {
    var date: Date
    var temperature: Measurement<UnitTemperature>
    var feelsLike: Measurement<UnitTemperature>
    var precipChance: Double
    var precipAmount: Measurement<UnitLength>
    var windSpeed: Measurement<UnitSpeed>
    var uvIndexValue: Int
    var conditionCode: String
    var conditionDescription: String
    var symbolName: String

    var id: Date { date }
}

/// One day of the 10-day forecast. Mirrors PRD Section 8's `CachedWeather.daily`.
struct DailyEntry: Codable, Equatable, Identifiable {
    var date: Date
    var low: Measurement<UnitTemperature>
    var high: Measurement<UnitTemperature>
    var precipChance: Double
    var precipAmount: Measurement<UnitLength>
    var conditionCode: String
    var conditionDescription: String
    var symbolName: String
    var sunrise: Date?
    var sunset: Date?
    var moonPhaseCode: String
    var moonPhaseDescription: String

    var id: Date { date }
}

/// A single active WeatherKit alert. Mirrors PRD Section 8's `CachedWeather.activeAlerts`.
/// WeatherKit's `WeatherAlert` has no stable `id`, so `id` here is synthesized from
/// `detailsURL` (stable across fetches for the same alert).
struct AlertSummary: Codable, Equatable, Identifiable {
    var id: String
    var severityCode: String
    var severityDescription: String
    var title: String
    var agencyText: String
    var region: String?
    var effectiveDate: Date
    var expirationDate: Date
    var detailsURL: URL

    init(
        severityCode: String,
        severityDescription: String,
        title: String,
        agencyText: String,
        region: String?,
        effectiveDate: Date,
        expirationDate: Date,
        detailsURL: URL
    ) {
        self.id = detailsURL.absoluteString
        self.severityCode = severityCode
        self.severityDescription = severityDescription
        self.title = title
        self.agencyText = agencyText
        self.region = region
        self.effectiveDate = effectiveDate
        self.expirationDate = expirationDate
        self.detailsURL = detailsURL
    }
}

/// A rolling record of what actually happened on a given day, kept for the trailing 7 days
/// per location. Fallback data source for the Forecast screen's comparison line when
/// WeatherKit's historical comparison data is unavailable. Mirrors PRD Section 8's
/// `CachedWeather.dailyActuals`.
struct DailyActual: Codable, Equatable, Identifiable {
    var date: Date
    var observedHigh: Measurement<UnitTemperature>
    var observedLow: Measurement<UnitTemperature>
    var dominantConditionCode: String
    var dominantConditionDescription: String

    var id: Date { date }
}

/// Apple Weather attribution, required to be visible on the Forecast screen without extra
/// navigation (PRD Section 6/9). Not location-specific, but fetched alongside a location's
/// weather for convenience and cached with it.
struct WeatherAttributionInfo: Codable, Equatable {
    var serviceName: String
    var legalPageURL: URL
    var squareMarkURL: URL
    var combinedMarkLightURL: URL
    var combinedMarkDarkURL: URL
    var legalAttributionText: String
}

/// The full cached payload for one `SavedLocation`. Mirrors PRD Section 8's `CachedWeather`.
/// Encoded to `Data` and stored in a `CachedWeatherRecord` (SwiftData) alongside `fetchedAt`.
struct CachedWeather: Codable, Equatable {
    var locationId: UUID
    var fetchedAt: Date
    var currentConditions: CurrentConditions
    var hourly: [HourlyEntry]
    var daily: [DailyEntry]
    var activeAlerts: [AlertSummary]
    var dailyActuals: [DailyActual]
    var attribution: WeatherAttributionInfo
}
