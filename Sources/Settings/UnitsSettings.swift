import Foundation
import Observation

/// PRD Screen D: "Units toggle (Fahrenheit/Celsius), defaulted from the device locale."
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case fahrenheit
    case celsius

    var id: String { rawValue }

    var unitTemperature: UnitTemperature {
        switch self {
        case .fahrenheit: return .fahrenheit
        case .celsius: return .celsius
        }
    }

    var shortLabel: String {
        switch self {
        case .fahrenheit: return "°F"
        case .celsius: return "°C"
        }
    }

    var title: String {
        switch self {
        case .fahrenheit: return "Fahrenheit (\u{00B0}F)"
        case .celsius: return "Celsius (\u{00B0}C)"
        }
    }

    /// PRD: "defaulted from the device locale" — `Locale.current.measurementSystem` is `.us`
    /// (Fahrenheit-using) or `.metric`/`.uk` (Celsius-using in practice for temperature).
    static var systemDefault: TemperatureUnit {
        Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }
}

/// Persisted units preference, shared app-wide via the SwiftUI environment (`.environment(_:)`)
/// so every temperature-rendering view — Forecast, Locations, Settings alike — reads the same
/// value and updates together when the Settings toggle changes (PRD Section 11: "changing units
/// updates Forecast, Locations, and Rankings consistently").
///
/// Backed directly by `UserDefaults` rather than `@AppStorage` (which requires a `View`) so
/// non-view services can read/observe it too if ever needed; `@Observable` gives SwiftUI views
/// the same automatic-invalidation behavior `@AppStorage` would.
///
/// Deliberately not `@MainActor` (unlike `WeatherStore`/`LocationsStore`, which wrap a
/// non-thread-safe SwiftData `ModelContext`): this only touches `UserDefaults`, which is
/// thread-safe, and being actor-free lets it be constructed as a plain `@State` default value at
/// a View's synchronous init time rather than only inside an async `.task`.
@Observable
final class UnitsSettings {
    static let storageKey = "clearSky.temperatureUnit"

    var unit: TemperatureUnit {
        didSet {
            guard unit != oldValue else { return }
            userDefaults.set(unit.rawValue, forKey: Self.storageKey)
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.string(forKey: Self.storageKey), let stored = TemperatureUnit(rawValue: raw) {
            unit = stored
        } else {
            unit = TemperatureUnit.systemDefault
        }
    }
}
