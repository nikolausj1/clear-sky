import CoreLocation
import Foundation
import WeatherKit

/// Async wrapper around Apple's `WeatherKit.WeatherService`, mapping its response types into
/// ClearSky's own Codable model structs (`Sources/Models/WeatherPayload.swift`) so the rest of
/// the app never has to import WeatherKit directly. This type is also named `WeatherService`
/// (matching the Build Phase 1 spec); unqualified `WeatherService` inside this module always
/// resolves to this type, and Apple's framework type is referenced fully-qualified below as
/// `WeatherKit.WeatherService`.
final class WeatherService {
    static let shared = WeatherService()

    /// 240 hours = 10 days of hourly detail, matching the 10-day daily forecast's span.
    static let hourlyEntryLimit = 240
    static let dailyEntryLimit = 10

    private let underlying: WeatherKit.WeatherService

    init(underlying: WeatherKit.WeatherService = .shared) {
        self.underlying = underlying
    }

    /// Fetches current conditions + hourly (240h) + daily (10d) + active alerts + Apple's
    /// attribution object for `location`, mapped into a single `CachedWeather` payload.
    /// `locationId` is stamped onto the result so callers (`WeatherStore`) can key their cache;
    /// `fetchedAt` is set to the fetch completion time.
    func fetchWeather(for location: CLLocation, locationId: UUID) async throws -> CachedWeather {
        let weather: WeatherKit.Weather
        do {
            weather = try await underlying.weather(for: location)
        } catch {
            throw WeatherFetchError.fetchFailed(underlying: error)
        }

        let attribution: WeatherKit.WeatherAttribution
        do {
            attribution = try await underlying.attribution
        } catch {
            throw WeatherFetchError.attributionFailed(underlying: error)
        }

        let hourly: [HourlyEntry] = weather.hourlyForecast.forecast
            .prefix(Self.hourlyEntryLimit)
            .map(Self.map(hour:))
        let daily: [DailyEntry] = weather.dailyForecast.forecast
            .prefix(Self.dailyEntryLimit)
            .map(Self.map(day:))
        let alerts: [AlertSummary] = (weather.weatherAlerts ?? []).map(Self.map(alert:))

        return CachedWeather(
            locationId: locationId,
            fetchedAt: Date(),
            currentConditions: Self.map(current: weather.currentWeather),
            hourly: hourly,
            daily: daily,
            activeAlerts: alerts,
            dailyActuals: [],
            attribution: Self.map(attribution: attribution)
        )
    }

    /// Standalone attribution fetch, independent of any location — used by the Settings screen
    /// (PRD Screen D: "Attribution and legal ... restated here in addition to the Forecast
    /// screen") so Settings doesn't need to depend on the Forecast screen's active-location
    /// payload just to show the same Apple-required attribution.
    func fetchAttribution() async throws -> WeatherAttributionInfo {
        do {
            let attribution = try await underlying.attribution
            return Self.map(attribution: attribution)
        } catch {
            throw WeatherFetchError.attributionFailed(underlying: error)
        }
    }

    // MARK: - Mapping (WeatherKit types -> ClearSky model structs)

    private static func map(current: WeatherKit.CurrentWeather) -> CurrentConditions {
        CurrentConditions(
            date: current.date,
            temperature: current.temperature,
            feelsLike: current.apparentTemperature,
            conditionCode: current.condition.rawValue,
            conditionDescription: current.condition.description,
            symbolName: current.symbolName,
            humidity: current.humidity,
            windSpeed: current.wind.speed,
            windDirection: current.wind.direction,
            uvIndexValue: current.uvIndex.value,
            uvIndexCategory: current.uvIndex.category.description,
            isDaylight: current.isDaylight
        )
    }

    private static func map(hour: WeatherKit.HourWeather) -> HourlyEntry {
        HourlyEntry(
            date: hour.date,
            temperature: hour.temperature,
            feelsLike: hour.apparentTemperature,
            precipChance: hour.precipitationChance,
            precipAmount: hour.precipitationAmount,
            windSpeed: hour.wind.speed,
            uvIndexValue: hour.uvIndex.value,
            conditionCode: hour.condition.rawValue,
            conditionDescription: hour.condition.description,
            symbolName: hour.symbolName
        )
    }

    private static func map(day: WeatherKit.DayWeather) -> DailyEntry {
        DailyEntry(
            date: day.date,
            low: day.lowTemperature,
            high: day.highTemperature,
            precipChance: day.precipitationChance,
            precipAmount: day.precipitationAmountByType.precipitation,
            conditionCode: day.condition.rawValue,
            conditionDescription: day.condition.description,
            symbolName: day.symbolName,
            sunrise: day.sun.sunrise,
            sunset: day.sun.sunset,
            moonPhaseCode: day.moon.phase.rawValue,
            moonPhaseDescription: day.moon.phase.description
        )
    }

    private static func map(alert: WeatherKit.WeatherAlert) -> AlertSummary {
        AlertSummary(
            severityCode: alert.severity.rawValue,
            severityDescription: alert.severity.description,
            title: alert.summary,
            agencyText: alert.source,
            region: alert.region,
            effectiveDate: alert.metadata.date,
            expirationDate: alert.metadata.expirationDate,
            detailsURL: alert.detailsURL
        )
    }

    private static func map(attribution: WeatherKit.WeatherAttribution) -> WeatherAttributionInfo {
        WeatherAttributionInfo(
            serviceName: attribution.serviceName,
            legalPageURL: attribution.legalPageURL,
            squareMarkURL: attribution.squareMarkURL,
            combinedMarkLightURL: attribution.combinedMarkLightURL,
            combinedMarkDarkURL: attribution.combinedMarkDarkURL,
            legalAttributionText: attribution.legalAttributionText
        )
    }
}
