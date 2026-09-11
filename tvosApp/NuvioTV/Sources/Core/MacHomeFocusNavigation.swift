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
    /// Card keys for one row, in display order. Collection rows show folders
    /// where ordinary rows show titles.
    static func cardKeys(for section: TVHomeSection) -> [String] {
        if !section.collectionFolders.isEmpty {
            return section.collectionFolders.map { "\(section.id)\u{1}\($0.id)" }
        }
        return section.items.map { "\(section.id)\u{1}\($0.id)" }
    }

    /// The card an arrow press should land on, or nil to leave focus alone.
    ///
    /// `sections` must already be in display order — the caller passes the same
    /// ordering Home renders.
    static func nextCardKey(
        from current: String?,
        direction: MoveCommandDirection,
        sections: [TVHomeSection]
    ) -> String? {
        let rows = sections.map { cardKeys(for: $0) }.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }

        guard let current,
              let rowIndex = rows.firstIndex(where: { $0.contains(current) }),
              let columnIndex = rows[rowIndex].firstIndex(of: current) else {
            // Nothing focused yet: start at the first card.
            return rows.first?.first
        }

        switch direction {
        case .left:
            return columnIndex > 0 ? rows[rowIndex][columnIndex - 1] : nil
        case .right:
            let next = columnIndex + 1
            return next < rows[rowIndex].count ? rows[rowIndex][next] : nil
        case .up:
            guard rowIndex > 0 else { return nil }
            return neighbour(in: rows[rowIndex - 1], preferredColumn: columnIndex)
        case .down:
            let next = rowIndex + 1
            guard next < rows.count else { return nil }
            return neighbour(in: rows[next], preferredColumn: columnIndex)
        @unknown default:
            return nil
        }
    }

    /// Keeps the horizontal position when changing rows, as a TV remote does,
    /// clamping to the end of a shorter row.
    private static func neighbour(in row: [String], preferredColumn: Int) -> String? {
        guard !row.isEmpty else { return nil }
        return row[min(preferredColumn, row.count - 1)]
    }
}
#endif
