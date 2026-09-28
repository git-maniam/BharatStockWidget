import Foundation

/// The shortening table, loaded from JSON so it can be extended without a rebuild (§7).
public struct NameRules: Codable, Sendable, Equatable {
    public var version: Int
    public var noiseSuffixesCommon: [String]
    public var noiseSuffixesFunds: [String]
    public var phrases: [String: String]
    public var amcShortForms: [String: String]

    public init(
        version: Int = 1,
        noiseSuffixesCommon: [String] = [],
        noiseSuffixesFunds: [String] = [],
        phrases: [String: String] = [:],
        amcShortForms: [String: String] = [:]
    ) {
        self.version = version
        self.noiseSuffixesCommon = noiseSuffixesCommon
        self.noiseSuffixesFunds = noiseSuffixesFunds
        self.phrases = phrases
        self.amcShortForms = amcShortForms
    }

    /// Longest phrase first, so "Information Technology" wins over "Technology" and
    /// "Large & Mid Cap" is never mangled into "L&M Cap" by a shorter partial match.
    var phrasesByDescendingLength: [(pattern: String, replacement: String)] {
        phrases
            .sorted { lhs, rhs in
                lhs.key.count == rhs.key.count ? lhs.key < rhs.key : lhs.key.count > rhs.key.count
            }
            .map { (pattern: $0.key, replacement: $0.value) }
    }

    var amcShortFormsByDescendingLength: [(pattern: String, replacement: String)] {
        amcShortForms
            .sorted { lhs, rhs in
                lhs.key.count == rhs.key.count ? lhs.key < rhs.key : lhs.key.count > rhs.key.count
            }
            .map { (pattern: $0.key, replacement: $0.value) }
    }

    func noiseSuffixes(for type: InstrumentType) -> [String] {
        // Funds accumulate both kinds of noise ("… Fund Direct Growth" on an AMC called
        // "… Asset Management Company Limited"), so their list is additive.
        let combined = type == .mutualFund
            ? noiseSuffixesFunds + noiseSuffixesCommon
            : noiseSuffixesCommon
        // Longest first so "Mutual Fund" is consumed before "Fund" leaves "Mutual" behind.
        return combined.sorted { $0.count > $1.count }
    }

    // MARK: - Loading

    /// Bundled defaults, overridden wholesale by `name-rules.json` in the App Group container.
    ///
    /// The override is what makes §7's "extendable without a rebuild" literally true: a bundled
    /// resource still needs a new build to change.
    public static func load(paths: AppPaths? = nil, bundle: Bundle? = nil) -> NameRules {
        // `Bundle.module` is internal to the package, so it cannot be a default argument value.
        let bundle = bundle ?? .module
        if let paths {
            let override = paths.root.appending(path: "name-rules.json", directoryHint: .notDirectory)
            if let data = try? Data(contentsOf: override),
               let rules = try? JSONDecoder().decode(NameRules.self, from: data) {
                return rules
            }
        }
        if let url = bundle.url(forResource: "name-rules", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let rules = try? JSONDecoder().decode(NameRules.self, from: data) {
            return rules
        }
        return .fallback
    }

    /// Enough to keep the shortener useful if the resource is ever missing from a bundle.
    public static let fallback = NameRules(
        noiseSuffixesCommon: ["Ltd.", "Ltd", "Limited", "Corporation", "Corp", "Industries"],
        noiseSuffixesFunds: ["Fund", "Plan", "Direct", "Regular", "Growth", "Option"],
        phrases: ["Flexi Cap": "FlexiCap", "Small Cap": "SmallCap"],
        amcShortForms: ["ICICI Prudential": "ICICI Pru", "Motilal Oswal": "MO"]
    )
}
