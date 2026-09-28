import Foundation
import Testing
@testable import BharatStockCore

@Suite("Name shortening")
struct NameShortenerTests {
    let shortener = NameShortener(rules: NameRules.load())

    /// Twenty real NSE company names as the API returns them.
    static let stockNames: [(symbol: String, fullName: String)] = [
        ("RELIANCE", "Reliance Industries Limited"),
        ("TCS", "Tata Consultancy Services Limited"),
        ("HDFCBANK", "HDFC Bank Limited"),
        ("INFY", "Infosys Limited"),
        ("ICICIBANK", "ICICI Bank Limited"),
        ("HINDUNILVR", "Hindustan Unilever Limited"),
        ("BHARTIARTL", "Bharti Airtel Limited"),
        ("SBIN", "State Bank of India"),
        ("LT", "Larsen & Toubro Limited"),
        ("KOTAKBANK", "Kotak Mahindra Bank Limited"),
        ("BAJFINANCE", "Bajaj Finance Limited"),
        ("ASIANPAINT", "Asian Paints Limited"),
        ("MARUTI", "Maruti Suzuki India Limited"),
        ("SUNPHARMA", "Sun Pharmaceutical Industries Limited"),
        ("TITAN", "Titan Company Limited"),
        ("ULTRACEMCO", "UltraTech Cement Limited"),
        ("ONGC", "Oil & Natural Gas Corporation Limited"),
        ("POWERGRID", "Power Grid Corporation of India Limited"),
        ("TATAMOTORS", "Tata Motors Limited"),
        ("ADANIENT", "Adani Enterprises Limited"),
    ]

    /// Twenty real AMFI scheme names, including the near-identical Direct/Regular pairs that make
    /// ambiguity a real risk rather than a theoretical one.
    static let fundNames: [(code: String, fullName: String)] = [
        ("122639", "Parag Parikh Flexi Cap Fund - Direct Plan - Growth"),
        ("122640", "Parag Parikh Flexi Cap Fund - Regular Plan - Growth"),
        ("120828", "Quant Small Cap Fund - Direct Plan Growth Option"),
        ("120503", "Axis ELSS- Tax Saver Fund - Direct Plan - Growth"),
        ("119551", "ICICI Prudential Bluechip Fund - Direct Plan - Growth"),
        ("118989", "HDFC Mid-Cap Opportunities Fund - Direct Plan - Growth"),
        ("125497", "Mirae Asset Large Cap Fund - Direct Plan - Growth"),
        ("147946", "Motilal Oswal Nasdaq 100 Fund of Fund - Direct Plan Growth"),
        ("120716", "SBI Bluechip Fund - Direct Plan - Growth"),
        ("118533", "Nippon India Small Cap Fund - Direct Plan - Growth"),
        ("112932", "UTI Nifty 50 Index Fund - Direct Plan - Growth"),
        ("119775", "Kotak Emerging Equity Fund - Direct Plan - Growth"),
        ("135800", "Aditya Birla Sun Life Frontline Equity Fund - Direct Plan - Growth"),
        ("133386", "DSP Technology Fund - Direct Plan - Growth"),
        ("101206", "Franklin India Prima Fund - Direct Plan - Growth"),
        ("146126", "Canara Robeco Small Cap Fund - Direct Plan - Growth"),
        ("149951", "Edelweiss Balanced Advantage Fund - Direct Plan - Growth"),
        ("143880", "Invesco India Financial Services Fund - Direct Plan - Growth"),
        ("120586", "Tata Digital India Fund - Direct Plan - Growth"),
        ("118269", "Quantum Long Term Equity Value Fund - Direct Plan - Growth"),
    ]

    // MARK: - Invariants

    @Test("Every stock name fits the limit", arguments: [12, 18, 24])
    func stockNamesFit(maxLength: Int) {
        for (symbol, fullName) in Self.stockNames {
            let label = shortener.shorten(
                .init(type: .stock, symbol: symbol, fullName: fullName), maxLength: maxLength
            )
            #expect(label.count <= maxLength, "\(fullName) → \"\(label)\" (\(label.count) > \(maxLength))")
            #expect(!label.isEmpty)
        }
    }

    @Test("Every fund name fits the limit", arguments: [12, 18, 24])
    func fundNamesFit(maxLength: Int) {
        for (code, fullName) in Self.fundNames {
            let label = shortener.shorten(
                .init(type: .mutualFund, symbol: code, fullName: fullName), maxLength: maxLength
            )
            #expect(label.count <= maxLength, "\(fullName) → \"\(label)\" (\(label.count) > \(maxLength))")
            #expect(!label.isEmpty)
        }
    }

    @Test("No two labels in one config collide", arguments: [12, 18, 24])
    func noAmbiguityWithinAConfig(maxLength: Int) {
        let requests =
            Self.stockNames.map {
                NameShortener.Request(type: .stock, symbol: $0.symbol, fullName: $0.fullName)
            }
            + Self.fundNames.map {
                NameShortener.Request(type: .mutualFund, symbol: $0.code, fullName: $0.fullName)
            }

        let labels = shortener.shortenAll(requests, maxLength: maxLength)

        #expect(labels.count == requests.count)
        let unique = Set(labels.map { $0.lowercased() })
        #expect(
            unique.count == labels.count,
            "collisions: \(Dictionary(grouping: labels, by: { $0.lowercased() }).filter { $0.value.count > 1 })"
        )
        for label in labels {
            #expect(label.count <= maxLength, "\"\(label)\" exceeds \(maxLength)")
        }
    }

    @Test("The Direct/Regular pair of the same scheme stays distinguishable")
    func directVersusRegular() {
        let requests = [
            NameShortener.Request(
                type: .mutualFund, symbol: "122639",
                fullName: "Parag Parikh Flexi Cap Fund - Direct Plan - Growth"
            ),
            NameShortener.Request(
                type: .mutualFund, symbol: "122640",
                fullName: "Parag Parikh Flexi Cap Fund - Regular Plan - Growth"
            ),
        ]
        let labels = shortener.shortenAll(requests, maxLength: 18)
        #expect(labels[0].lowercased() != labels[1].lowercased(), "both became \"\(labels[0])\"")
    }

    // MARK: - Individual rules

    @Test("Rule 1: an explicit name wins verbatim when it fits")
    func explicitNameWins() {
        let label = shortener.shorten(
            .init(
                type: .stock, symbol: "RELIANCE",
                fullName: "Reliance Industries Limited", explicitName: "Big Oil"
            ),
            maxLength: 18
        )
        #expect(label == "Big Oil")
    }

    @Test("Rule 1: an overlong explicit name is truncated, never abbreviated")
    func explicitNameTruncatedNotRewritten() {
        let label = shortener.shorten(
            .init(
                type: .mutualFund, symbol: "122639",
                fullName: "ignored", explicitName: "Parag Parikh Flexi Cap"
            ),
            maxLength: 18
        )
        #expect(label.count <= 18)
        #expect(label.hasSuffix("…"))
        // The phrase table would have produced "FlexiCap"; rule 1 forbids that.
        #expect(!label.contains("FlexiCap"))
    }

    @Test("Rule 2: trailing noise words are stripped, repeatedly")
    func stripsNoiseSuffixes() {
        #expect(
            shortener.stripNoiseSuffixes("Reliance Industries Limited", type: .stock) == "Reliance"
        )
        #expect(
            shortener.stripNoiseSuffixes(
                "Parag Parikh Flexi Cap Fund Direct Growth", type: .mutualFund
            ) == "Parag Parikh Flexi Cap"
        )
        #expect(
            shortener.stripNoiseSuffixes("Titan Company Limited", type: .stock) == "Titan"
        )
    }

    @Test("Rule 2: stripping never empties a name")
    func neverStripsEverything() {
        // Every word is noise. The rule must leave something behind rather than return "".
        let label = shortener.shorten(
            .init(type: .mutualFund, symbol: "1", fullName: "Fund Growth Direct Plan"),
            maxLength: 18
        )
        #expect(!label.isEmpty)
    }

    @Test("Rule 3: phrases are abbreviated longest-match-first")
    func abbreviatesPhrases() {
        #expect(shortener.applyPhrases("Quant Small Cap") == "Quant SmallCap")
        // "Information Technology" must not be mangled by the shorter "Technology" entry.
        #expect(shortener.applyPhrases("Information Technology") == "IT")
        #expect(shortener.applyPhrases("Financial Services") == "Fin Svcs")
    }

    @Test("Rule 4: a fund's AMC prefix collapses to its short form")
    func collapsesAMC() {
        #expect(shortener.collapseAMC("Motilal Oswal Nasdaq 100") == "MO Nasdaq 100")
        #expect(shortener.collapseAMC("ICICI Prudential Bluechip") == "ICICI Pru Bluechip")
        // Not a prefix, so nothing happens — an AMC name mid-string is part of the scheme name.
        #expect(shortener.collapseAMC("Nasdaq Motilal Oswal") == "Nasdaq Motilal Oswal")
    }

    @Test("Rule 5: truncation lands on a word boundary when that keeps enough of the name")
    func truncatesAtWordBoundary() {
        #expect(shortener.truncate("Aditya Birla Sun Life Frontline", to: 18) == "Aditya Birla Sun…")
        // A word cut here would leave just "Reliance", throwing away most of the allowance,
        // so a hard grapheme cut is preferred as it stays more informative.
        #expect(shortener.truncate("Reliance Industries", to: 18) == "Reliance Industri…")
    }

    @Test("Rule 5: the result never exceeds the limit, ellipsis included")
    func truncationRespectsBudget() {
        for maxLength in 4...30 {
            let label = shortener.truncate("Aditya Birla Sun Life Frontline Equity", to: maxLength)
            #expect(label.count <= maxLength, "\"\(label)\" is \(label.count) > \(maxLength)")
        }
    }

    @Test("A name that already fits is returned untouched")
    func shortNamesUnchanged() {
        #expect(shortener.shorten(.init(type: .stock, symbol: "INFY", fullName: "Infosys"), maxLength: 18) == "Infosys")
    }
}
