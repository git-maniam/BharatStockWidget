import Foundation

/// Deep links from a widget row into the container app (spec §11.5).
///
/// Lives in the core rather than in the widget because both sides need it: the widget constructs
/// these URLs and the app parses them, and a private copy on each side is how the two drift apart.
public enum InstrumentLink {
    public static let scheme = "bharatstock"

    public static var appHome: URL {
        URL(string: "\(scheme)://home")!
    }

    public static func url(type: InstrumentType, symbol: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "instrument"
        components.queryItems = [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "symbol", value: symbol),
        ]
        return components.url ?? appHome
    }

    /// Parses a link back into an instrument identity. Nil for `bharatstock://home` and for
    /// anything malformed.
    public static func instrument(from url: URL) -> (type: InstrumentType, symbol: String)? {
        guard url.scheme == scheme, url.host == "instrument",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawType = items.first(where: { $0.name == "type" })?.value,
              let type = InstrumentType(lenient: rawType),
              let symbol = items.first(where: { $0.name == "symbol" })?.value,
              !symbol.isEmpty
        else { return nil }
        return (type, symbol)
    }
}
