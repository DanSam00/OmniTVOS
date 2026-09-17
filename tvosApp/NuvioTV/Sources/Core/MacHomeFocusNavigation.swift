#if os(macOS)
import SwiftUI

/// Arrow-key movement across Home's rows.
///
/// macOS has no focus engine, and — unlike tvOS — SwiftUI does not back each
/// focusable view with an `NSView`, so focus cannot be moved from AppKit at all
/// (a survey of a live window found three hidden proxy views for the whole UI).
/// The only thing that can move SwiftUI focus is SwiftUI, by writing to the same
/// `@FocusState` the cards are bound to.
///
/// Home already keys every card as `"<sectionId>\u{1}<itemId>"` in a single
/// `focusedCardID`, so movement is index arithmetic over the ordered sections
/// rather than anything geometric.
enum MacHomeFocus {
    /// Section id of the stand-in row for the featured carousel, which Home
    /// prepends to the navigable rows while the carousel is on.
    static let featureSectionId = "mac.feature"
    /// The carousel's single card key.
    static let featureCardKey = "mac.feature\u{1}slide"

    /// Card keys for one row, in display order. Collection rows show folders
    /// where ordinary rows show titles.
    static func cardKeys(for section: TVHomeSection) -> [String] {
        // However many slides it holds, the carousel is one focus target — the
        // same as on tvOS, where Left/Right page it rather than moving focus.
        // A key per slide would also change under the auto-advance timer and
        // strand the highlight.
        if section.id == featureSectionId { return [featureCardKey] }
        if !section.collectionFolders.isEmpty {
            return section.collectionFolders.map { "\(section.id)\u{1}\($0.id)" }
        }
        return section.items.map { "\(section.id)\u{1}\($0.id)" }
    }

    /// Whether a row has anything to focus, without building its card keys.
    ///
    /// `cardKeys(for:)` interpolates a string per item, so asking it merely
    /// whether a row is empty costs the whole row.
    static func isNavigable(_ section: TVHomeSection) -> Bool {
        if section.id == featureSectionId { return true }
        if !section.collectionFolders.isEmpty { return true }
        return !section.items.isEmpty
    }

    /// The first card on Home, used to give focus somewhere to start from.
    static func firstCardKey(sections: [TVHomeSection]) -> String? {
        for section in sections {
            if let first = cardKeys(for: section).first { return first }
        }
        return nil
    }

    /// The row a card key belongs to. Keys are "<sectionId>\u{1}<itemId>".
    static func sectionId(of cardKey: String?) -> String? {
        guard let cardKey, let separator = cardKey.firstIndex(of: "\u{1}") else { return nil }
        return String(cardKey[cardKey.startIndex..<separator])
    }

    /// The card an arrow press should land on, or nil to leave focus alone.
    ///
    /// `sections` must already be in display order — the caller passes the same
    /// ordering Home renders.
    /// - Parameter lastCardBySection: where each row was last left, so
    ///   changing rows resumes that row rather than restarting it.
    static func nextCardKey(
        from current: String?,
        direction: MoveCommandDirection,
        sections: [TVHomeSection],
        lastCardBySection: [String: String] = [:]
    ) -> String? {
        // Only the rows this press actually touches are expanded. Building
        // every row's keys up front meant a string interpolation per item on
        // Home — tens of thousands of them on a long catalog list, on every
        // single arrow press, before any work towards the answer began.
        let rows = sections.filter(isNavigable)
        guard !rows.isEmpty else { return nil }

        guard let current,
              let sectionID = sectionId(of: current),
              let rowIndex = rows.firstIndex(where: { $0.id == sectionID }) else {
            // Nothing focused yet: start at the first card.
            return rows.first.flatMap { cardKeys(for: $0).first }
        }

        switch direction {
        case .left, .right:
            let keys = cardKeys(for: rows[rowIndex])
            guard let columnIndex = keys.firstIndex(of: current) else { return nil }
            let next = direction == .left ? columnIndex - 1 : columnIndex + 1
            return keys.indices.contains(next) ? keys[next] : nil
        case .up:
            guard rowIndex > 0 else { return nil }
            return entry(into: rows[rowIndex - 1], remembering: lastCardBySection)
        case .down:
            let next = rowIndex + 1
            guard next < rows.count else { return nil }
            return entry(into: rows[next], remembering: lastCardBySection)
        @unknown default:
            return nil
        }
    }

    /// Where the caret lands when it enters a row: back where that row was
    /// left, or its first card if it has not been visited.
    ///
    /// Carrying the column across instead meant stepping down from the twelfth
    /// card of one row landed on the twelfth card of the next, with the first
    /// eleven behind the caret and the row already scrolled along. Rows are
    /// independent lists rather than columns of a table, so a shared column
    /// index carries no meaning between them.
    private static func entry(
        into section: TVHomeSection,
        remembering lastCardBySection: [String: String]
    ) -> String? {
        // The remembered key is checked against the section id before the row
        // is expanded, so the common case costs nothing.
        if let remembered = lastCardBySection[section.id] {
            let keys = cardKeys(for: section)
            if keys.contains(remembered) { return remembered }
            return keys.first
        }
        return cardKeys(for: section).first
    }
}
#endif
