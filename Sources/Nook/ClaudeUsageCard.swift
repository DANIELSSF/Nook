import SwiftUI
import AppKit

// Claude's usage panel (/usage) as Nook draws it: a dashboard of its own in the panel's place, all of it at once.
//
// Claude's panel is a screen of text that runs for three screens: what the session cost, how long it ran and what it changed in the code; the tokens each model used;
// the prompt cache; the plugins' footprint; the limits with their bars and when they reset; and Claude's reading of what spends them. The card shows every part
// of it as a small section, side by side in as many columns as it is wide, with nothing behind a disclosure. Claude's own "más" stays only while Nook holds a
// part of the panel (a Terminal tab shows what its screen shows): `ClaudeUsage.complete` says when it holds all of it.
//
//   UsageContent      the dashboard: the limits and the session in bands across the card, the other sections in columns under them, and the "más" of a panel that is not whole
//   UsageMasonry      the columns: as many as the width allows, the sections put where the columns end lowest
//   UsageTileGrid     the tiles of a section (the limits, the session's figures) in rows, as many to a row as the width allows
//   UsageSection      a section's frame: its symbol, its title and what stands at its end
//   Usage…Section     the limits, the session, the tokens per model, the plugins and what spends the limits
//   UsageMeterView    one limit: its name, its percent, its bar and its reset
//   UsageBar          the bar
//   UsageFigures      the numbers and names of the panel, worked out from Claude's words (plain values, so they are tested without a window)
//
// The words are Spanish (`UsageWords` has Claude's, and gives back what it does not know unchanged: the card never loses a line to a translation). Whatever the
// card cannot place (`ClaudeUsage.leftovers`) is drawn modestly at the end, as the generic panel draws it.

// MARK: - Figures

enum UsageFigures {
    /// A count as Claude prints it: "23.5k" is 23 500, "2.0m" is 2 000 000, "381" is 381. nil for anything else.
    static func count(_ text: String?) -> Double? {
        guard var number = text?.trimmingCharacters(in: .whitespaces).lowercased(), !number.isEmpty else { return nil }
        var factor = 1.0
        if let last = number.last, "kmb".contains(last) {
            factor = last == "k" ? 1e3 : last == "m" ? 1e6 : 1e9
            number.removeLast()
        }
        return Double(number.replacingOccurrences(of: ",", with: "")).map { $0 * factor }
    }

    /// An amount of money: "$1.75" is 1.75.
    static func dollars(_ text: String?) -> Double? {
        guard let text else { return nil }
        return Double(text.trimmingCharacters(in: .whitespaces).drop { $0 == "$" }.replacingOccurrences(of: ",", with: ""))
    }

    /// A percentage as a share of the whole: "42%" is 0.42. nil for anything else.
    static func share(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%"), let value = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(1, max(0, value / 100))
    }

    /// A reset in Spanish apart from the zone it names: "Se reinicia el 13 oct a las 6 a. m. (America/Bogota)" is its words and "America/Bogota".
    static func zoneSplit(_ resets: String) -> (words: String, zone: String?) {
        let text = resets.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return (text, nil) }
        let zone = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        // A zone is one word of the clock's database ("America/Bogota", "UTC"): what is in parentheses after other words is not one.
        guard !zone.isEmpty, !zone.contains(" "), zone.contains("/") || zone.uppercased() == zone else { return (text, nil) }
        return (String(text[..<open]).trimmingCharacters(in: .whitespaces), zone)
    }

    /// A reset in few words, for a tile: "Se reinicia el 13 oct a las 6 a. m." is "Reinicia el 13 oct · 6 a. m."; "Se reinicia a las 1 p. m." is "Reinicia a las 1 p. m.".
    /// What does not start the way Claude's resets do keeps its words.
    static func shortReset(_ words: String) -> String {
        let lead = "Se reinicia"
        guard words.hasPrefix(lead) else { return words }
        var text = "Reinicia" + words.dropFirst(lead.count)
        if text.contains(" el "), let range = text.range(of: " a las ") { text.replaceSubrange(range, with: " · ") }
        return text
    }

    /// A line of the card's text with what belongs together kept together when the line has to break: a command Claude mentions ("/compact") stays with its slash
    /// (a word joiner after it, which has no width), a time ("6 a. m.") is one piece, and a dot that separates two parts ends the line it follows and does not begin
    /// the next (no-break spaces). Only for what is drawn: what is spoken and what is compared is the text as it was.
    static func unbroken(_ text: String) -> String {
        let commands = text.replacingOccurrences(of: #"(?<![\p{L}\p{N}/.:~])/(?=[a-z])"#, with: "/\u{2060}", options: .regularExpression)
        let times = commands.replacingOccurrences(of: #"(\d) ([ap])\. m\."#, with: "$1\u{00A0}$2.\u{00A0}m.", options: .regularExpression)
        return times.replacingOccurrences(of: " · ", with: "\u{00A0}· ")
    }

    /// The zone every limit's reset names, when they all name the same: the card says it once.
    static func commonZone(of resets: [String?]) -> String? {
        let zones = resets.compactMap { $0.map(UsageWords.resets).flatMap { zoneSplit($0).zone } }
        guard let first = zones.first, zones.count == resets.compactMap({ $0 }).count, zones.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// A limit's title apart from what it is for: "Semana actual (todos los modelos)" is "Semana actual" and "todos los modelos".
    static func titleParts(_ title: String) -> (main: String, detail: String?) {
        let text = title.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(")"), let open = text.firstIndex(of: "("), open > text.startIndex else { return (text, nil) }
        let detail = String(text[text.index(after: open)..<text.index(before: text.endIndex)]).trimmingCharacters(in: .whitespaces)
        let main = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        return main.isEmpty || detail.isEmpty ? (text, nil) : (main, detail)
    }

    /// A model as Claude's panel names it ("claude-opus-5-5") the way the island names it: "Opus 5.5". An id with a date ("claude-sonnet-4-5-20250929") is
    /// "Sonnet 4.5", an older one ("claude-3-5-haiku-20241022") "Haiku 3.5"; a name that is not an id stays as it is.
    static func modelName(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("claude-") else { return text }
        var body = String(text.dropFirst("claude-".count))
        if let bracket = body.firstIndex(of: "[") { body = String(body[..<bracket]) }
        let parts = body.split(separator: "-").map(String.init).filter { !($0.count >= 6 && $0.allSatisfy(\.isNumber)) }
        let words = parts.filter { part in part.contains { $0.isLetter } }
        let numbers = parts.filter { part in part.allSatisfy(\.isNumber) }
        guard let family = words.first else { return text }
        var name = family.prefix(1).uppercased() + family.dropFirst()
        for word in words.dropFirst() { name += " " + word.prefix(1).uppercased() + word.dropFirst() }
        return numbers.isEmpty ? name : name + " " + numbers.joined(separator: ".")
    }

    /// A section's heading in the card: `UsageWords.section`'s, but for the one question that is too long for a header with a badge and a note beside it.
    static func heading(_ title: String) -> String {
        let words = UsageWords.section(title)
        return words == "¿Qué está consumiendo tus límites?" ? "¿Qué consume tus límites?" : words
    }

    // MARK: The prompt cache

    /// What Claude's one line about the prompt cache says, part by part: "22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m
    /// 11s ago)". Every part that is not one of these is kept, in Spanish where `UsageWords` can, in `rest`.
    struct Cache: Equatable {
        enum State: Equatable {
            case warm(ttl: String, idle: String)
            case cold(idle: String, tokens: String)
        }

        var requests: Int?
        /// How much of the input came from the cache, 0…100.
        var percent: Int?
        var state: State?
        /// "sin fallos", "3 fallos".
        var misses: String?
        var rest: [String] = []

        var isEmpty: Bool { requests == nil && percent == nil && state == nil && misses == nil && rest.isEmpty }
    }

    static func cache(_ text: String) -> Cache {
        var cache = Cache()
        for raw in text.components(separatedBy: " · ") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if let found = capture(#"^(\d+) requests?$"#, in: part)?.first { cache.requests = Int(found) }
            else if let found = capture(#"^(\d+)% of input tokens from cache$"#, in: part)?.first { cache.percent = Int(found) }
            else if part == "no misses" { cache.misses = "sin fallos" }
            else if let found = capture(#"^(\d+) (?:cache )?misses?$"#, in: part)?.first { cache.misses = found == "1" ? "1 fallo" : "\(found) fallos" }
            else if let found = capture(#"^warm \((\S+) TTL, last activity (.+) ago\)$"#, in: part), found.count == 2 { cache.state = .warm(ttl: found[0], idle: found[1]) }
            else if let found = capture(#"^cold — idle ([^,]+), next turn re-caches (.+) tokens$"#, in: part), found.count == 2 { cache.state = .cold(idle: found[0], tokens: found[1]) }
            else if !part.isEmpty { cache.rest.append(UsageWords.promptCache(part)) }
        }
        return cache
    }

    /// The text of the capture groups of `pattern` over the whole of `text`, or nil when it does not match.
    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)), match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : (text as NSString).substring(with: range)
        }
    }
}

// MARK: - Measures

/// The card's sizes, which follow the chat's text size a little: it is dense, and the island small.
struct UsageMetrics: Equatable {
    var unit: CGFloat
    /// The card has little height to show in (the usual island's): what matters most (the limits, and the session's four figures) is made to fit one screen.
    var dense: Bool

    init(chatSize: Double = DisplaySettings.defaultChatSize, dense: Bool = false) {
        unit = min(1.35, max(0.88, 1 + CGFloat(chatSize - DisplaySettings.defaultChatSize) * 0.045))
        self.dense = dense
    }

    /// How short the card's room has to be (the content's height, under the toolbar) for it to count as little: the usual island leaves about 160 pt, a wide one 240.
    static let denseBelow: CGFloat = 200

    /// The padding inside a section.
    var inset: CGFloat { self(dense ? 7.5 : 10) }

    func callAsFunction(_ points: CGFloat) -> CGFloat { points * unit }

    static let primary = Color.primary.opacity(0.92)
    /// The card's small labels are read: the island's secondary text, which keeps 4.5 : 1 on the paper.
    static let secondary = Color.nookSecondary
    static let quiet = Color.nookSecondary
    static let track = Color.nookWash(0.1, light: 0.12)
    /// What is said in these colours is read (a note, a figure): the deep shades on the paper. What is only drawn is in `PanelBar.color(for:)`.
    static let amber = Color.nookAmber
    static let mint = Color.nookMint
    static let coral = Color.nookCoral
}

// MARK: - The columns

/// Its sections in as many columns as the width allows (at least `minColumn` points each, three at most), put where the columns end lowest: every way of dividing
/// them between the columns is tried (each keeps its order inside its column, and the first is always at the top of the first), and of those that end equally low
/// the one that keeps the earlier sections to the left. Each section is given its column's width and its own height.
struct UsageMasonry: Layout {
    var gap: CGFloat
    var minColumn: CGFloat
    var maxColumns = 3

    func columns(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, min(maxColumns, Int(((width + gap) / (minColumn + gap)).rounded(.down))))
    }

    /// Where each section stands, and how tall they are together.
    func arrange(heights: [CGFloat], width: CGFloat) -> (origins: [(column: Int, y: CGFloat)], height: CGFloat) {
        let count = columns(for: width)
        let assignment = count > 1 && heights.count > 1 && heights.count <= 10 ? lowest(heights, columns: count) : [Int](repeating: 0, count: heights.count)
        var filled = [CGFloat](repeating: 0, count: count)
        var origins = [(column: Int, y: CGFloat)](repeating: (0, 0), count: heights.count)
        for (index, column) in assignment.enumerated() {
            let y = filled[column] > 0 ? filled[column] + gap : 0
            origins[index] = (column, y)
            filled[column] = y + heights[index]
        }
        return (origins, filled.max() ?? 0)
    }

    /// The column of each section in the division that ends lowest. A new column opens only after the one before it has a section (so no division is tried twice
    /// with its columns swapped), and an earlier division wins a tie.
    private func lowest(_ heights: [CGFloat], columns count: Int) -> [Int] {
        var best = [Int](repeating: 0, count: heights.count)
        var bestHeight = CGFloat.greatestFiniteMagnitude
        var assignment = best
        func tallest() -> CGFloat {
            var filled = [CGFloat](repeating: 0, count: count)
            for (index, column) in assignment.enumerated() { filled[column] += (filled[column] > 0 ? gap : 0) + heights[index] }
            return filled.max() ?? 0
        }
        func divide(_ index: Int, opened: Int) {
            guard index < heights.count else {
                let height = tallest()
                if height < bestHeight - 0.5 { best = assignment; bestHeight = height }
                return
            }
            for column in 0..<min(count, opened + 1) {
                assignment[index] = column
                divide(index + 1, opened: max(opened, column + 1))
            }
        }
        divide(0, opened: 0)
        return best
    }

    private func heights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        let count = columns(for: width)
        let columnWidth = (width - gap * CGFloat(count - 1)) / CGFloat(count)
        return subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumn
        return CGSize(width: width, height: arrange(heights: heights(subviews, width: width), width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = columns(for: bounds.width)
        let columnWidth = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let placed = arrange(heights: heights(subviews, width: bounds.width), width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let origin = placed.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(origin.column) * (columnWidth + gap), y: bounds.minY + origin.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: columnWidth, height: nil))
        }
    }
}

// MARK: - The tiles of a section

/// Tiles in rows of equal columns: as many to a row as the width allows (at least `minTile` points each), the tiles divided between the rows evenly (four are
/// two and two, not three and one). The tiles of a row are as tall as the tallest.
struct UsageTileGrid: Layout {
    var minTile: CGFloat
    var gap: CGFloat
    var rowGap: CGFloat

    func columns(count: Int, width: CGFloat) -> Int {
        guard count > 0, width.isFinite, width > 0 else { return 1 }
        let widest = min(count, max(1, Int(((width + gap) / (minTile + gap)).rounded(.down))))
        let rows = Int((Double(count) / Double(widest)).rounded(.up))
        return Int((Double(count) / Double(rows)).rounded(.up))
    }

    private func measure(_ subviews: Subviews, width: CGFloat) -> (columns: Int, tile: CGFloat, rows: [CGFloat]) {
        let columns = columns(count: subviews.count, width: width)
        let tile = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        var rows: [CGFloat] = []
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height
            if index % columns == 0 { rows.append(height) } else { rows[rows.count - 1] = max(rows[rows.count - 1], height) }
        }
        return (columns, tile, rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minTile
        let measured = measure(subviews, width: width)
        return CGSize(width: width, height: measured.rows.reduce(0, +) + rowGap * CGFloat(max(0, measured.rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measure(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in measured.rows.enumerated() {
            for column in 0..<measured.columns {
                let index = row * measured.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (measured.tile + gap), y: y), anchor: .topLeading, proposal: ProposedViewSize(width: measured.tile, height: height))
            }
            y += height + rowGap
        }
    }
}

// MARK: - A section's frame

private struct UsageSection<Accessory: View, Content: View>: View {
    var symbol: String
    var title: String
    var metrics: UsageMetrics
    /// The section has no heading of its own where its figures say what they are (the session's strip in a short card).
    var showsHeader = true
    var accessory: Accessory
    var content: Content

    init(symbol: String, title: String, metrics: UsageMetrics, showsHeader: Bool = true, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.title = title
        self.metrics = metrics
        self.showsHeader = showsHeader
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: metrics(metrics.dense ? 6 : 8)) {
            if showsHeader {
                HStack(spacing: metrics(6)) {
                    Image(systemName: symbol).font(.system(size: metrics(9.5), weight: .semibold)).foregroundStyle(UsageMetrics.secondary).frame(width: metrics(12))
                    // The title keeps its room; what stands at the header's end gives way (it wraps or shortens) rather than push the section wider than the card.
                    Text(title).font(.system(size: metrics(10.5), weight: .semibold)).foregroundStyle(UsageMetrics.primary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: metrics(4))
                    accessory
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nookWash(0.04), in: shape)
        .overlay(shape.strokeBorder(Color.nookWash(0.07), lineWidth: 0.6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private extension UsageSection where Accessory == EmptyView {
    init(symbol: String, title: String, metrics: UsageMetrics, showsHeader: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, title: title, metrics: metrics, showsHeader: showsHeader, accessory: { EmptyView() }, content: content)
    }
}

/// A small note at a section's end that explains it: the words Claude puts under a title, behind a mark that says so when the pointer rests on it.
private struct UsageNote: View {
    var title: String
    var text: String
    var metrics: UsageMetrics

    var body: some View {
        Image(systemName: "info.circle").font(.system(size: metrics(10), weight: .regular)).foregroundStyle(UsageMetrics.quiet)
            .frame(width: metrics(18), height: metrics(18)).contentShape(Rectangle())
            .nookTip(NookTip(title, detail: text), id: "usage-note-" + title)
            .accessibilityElement().accessibilityLabel(title).accessibilityValue(text)
    }
}

// MARK: - The bar

/// A limit's bar: a rounded track with its fill, in the colour of how full it is. Drawn with fills only (a stroked capsule leaves ticks at its ends).
struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(UsageMetrics.track)
                if fraction > 0.004 {
                    Capsule().fill(LinearGradient(colors: [color.opacity(0.82), color], startPoint: .top, endPoint: .bottom))
                        .frame(width: max(height, proxy.size.width * CGFloat(min(1, fraction))))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - The limits

/// One limit: its name, how full it is, the bar, and when it resets.
struct UsageMeterView: View {
    let meter: ClaudeUsage.Meter
    var metrics = UsageMetrics()
    /// The reset names its zone; false when the section says it once for all of them.
    var showsZone = true
    /// The title takes two lines even when what the limit is for has no words, so that limits side by side have their bars level.
    var reservesDetail = false
    /// When Claude's status line gave the figures that came from it (`meter.source`, `meter.resetsSource`): the dot beside them says so.
    var since: Date?
    /// The dollars of a spend limit, under its reset.
    var spend: String?

    var body: some View {
        let percent = UsageWords.percent(meter.label)
        let title = UsageFigures.titleParts(UsageWords.title(meter.title))
        let resets = meter.resets.map(UsageWords.resets).map(UsageFigures.zoneSplit)
        let tint = PanelBar.color(for: meter.fraction)
        // The big percent is read, so it has the shade that reads (the bar under it is only drawn).
        let ink = PanelBar.ink(for: meter.fraction)
        VStack(alignment: .leading, spacing: metrics(metrics.dense ? 3 : 4)) {
            VStack(alignment: .leading, spacing: 1) {
                // The percent says "usado" where the tile has the room for it, and is the number alone where it does not.
                ViewThatFits(in: .horizontal) {
                    titleRow(title.main, percent, tint: ink, words: true)
                    titleRow(title.main, percent, tint: ink, words: false)
                }
                // What the limit is for has the tile's whole width: the percent stands beside the name only.
                if let detail = title.detail {
                    Text(detail).font(.system(size: metrics(9.5))).foregroundStyle(UsageMetrics.secondary).lineLimit(1)
                } else if reservesDetail {
                    Text(" ").font(.system(size: metrics(9.5)))
                }
            }
            UsageBar(fraction: meter.fraction, color: tint, height: metrics(6))
            if let resets { resetLine(resets) }
            if let spend {
                Text(spend).font(.system(size: metrics(9.5), design: .rounded).monospacedDigit()).foregroundStyle(UsageMetrics.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(meter.notes.enumerated()), id: \.offset) { _, note in
                Text(UsageFigures.unbroken(UsageWords.insight(note))).font(.system(size: metrics(9.5))).foregroundStyle(UsageMetrics.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageWords.title(meter.title))
        .accessibilityValue(([percent.value + (percent.rest.isEmpty ? "" : " " + percent.rest), resets.map { $0.words + ($0.zone.map { " (\($0))" } ?? "") }, spend,
                              meter.source == .live || meter.resetsSource == .live ? "en vivo" : nil] + meter.notes.map { Optional($0) })
            .compactMap { $0 }.joined(separator: ". "))
    }

    private func titleRow(_ name: String, _ percent: (value: String, rest: String), tint: Color, words: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics(6)) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(name).font(.system(size: metrics(11), weight: .medium)).foregroundStyle(UsageMetrics.primary).lineLimit(1).minimumScaleFactor(0.85)
                if meter.source == .live { UsageLiveMark(since: since, metrics: metrics, id: "limit-" + meter.title).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + metrics(3.5) } }
            }
            Spacer(minLength: metrics(4))
            figure(percent, tint: tint, words: words)
        }
    }

    /// The number is what the eye goes to: big, and in the colour of the bar once it is nearly full.
    private func figure(_ percent: (value: String, rest: String), tint: Color, words: Bool) -> some View {
        let high = meter.fraction >= 0.8
        let number = percent.rest.isEmpty ? percent.value : String(percent.value.dropLast(2))
        let suffix = percent.rest.isEmpty ? "" : (words ? " % usado" : " %")
        return (Text(number).font(.system(size: metrics(15), weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(high ? tint : UsageMetrics.primary)
            + Text(suffix).font(.system(size: metrics(9.5))).foregroundStyle(UsageMetrics.secondary))
            .lineLimit(1).fixedSize()
    }

    private func resetLine(_ resets: (words: String, zone: String?)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics(4)) {
            Image(systemName: "clock").font(.system(size: metrics(8), weight: .medium))
            Text(UsageFigures.unbroken(UsageFigures.shortReset(resets.words) + (showsZone ? (resets.zone.map { " (\($0))" } ?? "") : ""))).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            // The figures of the limit are the panel's and only its next reset is the status line's (the panel's had passed): the dot is here, where it is true.
            if meter.resetsSource == .live, meter.source != .live { UsageLiveMark(since: since, metrics: metrics, id: "reset-" + meter.title) }
        }.font(.system(size: metrics(9.5))).foregroundStyle(UsageMetrics.secondary)
    }
}

/// The limits, side by side where the width allows: they are what anyone opens the panel for, so they stand across the whole card, at its top.
private struct UsageLimitsSection: View {
    var meters: [ClaudeUsage.Meter]
    var metrics: UsageMetrics
    /// What Claude's status line gave, with when: the dots beside what came from it, and the spend limit's dollars.
    var live: ClaudeLiveUsage?

    var body: some View {
        let zone = UsageFigures.commonZone(of: meters.map(\.resets))
        UsageSection(symbol: UsageButton.symbol, title: "Límites", metrics: metrics, accessory: {
            if let zone { Text(zone).font(.system(size: metrics(9), design: .monospaced)).foregroundStyle(UsageMetrics.quiet).lineLimit(1).truncationMode(.head) }
        }, content: {
            UsageTileGrid(minTile: metrics(128), gap: metrics(metrics.dense ? 14 : 16), rowGap: metrics(metrics.dense ? 9 : 12)) {
                ForEach(Array(meters.enumerated()), id: \.offset) { _, meter in
                    UsageMeterView(meter: meter, metrics: metrics, showsZone: zone == nil, reservesDetail: true, since: live?.limitsAt,
                                   spend: meter.title.caseInsensitiveCompare("Spend limit") == .orderedSame ? UsageLive.spend(live?.limits?.spendLimit) : nil)
                }
            }
        })
    }
}

// MARK: - The session

/// One figure of the session: what it is, the figure, and a line under it. The figure is a `Text` so that a part of it can have a colour of its own (the lines added
/// and the lines removed); the cell sets its size.
private struct UsageStatCell: View {
    var label: String
    var value: Text
    var caption: String?
    var captionTint = UsageMetrics.secondary
    /// What the cell says when the pointer rests on it: what its caption would say in a card with the room for it.
    var tip: NookTip?
    var tipID = ""
    var spoken: String
    var metrics: UsageMetrics
    /// The figure came from Claude's status line, given at `since`: a dot beside the label says so.
    var live = false
    var since: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 0) {
                Text(label).font(.system(size: metrics(9), weight: .medium)).foregroundStyle(UsageMetrics.quiet).lineLimit(1)
                if live { UsageLiveMark(since: since, metrics: metrics, id: tipID) }
            }
            value.font(.system(size: metrics(15), weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            if let caption { Text(caption).font(.system(size: metrics(9.5))).foregroundStyle(captionTint).lineLimit(4).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .nookTip(tip, id: tipID)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken + (live ? ". En vivo" : ""))
    }
}

private struct UsageSessionSection: View {
    var session: ClaudeUsage.SessionStats
    var metrics: UsageMetrics
    /// What Claude's status line gave, with when: the dots beside what came from it (`session.liveFields`) and the context window, which only it knows.
    var live: ClaudeLiveUsage?

    private var cache: UsageFigures.Cache? { session.promptCache.map(UsageFigures.cache) }

    private var cells: [UsageStatCell] {
        var cells: [UsageStatCell] = []
        let plain = UsageMetrics.primary
        let dense = metrics.dense
        /// A caption in a roomy card; in a dense one the same words wait in the cell's tip.
        func cell(_ id: String, _ label: String, _ value: Text, caption: String?, captionTint: Color = UsageMetrics.secondary, spoken: String,
                  fromStatusLine: Bool = false, tip: NookTip? = nil) -> UsageStatCell {
            UsageStatCell(label: label, value: value, caption: dense ? nil : caption, captionTint: captionTint,
                          tip: tip ?? (dense ? caption.map { NookTip(label, detail: $0) } : nil), tipID: "usage-stat-" + id, spoken: spoken, metrics: metrics,
                          live: fromStatusLine, since: live?.sessionAt)
        }
        let fields = session.liveFields
        if let cost = session.cost {
            let note = session.costNote.map(UsageWords.costNote)
            cells.append(cell("cost", UsageWords.stat("Total cost"), Text(cost).foregroundStyle(plain), caption: note, captionTint: UsageMetrics.amber,
                              spoken: cost + (note.map { ". " + $0 } ?? ""), fromStatusLine: fields.contains(.cost)))
        }
        if let wall = session.wallDuration ?? session.apiDuration {
            let api = session.wallDuration != nil ? session.apiDuration : nil
            cells.append(cell("time", UsageWords.stat("Total duration (wall)"), Text(wall).foregroundStyle(plain), caption: api.map { "API \($0)" } ?? "tiempo en la API",
                              spoken: wall + (api.map { ". \(UsageWords.stat("Total duration (API)")) \($0)" } ?? ""),
                              fromStatusLine: fields.contains(.wallDuration) || fields.contains(.apiDuration)))
        }
        if let added = session.linesAdded, let removed = session.linesRemoved {
            let value = Text("+\(added)").foregroundStyle(added > 0 ? UsageMetrics.mint : UsageMetrics.secondary) + Text("  ")
                + Text("−\(removed)").foregroundStyle(removed > 0 ? UsageMetrics.coral : UsageMetrics.secondary)
            cells.append(cell("code", UsageWords.stat("Total code changes"), value, caption: dense ? UsageWords.lines(added: added, removed: removed) : "añadidas · quitadas",
                              spoken: UsageWords.lines(added: added, removed: removed), fromStatusLine: fields.contains(.lines)))
        }
        if let cache, let percent = cache.percent {
            let requests = cache.requests.map { $0 == 1 ? "1 solicitud" : "\($0) solicitudes" }
            cells.append(cell("cache", "Caché de prompts", Text("\(percent) %").foregroundStyle(plain),
                              caption: dense ? cacheWords(cache) : requests, spoken: "\(percent) % de la entrada desde la caché", fromStatusLine: fields.contains(.promptCache)))
        }
        // How full the context window is: the panel never says it, and the status line does. In a card with room (a short one has its figures to fit).
        if !dense, let context = live?.session?.context, let used = context.usedPercentage {
            let fraction = min(1, max(0, used / 100))
            let words = "\(Int(used.rounded())) %"
            cells.append(cell("context", "Contexto", Text(words).foregroundStyle(fraction >= 0.8 ? PanelBar.color(for: fraction) : plain),
                              caption: context.size.map { "de \(UsageLive.tokens($0)) tokens" }, spoken: words + " de la ventana de contexto", fromStatusLine: true,
                              tip: UsageLive.contextTip(live?.session)))
        }
        return cells
    }

    var body: some View {
        UsageSection(symbol: "clock", title: UsageWords.section(session.title), metrics: metrics, showsHeader: !metrics.dense, accessory: {
            // Where the width allows, how the prompt cache stands is said at the header's end; where it does not, in a line of its own under the figures.
            if let cache, !cache.isEmpty, !metrics.dense { cacheLine(cache) }
        }, content: {
            VStack(alignment: .leading, spacing: metrics(9)) {
                let items = cells
                if !items.isEmpty {
                    UsageTileGrid(minTile: metrics(96), gap: metrics(10), rowGap: metrics(9)) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, cell in cell }
                    }
                }
                if !metrics.dense {
                    ForEach(Array(session.other.enumerated()), id: \.offset) { _, stat in otherStat(stat) }
                }
            }
        })
    }

    private func otherStat(_ stat: ClaudeUsage.Stat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics(6)) {
            Text(UsageWords.stat(stat.label)).foregroundStyle(UsageMetrics.secondary)
            Spacer(minLength: 4)
            Text(stat.value).monospacedDigit().foregroundStyle(UsageMetrics.primary)
        }.font(.system(size: metrics(10)))
    }

    /// The prompt cache's state, in words: whether it is warm, what missed, and what else Claude said of it.
    private func cacheWords(_ cache: UsageFigures.Cache) -> String {
        var words: [String] = []
        switch cache.state {
        case .warm(let ttl, let idle)?: words.append("activa · TTL de \(ttl) · última actividad hace \(idle)")
        case .cold(let idle, let tokens)?: words.append("fría · inactiva \(idle) · el próximo turno vuelve a cachear \(tokens) tokens")
        case nil: break
        }
        if let requests = cache.requests { words.insert(requests == 1 ? "1 solicitud" : "\(requests) solicitudes", at: 0) }
        if let misses = cache.misses { words.append(misses) }
        return (words + cache.rest).joined(separator: " · ")
    }

    /// What is left of the prompt cache's line once its numbers have their cells: whether it is warm, and what missed. One line where the header has the room for it,
    /// with a dot that says it at a glance; where it has not, the words go on to a second line (and a third) at the header's end, never past the card's edge.
    private func cacheLine(_ cache: UsageFigures.Cache) -> some View {
        var words: [String] = []
        var warm: Bool?
        switch cache.state {
        case .warm(let ttl, let idle)?: words.append("activa · TTL de \(ttl) · última actividad hace \(idle)"); warm = true
        case .cold(let idle, let tokens)?: words.append("fría · inactiva \(idle) · el próximo turno vuelve a cachear \(tokens) tokens"); warm = false
        case nil: break
        }
        if let misses = cache.misses { words.append(misses) }
        words += cache.rest
        return HStack(alignment: .firstTextBaseline, spacing: metrics(6)) {
            if let warm { Circle().fill(warm ? UsageMetrics.mint : Color.nookInfo).frame(width: metrics(6), height: metrics(6)) }
            Text(UsageFigures.unbroken(words.joined(separator: " · "))).font(.system(size: metrics(9.5))).foregroundStyle(UsageMetrics.secondary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .trailing).accessibilityElement(children: .combine)
    }
}

// MARK: - Tokens per model

private struct UsageModelsSection: View {
    var models: [ClaudeUsage.ModelUsage]
    var metrics: UsageMetrics

    /// Each model's share of the money spent, when every cost can be read: the bars say which model the session's cost went to.
    private var shares: [Double?] {
        let costs = models.map { UsageFigures.dollars($0.cost) }
        let known = costs.compactMap { $0 }
        let total = known.reduce(0, +)
        guard models.count > 1, known.count == models.count, total > 0 else { return models.map { _ in nil } }
        return costs.map { $0.map { $0 / total } }
    }

    var body: some View {
        UsageSection(symbol: "cpu", title: UsageWords.section("Usage by model"), metrics: metrics, content: {
            VStack(alignment: .leading, spacing: metrics(11)) {
                let shares = self.shares
                ForEach(Array(models.enumerated()), id: \.offset) { index, model in UsageModelRow(model: model, share: shares[index], metrics: metrics) }
            }
        })
    }
}

private struct UsageModelRow: View {
    var model: ClaudeUsage.ModelUsage
    var share: Double?
    var metrics: UsageMetrics

    private var figures: [(value: String, label: String)] {
        var figures: [(String, String)] = []
        if let input = model.input { figures.append((input, "entrada")) }
        if let output = model.output { figures.append((output, "salida")) }
        if let read = model.cacheRead { figures.append((read, "lect. caché")) }
        if let write = model.cacheWrite { figures.append((write, "escr. caché")) }
        if let search = model.webSearch { figures.append((search, "búsq. web")) }
        return figures
    }

    var body: some View {
        let family = ClaudeModelFamily(model: model.name) ?? .other
        VStack(alignment: .leading, spacing: metrics(5)) {
            HStack(spacing: metrics(7)) {
                Image(systemName: family.symbol).font(.system(size: metrics(9), weight: .semibold)).foregroundStyle(UsageMetrics.primary)
                    .frame(width: metrics(18), height: metrics(18)).background(Color.nookWash(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(UsageFigures.modelName(model.name)).font(.system(size: metrics(11), weight: .semibold)).foregroundStyle(UsageMetrics.primary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: metrics(4))
                if let cost = model.cost { Text(cost).font(.system(size: metrics(11), weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(UsageMetrics.primary) }
            }
            if let share { UsageBar(fraction: share, color: claudeSpinner, height: metrics(3)) }
            HStack(alignment: .top, spacing: metrics(4)) {
                ForEach(Array(figures.enumerated()), id: \.offset) { _, figure in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(figure.value).font(.system(size: metrics(10.5), weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(UsageMetrics.primary).lineLimit(1)
                        Text(figure.label).font(.system(size: metrics(8.5))).foregroundStyle(UsageMetrics.quiet).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.extra.isEmpty {
                Text(model.extra.joined(separator: " · ")).font(.system(size: metrics(9))).foregroundStyle(UsageMetrics.quiet).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageFigures.modelName(model.name))
        .accessibilityValue((figures.map { "\($0.value) \($0.label)" } + [model.cost].compactMap { $0 }).joined(separator: ", "))
    }
}

// MARK: - The plugins

private struct UsageFootprintSection: View {
    var footprint: ClaudeUsage.Footprint
    var metrics: UsageMetrics

    var body: some View {
        let biggest = max(1, footprint.plugins.compactMap(\.tokens).max() ?? 1)
        UsageSection(symbol: "puzzlepiece.extension", title: UsageWords.section(footprint.title), metrics: metrics, accessory: {
            if let note = footprint.note, !footprint.plugins.isEmpty { UsageNote(title: UsageWords.section(footprint.title), text: UsageWords.insight(note), metrics: metrics) }
        }, content: {
            VStack(alignment: .leading, spacing: metrics(8)) {
                if footprint.plugins.isEmpty, let note = footprint.note {
                    // Claude's older panel says it in one line.
                    Text(UsageFigures.unbroken(UsageWords.insight(note))).font(.system(size: metrics(10))).foregroundStyle(UsageMetrics.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(footprint.plugins.enumerated()), id: \.offset) { _, plugin in row(plugin, biggest: biggest) }
                if let total = footprint.total { totalRow(total) }
                if let note = footprint.totalNote {
                    Text(UsageFigures.unbroken(UsageWords.insight(note))).font(.system(size: metrics(9))).foregroundStyle(UsageMetrics.quiet).fixedSize(horizontal: false, vertical: true)
                }
            }
        })
    }

    private func row(_ plugin: ClaudeUsage.Plugin, biggest: Int) -> some View {
        let detail = UsageWords.footprint(plugin.detail)
        let name = Text(plugin.name).font(.system(size: metrics(11), weight: .medium)).foregroundStyle(UsageMetrics.primary).lineLimit(1).truncationMode(.middle)
        let figures = Text(detail).font(.system(size: metrics(9.5), design: .monospaced)).foregroundStyle(UsageMetrics.secondary).lineLimit(1)
        return VStack(alignment: .leading, spacing: metrics(3)) {
            // Side by side where they fit; the figures under the name where they do not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: metrics(6)) { name; Spacer(minLength: metrics(4)); figures.fixedSize() }
                VStack(alignment: .leading, spacing: 1) { name; figures }
            }
            if let tokens = plugin.tokens { UsageBar(fraction: Double(tokens) / Double(biggest), color: UsageMetrics.secondary, height: metrics(3)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plugin.name).accessibilityValue(detail)
    }

    private func totalRow(_ total: String) -> some View {
        VStack(alignment: .leading, spacing: metrics(5)) {
            Rectangle().fill(Color.nookWash(0.08)).frame(height: 0.5)
            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(.system(size: metrics(10.5), weight: .semibold)).foregroundStyle(UsageMetrics.primary)
                Spacer(minLength: metrics(4))
                Text(UsageWords.footprint(total)).font(.system(size: metrics(11), weight: .semibold, design: .monospaced)).foregroundStyle(UsageMetrics.primary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - What spends the limits

private struct UsageInsightsSection: View {
    var insights: ClaudeUsage.Insights
    var metrics: UsageMetrics

    /// "Últimas 24 h" and what Claude says after it.
    private var window: (name: String, rest: String?)? {
        guard let text = insights.window.map(UsageWords.insight) else { return nil }
        let parts = text.components(separatedBy: " · ")
        return (parts[0], parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil)
    }

    var body: some View {
        UsageSection(symbol: "lightbulb", title: UsageFigures.heading(insights.title), metrics: metrics, accessory: {
            if let note { UsageNote(title: UsageFigures.heading(insights.title), text: note, metrics: metrics) }
        }, content: {
            VStack(alignment: .leading, spacing: metrics(10)) {
                if let window { windowBadge(window.name) }
                ForEach(Array(insights.items.enumerated()), id: \.offset) { index, item in UsageInsightRow(item: item, index: index, metrics: metrics) }
                ForEach(Array(insights.tables.enumerated()), id: \.offset) { _, table in UsageTableView(table: table, metrics: metrics) }
                ForEach(Array(insights.messages.enumerated()), id: \.offset) { _, message in
                    Text(UsageFigures.unbroken(UsageWords.insight(message))).font(.system(size: metrics(10))).foregroundStyle(UsageMetrics.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        })
    }

    /// What the ⓘ says: Claude's note under the title, and what it says of the period.
    private var note: String? {
        let parts = [insights.note.map(UsageWords.insight), window?.rest.map { $0.prefix(1).uppercased() + $0.dropFirst() }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The period the reading covers, as a badge.
    private func windowBadge(_ name: String) -> some View {
        Text(name).font(.system(size: metrics(9), weight: .medium)).foregroundStyle(UsageMetrics.secondary).lineLimit(1).fixedSize()
            .padding(.horizontal, metrics(6)).frame(height: metrics(16))
            .background(Color.nookWash(0.08), in: RoundedRectangle(cornerRadius: metrics(8), style: .circular))
    }
}

/// One thing Claude finds in the use: the share of it as a ring, what it says, and its advice: the whole of it where the card has room, and in a dense card two
/// lines of it, with the whole of it when the pointer rests on the row.
struct UsageInsightRow: View {
    var item: ClaudeUsage.Insight
    var index: Int
    var metrics: UsageMetrics

    var body: some View {
        let words = UsageWords.insight(item.headline)
        let advice = item.advice.map(UsageWords.insight)
        HStack(alignment: .top, spacing: metrics(9)) {
            if let share = item.share { ring(share) }
            VStack(alignment: .leading, spacing: metrics(2)) {
                Text(UsageFigures.unbroken(words)).font(.system(size: metrics(10.5), weight: .medium)).foregroundStyle(UsageMetrics.primary).fixedSize(horizontal: false, vertical: true)
                if let advice {
                    Text(UsageFigures.unbroken(advice)).font(.system(size: metrics(9.5))).foregroundStyle(UsageMetrics.secondary).lineLimit(metrics.dense ? 2 : nil).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contentShape(Rectangle())
        // Said in full already where it is not cut.
        .nookTip(metrics.dense ? advice.map { NookTip(words, detail: $0) } : nil, id: "usage-insight-\(index)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
        .accessibilityValue(advice ?? "")
    }

    /// A ring as full as the share is, in the amber the island uses for "look at this" once it is most of the use.
    private func ring(_ share: Double) -> some View {
        let tint = share >= 0.5 ? Color.nookAmberFill : UsageMetrics.secondary
        let side = metrics(26)
        return ZStack {
            Circle().stroke(UsageMetrics.track, lineWidth: metrics(3))
            Circle().trim(from: 0, to: CGFloat(min(1, max(0.015, share)))).stroke(tint, style: StrokeStyle(lineWidth: metrics(3), lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int((share * 100).rounded()))").font(.system(size: metrics(8.5), weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(UsageMetrics.primary)
        }
        .frame(width: side, height: side).padding(metrics(1.5))
        .accessibilityHidden(true)
    }
}

/// A table of who spends what (skills, subagents, plugins, MCP servers, loops): its title, and a row for each with its figures at the end and a thin bar when the
/// figure is a share.
private struct UsageTableView: View {
    var table: ClaudeUsage.Table
    var metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics(4)) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageWords.insight(table.title)).font(.system(size: metrics(9.5), weight: .semibold)).foregroundStyle(UsageMetrics.secondary)
                Spacer(minLength: metrics(4))
                Text(table.columns.map(UsageWords.insight).joined(separator: "  ")).font(.system(size: metrics(8.5))).foregroundStyle(UsageMetrics.quiet).lineLimit(1)
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: metrics(2)) {
                    HStack(alignment: .firstTextBaseline, spacing: metrics(6)) {
                        Text(row.name).font(.system(size: metrics(10), design: .monospaced)).foregroundStyle(UsageMetrics.primary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: metrics(4))
                        Text(row.values.joined(separator: "  ")).font(.system(size: metrics(10), weight: .medium, design: .monospaced)).foregroundStyle(UsageMetrics.primary).lineLimit(1)
                    }
                    if row.values.count == 1, let share = UsageFigures.share(row.values[0]) { UsageBar(fraction: share, color: UsageMetrics.secondary, height: metrics(2.5)) }
                }
                .accessibilityElement(children: .combine)
            }
            if let more = table.more { Text(UsageWords.insight(more)).font(.system(size: metrics(9))).foregroundStyle(UsageMetrics.quiet) }
        }
    }
}

// MARK: - What the card cannot place

/// The rows of the panel that no section took (what Claude added since, its loading and its error lines). They are never dropped: each is drawn in the card's own
/// type, in Spanish where `UsageWords` knows it and as Claude wrote it where it does not.
private struct UsageLeftoversSection: View {
    var rows: [ClaudePanel.Row]
    var metrics: UsageMetrics

    var body: some View {
        UsageSection(symbol: "ellipsis.circle", title: "Más de Claude", metrics: metrics, content: {
            VStack(alignment: .leading, spacing: metrics(5)) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in view(of: row) }
            }
        })
    }

    @ViewBuilder private func view(of row: ClaudePanel.Row) -> some View {
        switch row {
        case .heading(_, let text):
            Text(UsageWords.title(text)).font(.system(size: metrics(10.5), weight: .semibold)).foregroundStyle(UsageMetrics.primary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, metrics(3))
        case .text(_, let label, let body):
            if label.isEmpty {
                Text(UsageFigures.unbroken(UsageWords.insight(body))).font(.system(size: metrics(10))).foregroundStyle(UsageMetrics.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: metrics(6)) {
                    Text(UsageWords.stat(label)).foregroundStyle(UsageMetrics.secondary)
                    Spacer(minLength: metrics(4))
                    Text(UsageFigures.unbroken(UsageWords.insight(body))).monospacedDigit().foregroundStyle(UsageMetrics.primary)
                }.font(.system(size: metrics(10)))
            }
        case .caption(_, let text), .hint(let text), .cursor(_, let text):
            Text(UsageFigures.unbroken(UsageWords.insight(text))).font(.system(size: metrics(9.5))).foregroundStyle(UsageMetrics.quiet).fixedSize(horizontal: false, vertical: true)
        case .bar(_, let lead, let fraction, let trailing):
            VStack(alignment: .leading, spacing: metrics(3)) {
                HStack {
                    if !lead.isEmpty { Text(UsageWords.title(lead)).foregroundStyle(UsageMetrics.secondary) }
                    Spacer(minLength: metrics(4))
                    Text(trailing).monospacedDigit().foregroundStyle(UsageMetrics.primary)
                }.font(.system(size: metrics(10)))
                UsageBar(fraction: fraction, color: PanelBar.color(for: fraction), height: metrics(5))
            }
        case .rule:
            Rectangle().fill(Color.nookWash(0.08)).frame(height: 0.5).padding(.vertical, metrics(2))
        case .blank, .tabs:
            Color.clear.frame(height: metrics(2))
        }
    }
}

// MARK: - The dashboard

/// The panel's content when it is the usage panel: every part of it at once.
struct UsageContent: View {
    let usage: ClaudeUsage
    let panel: ClaudePanel
    /// The user's chat text size: the card's sizes follow it a little.
    let chatSize: Double
    /// The card has little height to show in: what matters most is made to fit one screen (`UsageMetrics.dense`).
    var dense = false
    /// Nook is still scrolling Claude's panel to read the rest of it.
    var reading = false
    /// Claude's own "↓" (or "↑"): its panel goes on beyond what Nook holds.
    let onMore: (_ down: Bool) -> Void
    let enabled: Bool

    private var metrics: UsageMetrics { UsageMetrics(chatSize: chatSize, dense: dense) }

    /// Where Claude's own «más» is offered: only while Nook holds part of the panel (a Terminal tab shows what its screen shows), which is when moving what Claude
    /// shows brings more of it. With the whole panel in hand it is never offered, whatever marks Claude's last screen left.
    static func offersMore(usage: ClaudeUsage, panel: ClaudePanel) -> (above: Bool, below: Bool) {
        usage.complete ? (false, false) : (panel.moreAbove, panel.moreBelow)
    }

    private var partial: Bool { !usage.complete }

    var body: some View {
        let more = Self.offersMore(usage: usage, panel: panel)
        VStack(alignment: .leading, spacing: metrics(8)) {
            if more.above { self.more(down: false) }
            // The two summaries stand across the card, one under the other: the limits, which is what anyone opens the panel for, and what this session has cost.
            if !usage.meters.isEmpty { UsageLimitsSection(meters: usage.meters, metrics: metrics, live: usage.live) }
            if let session = usage.session { UsageSessionSection(session: session, metrics: metrics, live: usage.live) }
            UsageMasonry(gap: metrics(8), minColumn: metrics(205)) {
                if let session = usage.session, !session.models.isEmpty { UsageModelsSection(models: session.models, metrics: metrics) }
                if let footprint = usage.footprint { UsageFootprintSection(footprint: footprint, metrics: metrics) }
                if let insights = usage.insights { UsageInsightsSection(insights: insights, metrics: metrics) }
                if !usage.leftovers.isEmpty { UsageLeftoversSection(rows: usage.leftovers, metrics: metrics) }
            }
            if reading, partial { readingNote }
            if more.below { self.more(down: true) }
        }
    }

    private var readingNote: some View {
        HStack(spacing: metrics(6)) {
            ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: metrics(12), height: metrics(12))
            Text("Leyendo el resto del panel…").font(.system(size: metrics(9.5))).foregroundStyle(UsageMetrics.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, metrics(4))
            .accessibilityElement(children: .combine)
    }

    private func more(down: Bool) -> some View { UsageMoreButton(down: down, enabled: enabled, onMore: onMore) }
}

/// Claude's own «más»: the panel goes on beyond what Nook holds, and a press moves it (about a screen). At the end of the card's content, under the sections.
struct UsageMoreButton: View {
    let down: Bool
    let enabled: Bool
    let onMore: (_ down: Bool) -> Void

    var body: some View {
        Button { onMore(down) } label: {
            HStack(spacing: 3) {
                Image(systemName: down ? "arrow.down" : "arrow.up").font(.system(size: 8.5, weight: .bold)).nookIconMotion(down ? .nudgeDown : .nudgeUp, strength: 0.6)
                Text("más").font(.system(size: 10, weight: .medium))
            }.foregroundStyle(Color.primary.opacity(0.85)).padding(.horizontal, 8).frame(height: 20).contentShape(Capsule())
        }.buttonStyle(PanelButtonStyle(rest: 0.1, radius: 10)).disabled(!enabled)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .nookTip(NookTip(down ? "Hay más debajo" : "Hay más arriba", detail: down ? "Claude tiene más del panel debajo · ↓ lo baja" : "Claude tiene más del panel arriba · ↑ lo sube"), id: down ? "usage-more-down" : "usage-more-up")
            .accessibilityLabel(down ? "Más contenido debajo" : "Más contenido arriba")
    }
}
