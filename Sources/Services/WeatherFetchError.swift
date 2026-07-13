import Foundation

/// Typed error surface for `WeatherService`. Deliberately keeps the full underlying error
/// (domain, code, userInfo, debug description) in `errorDescription` rather than a friendly
/// one-liner: during Phase 1 this is what gets rendered verbatim on the smoke test screen so
/// WeatherKit auth/JWT failures (e.g. during App Services capability propagation) are
/// diagnosable on-device without Xcode attached.
enum WeatherFetchError: LocalizedError {
    case fetchFailed(underlying: Error)
    case attributionFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .fetchFailed(let underlying):
            return "Weather fetch failed: \(WeatherFetchError.fullDescription(of: underlying))"
        case .attributionFailed(let underlying):
            return "Attribution fetch failed: \(WeatherFetchError.fullDescription(of: underlying))"
        }
    }

    static func fullDescription(of error: Error) -> String {
        let nsError = error as NSError
        var parts = ["\(nsError.domain) (\(nsError.code))"]
        let localized = nsError.localizedDescription
        if !localized.isEmpty {
            parts.append(localized)
        }
        if !nsError.userInfo.isEmpty {
            parts.append("userInfo: \(nsError.userInfo)")
        }
        parts.append("debug: \(String(reflecting: error))")
        return parts.joined(separator: " — ")
    }
}
