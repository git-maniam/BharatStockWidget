import Foundation

/// Turns a full instrument name into a label that fits, without clipping mid-glyph at random (§7).
///
/// The five rules of §7 are modelled as a ladder of progressively shorter candidates; the first
/// one that fits wins. Collisions are resolved afterwards across the whole config, because a label
/// that is short but ambiguous ("Parag Parikh…" twice) is worse than one that is merely long.
public struct NameShortener: Sendable {
    public struct Request: Sendable, Equatable {
        public var type: InstrumentType
        public var symbol: String
        /// Name as published by the API.
        public var fullName: String
        /// `name` from the config. When present it wins verbatim (§7 rule 1).
        public var explicitName: String?

        public init(type: InstrumentType, symbol: String, fullName: String, explicitName: String? = nil) {
            self.type = type
            self.symbol = symbol
            self.fullName = fullName
            self.explicitName = explicitName
        }
    }

    private let rules: NameRules

    public init(rules: NameRules) {
        self.rules = rules
    }

    // MARK: - Single name

    /// The §7 ladder, longest first. Every entry is a legitimate label; later ones sacrifice more.
    ///
    /// The untouched name is rung 0 but is *not* offered to `shorten` — see `displayLadder`. It is
    /// kept only because collision resolution needs the most informative form available.
    func ladder(for request: Request, type: InstrumentType? = nil) -> [String] {
        // Rule 1: the user's choice always wins, even if it overflows — so the ladder for an
        // explicit name has exactly one rung, and only truncation may touch it.
        if let explicit = request.explicitName?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return [explicit]
        }

        let type = type ?? request.type
        let original = tidy(request.fullName)
        var rungs = [original]

        // One phrase substitution is allowed before stripping, and only when a phrase matches the
        // *entire* name: "State Bank of India" has to become "SBI" before the stripper whittles it
        // down to "State Bank". Word-level substitutions deliberately wait until rung 2, so a name
        // that already fits is never abbreviated for no reason ("Bajaj Finance", not "Bajaj Fin").
        let prePhrased = applyWholeNamePhrase(original) ?? original

        // Rule 2: strip noise suffixes.
        let stripped = stripNoiseSuffixes(prePhrased, type: type)
        if !stripped.isEmpty { rungs.appendIfNew(stripped) }

        // Rule 3: abbreviate known phrases revealed by the stripping.
        let abbreviated = applyPhrases(stripped)
        if !abbreviated.isEmpty { rungs.appendIfNew(abbreviated) }

        // Rule 4: collapse the AMC name — funds only; a stock has no AMC.
        if type == .mutualFund {
            let collapsed = collapseAMC(abbreviated)
            if !collapsed.isEmpty { rungs.appendIfNew(collapsed) }
        }

        return rungs
    }

    /// The rungs `shorten` may actually choose from.
    ///
    /// Excludes the untouched name, because §7 rule 2 is not conditional: noise suffixes are
    /// stripped whether or not the original happened to fit. Without this, a config would show
    /// "Reliance" beside "HDFC Bank Limited" purely because the latter is three characters shorter.
    func displayLadder(for request: Request) -> [String] {
        let rungs = ladder(for: request)
        guard rungs.count > 1 else { return rungs }
        return Array(rungs.dropFirst())
    }

    /// The label for one instrument, ignoring collisions.
    public func shorten(_ request: Request, maxLength: Int) -> String {
        let rungs = displayLadder(for: request)
        // Rules 1–4: stop at the first rung that fits.
        if let fits = rungs.first(where: { $0.count <= maxLength }) { return fits }
        // Rule 5: nothing fits, so truncate the shortest rung we produced.
        return truncate(rungs.last ?? request.symbol, to: maxLength)
    }

    // MARK: - Whole config

    /// Labels for every row, guaranteed distinct within this set.
    ///
    /// §8 requires that "no shortened name becomes ambiguous within the same config", which cannot
    /// be decided one name at a time: "Parag Parikh Flexi Cap Direct" and "… Regular" collapse to
    /// the same rung. Colliding rows therefore climb back up their ladder to the first rung that
    /// tells them apart, and fall back to a symbol-derived discriminator if even the full names
    /// truncate identically.
    public func shortenAll(_ requests: [Request], maxLength: Int) -> [String] {
        var labels = requests.map { shorten($0, maxLength: maxLength) }

        for group in duplicateGroups(in: labels) {
            // Climb to the first rung depth where this group's names differ. Depth 0 is the
            // untouched name, which is why the full ladder is used here and not `displayLadder`.
            var resolved = false
            let ladders = group.map { ladder(for: requests[$0]) }
            let deepest = ladders.map(\.count).max() ?? 0

            for depth in 0..<deepest {
                let candidates = ladders.map { $0[min(depth, $0.count - 1)] }
                    .map { truncate($0, to: maxLength) }
                if Set(candidates.map { $0.lowercased() }).count == group.count {
                    for (offset, index) in group.enumerated() { labels[index] = candidates[offset] }
                    resolved = true
                    break
                }
            }

            // Still identical even at full length — the classic case being the Direct and Regular
            // plans of one scheme, whose names differ only in a word the stripper removes. Append
            // whatever word actually distinguishes them; the untruncated name is always available
            // in the tooltip and accessibility label.
            if !resolved {
                let tags = discriminatingTags(for: group, requests: requests)
                for (offset, index) in group.enumerated() {
                    labels[index] = append(
                        tag: tags[offset], to: labels[index], maxLength: maxLength
                    )
                }
            }
        }
        return labels
    }

    /// For each member of a colliding group, a short tag drawn from a word that only it has.
    ///
    /// "… Direct Plan Growth" and "… Regular Plan Growth" yield "Dir" and "Reg", which is far more
    /// use than the tail of a scheme code. Falls back to the symbol when the names are genuinely
    /// word-for-word identical.
    private func discriminatingTags(for group: [Int], requests: [Request]) -> [String] {
        let wordLists = group.map { index in
            tidy(requests[index].fullName)
                .split(separator: " ")
                .map { String($0).strippedPunctuation }
                .filter { !$0.isEmpty }
        }

        return group.indices.map { position in
            let mine = wordLists[position]
            let others = Set(
                wordLists.enumerated()
                    .filter { $0.offset != position }
                    .flatMap { $0.element.map { $0.lowercased() } }
            )
            if let unique = mine.first(where: { !others.contains($0.lowercased()) }) {
                return unique.count <= 4 ? unique : String(unique.prefix(3))
            }
            let symbol = requests[group[position]].symbol
            return requests[group[position]].type == .mutualFund
                ? String(symbol.suffix(3))
                : symbol
        }
    }

    private func append(tag: String, to label: String, maxLength: Int) -> String {
        let suffix = " \(tag)"
        let room = maxLength - suffix.count
        guard room >= 3 else { return String(tag.prefix(maxLength)) }
        return truncate(label, to: room) + suffix
    }

    private func duplicateGroups(in labels: [String]) -> [[Int]] {
        var byLabel: [String: [Int]] = [:]
        for (index, label) in labels.enumerated() {
            byLabel[label.lowercased(), default: []].append(index)
        }
        return byLabel.values.filter { $0.count > 1 }.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }

    /// Appends the last few characters of the symbol, which is what actually differs.
    // MARK: - Rules

    /// Collapses whitespace and removes punctuation that is only there as a separator.
    ///
    /// AMFI names are littered with " - " between the scheme, plan and option. Left in place, a
    /// lone "-" blocks suffix stripping — "DSP Technology Fund - Direct Plan - Growth" would strip
    /// back only as far as "DSP Technology Fund -" — and a trailing hyphen glued to a word
    /// ("Axis ELSS- Tax Saver") wastes a character. Internal hyphens are preserved, so "Mid-Cap"
    /// survives intact.
    func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.allSatisfy(Self.separatorCharacters.contains) }
            .map { word in
                var word = word
                while let last = word.last, Self.separatorCharacters.contains(last), word.count > 1 {
                    word.removeLast()
                }
                return word
            }
            .joined(separator: " ")
    }

    private static let separatorCharacters: Set<Character> = ["-", "–", "—", "|", "·", ",", ":", ";"]

    private func normaliseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Removes trailing noise words repeatedly, e.g.
    /// "Parag Parikh Flexi Cap Fund Direct Growth" → "Parag Parikh Flexi Cap".
    ///
    /// §7 calls this "one pass", which is read here as one traversal from the end that keeps
    /// consuming while the tail matches — stripping only the final word would leave
    /// "… Fund Direct" behind and miss the point of the rule.
    func stripNoiseSuffixes(_ text: String, type: InstrumentType) -> String {
        let suffixes = rules.noiseSuffixes(for: type)
        var words = tidy(text).split(separator: " ").map(String.init)

        var changed = true
        while changed, words.count > 1 {
            changed = false
            for suffix in suffixes {
                let suffixWords = suffix.split(separator: " ").map(String.init)
                guard suffixWords.count < words.count,
                      words.suffix(suffixWords.count).map({ $0.strippedPunctuation.lowercased() })
                        == suffixWords.map({ $0.strippedPunctuation.lowercased() })
                else { continue }
                words.removeLast(suffixWords.count)
                changed = true
                break
            }
        }
        return words.joined(separator: " ")
    }

    /// A phrase whose key is the whole name, e.g. "State Bank of India" → "SBI".
    func applyWholeNamePhrase(_ text: String) -> String? {
        let subject = tidy(text)
        return rules.phrases.first { $0.key.caseInsensitiveCompare(subject) == .orderedSame }?.value
    }

    func applyPhrases(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in rules.phrasesByDescendingLength {
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: [.caseInsensitive]
            )
        }
        return normaliseWhitespace(result)
    }

    func collapseAMC(_ text: String) -> String {
        for (pattern, replacement) in rules.amcShortFormsByDescendingLength {
            guard text.range(of: pattern, options: [.caseInsensitive, .anchored]) != nil else { continue }
            let remainder = text.dropFirst(pattern.count)
            return normaliseWhitespace(replacement + remainder)
        }
        return text
    }

    /// Rule 5: truncate to `maxLength` *graphemes*, preferring a word boundary, and append `…`.
    ///
    /// The ellipsis is included in the budget, so the result never exceeds `maxLength`. A word
    /// boundary is only taken when it keeps most of the allowance: cutting "Reliance Industries"
    /// back to "Reliance…" throws away more than it saves, so that case falls through to a hard
    /// grapheme cut ("Reliance Industri…") which stays informative.
    func truncate(_ text: String, to maxLength: Int) -> String {
        guard maxLength > 1 else { return String(text.prefix(max(0, maxLength))) }
        guard text.count > maxLength else { return text }

        let budget = maxLength - 1  // room for "…"
        let hardCut = String(text.prefix(budget))

        if let lastSpace = hardCut.lastIndex(of: " ") {
            let wordCut = String(hardCut[hardCut.startIndex..<lastSpace])
                .trimmingCharacters(in: .whitespaces)
            if wordCut.count * 5 >= budget * 3 {  // keeps at least 60% of the allowance
                return wordCut + "…"
            }
        }
        return hardCut.trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension String {
    /// Lets "Ltd." match "Ltd" and "ELSS-" match "ELSS".
    fileprivate var strippedPunctuation: String {
        trimmingCharacters(in: CharacterSet(charactersIn: ".,-–—·"))
    }
}

extension [String] {
    /// Keeps the ladder free of consecutive duplicates, so rung depth means something.
    fileprivate mutating func appendIfNew(_ value: String) {
        guard last != value else { return }
        append(value)
    }
}
