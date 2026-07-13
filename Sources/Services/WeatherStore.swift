import CoreLocation
import Foundation
import SwiftData

/// Per-location weather cache implementing PRD Section 8's staleness rule: data is stale
/// after 30 minutes, but stale data is still returned (with its `fetchedAt`) rather than
/// blanked while a refresh happens in the background. Also maintains the rolling 7-day
/// `dailyActuals` history used as the comparison-line fallback (Section 6).
///
/// Marked `@MainActor`: SwiftData's `ModelContext` is not thread-safe, and every consumer of
/// this store in the shipped app (ViewModels) is main-actor-bound anyway, so isolating here
/// avoids a second layer of locking.
@MainActor
final class WeatherStore {
    /// PRD Section 8: "data is considered stale after 30 minutes."
    static let staleInterval: TimeInterval = 30 * 60
    /// PRD Section 8: "kept for the trailing 7 days per location."
    static let dailyActualsWindow: TimeInterval = 7 * 24 * 60 * 60

    enum CacheState: Equatable {
        case missing
        case fresh
        case stale
    }

    private let weatherService: WeatherService
    private let modelContext: ModelContext?
    private var cache: [UUID: CachedWeather] = [:]
    private var refreshTasks: [UUID: Task<CachedWeather, Error>] = [:]

    init(weatherService: WeatherService = .shared, modelContext: ModelContext? = nil) {
        self.weatherService = weatherService
        self.modelContext = modelContext
        if let modelContext {
            loadPersistedCache(from: modelContext)
        }
    }

    /// Whatever is currently cached for `locationId`, possibly stale. `nil` if nothing has
    /// ever been fetched (or loaded from disk) for this location yet.
    func cached(for locationId: UUID) -> CachedWeather? {
        cache[locationId]
    }

    func cacheState(for locationId: UUID, now: Date = Date()) -> CacheState {
        guard let entry = cache[locationId] else { return .missing }
        return now.timeIntervalSince(entry.fetchedAt) > Self.staleInterval ? .stale : .fresh
    }

    /// Returns weather for `locationId` at `coordinate`. If cached data exists and is fresh
    /// (and `forceRefresh` is false), returns it immediately with no network call. Otherwise
    /// fetches fresh data from WeatherService, merges the rolling `dailyActuals` window,
    /// persists it, and returns it. Concurrent calls for the same location while a fetch is
    /// already in flight are coalesced onto the same task rather than firing duplicate
    /// network requests.
    ///
    /// Callers implementing the PRD's "stale data stays visible while a refresh happens" UX
    /// should read `cached(for:)` synchronously first to render immediately, then call this
    /// method to trigger/await the refresh.
    @discardableResult
    func weather(
        for locationId: UUID,
        coordinate: CLLocationCoordinate2D,
        forceRefresh: Bool = false
    ) async throws -> CachedWeather {
        if !forceRefresh, cacheState(for: locationId) == .fresh, let cached = cache[locationId] {
            return cached
        }

        if let existingTask = refreshTasks[locationId] {
            return try await existingTask.value
        }

        let previous = cache[locationId]
        let task = Task<CachedWeather, Error> { [weatherService] in
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let fresh = try await weatherService.fetchWeather(for: location, locationId: locationId)
            return Self.mergingDailyActuals(into: fresh, previous: previous)
        }
        refreshTasks[locationId] = task

        do {
            let result = try await task.value
            refreshTasks[locationId] = nil
            cache[locationId] = result
            persist(result)
            return result
        } catch {
            refreshTasks[locationId] = nil
            throw error
        }
    }

    // MARK: - dailyActuals rolling window

    private static func mergingDailyActuals(into payload: CachedWeather, previous: CachedWeather?) -> CachedWeather {
        var actuals = previous?.dailyActuals ?? []
        if let today = payload.daily.first {
            let calendar = Calendar.current
            actuals.removeAll { calendar.isDate($0.date, inSameDayAs: today.date) }
            actuals.append(
                DailyActual(
                    date: today.date,
                    observedHigh: today.high,
                    observedLow: today.low,
                    dominantConditionCode: today.conditionCode,
                    dominantConditionDescription: today.conditionDescription
                )
            )
        }
        let cutoff = Date().addingTimeInterval(-dailyActualsWindow)
        actuals = actuals
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }

        var merged = payload
        merged.dailyActuals = actuals
        return merged
    }

    // MARK: - SwiftData persistence

    private func loadPersistedCache(from context: ModelContext) {
        guard let records = try? context.fetch(FetchDescriptor<CachedWeatherRecord>()) else { return }
        for record in records {
            if let payload = record.decodedPayload() {
                cache[record.locationId] = payload
            }
        }
    }

    private func persist(_ payload: CachedWeather) {
        guard let modelContext else { return }
        guard let data = try? CachedWeatherRecord.encode(payload) else { return }

        let locationId = payload.locationId
        let descriptor = FetchDescriptor<CachedWeatherRecord>(
            predicate: #Predicate { $0.locationId == locationId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.fetchedAt = payload.fetchedAt
            existing.payloadData = data
        } else {
            modelContext.insert(
                CachedWeatherRecord(locationId: locationId, fetchedAt: payload.fetchedAt, payloadData: data)
            )
        }
        try? modelContext.save()
    }
}
