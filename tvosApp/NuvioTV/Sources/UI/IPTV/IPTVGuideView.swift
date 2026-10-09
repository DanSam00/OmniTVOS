import SwiftUI

/// The Live TV tab: a programme guide for the IPTV sources in Settings ▸
/// Integrations. Channels run down the side, a time window runs across, and
/// each programme sits where it airs, with a line at the current time.
/// Choosing a programme opens its channel's page, which lists the sources to
/// play and what is on now and next.
///
/// The window is paged rather than scrolled sideways (Earlier / Later, or
/// running off either end of a row), so every row stays aligned to the same
/// clock and the ruler above can be one plain view.
struct IPTVGuideView: View {
    let isActive: Bool
    let onOpenChannel: (String, String) -> Void

    @State private var groups: [IPTVChannelGroup] = []
    /// "VIP" of "VIP | UFC PPV"; nil shows every section.
    @State private var section: String?
    /// "UFC PPV" of "VIP | UFC PPV"; nil shows the whole section.
    @State private var subsection: String?
    @State private var windowStart = IPTVGuideView.slot(containing: Date())
    @State private var programmes: [String: [IPTVProgramme]] = [:]
    @State private var isLoading = true
    @State private var now = Date()
    #if os(macOS)
    @State private var caretRow = 0
    @State private var caretCell = 0
    /// Which header row the keyboard is in (0 Earlier/Now/Later, 1 sections,
    /// 2 subsections); nil while it is in the guide itself.
    @State private var headerRow: Int?
    @State private var headerIndex = 0
    @State private var macKeyToken: UUID?
    @State private var scrollProxy: ScrollViewProxy?
    private let keyRouter = MacKeyRouter.shared
    #endif

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private static let channelColumnWidth: CGFloat = {
        #if os(iOS)
        return 120
        #else
        return 300
        #endif
    }()
    private static let rowHeight: CGFloat = {
        #if os(iOS)
        return 64
        #else
        return 96
        #endif
    }()

    /// Hours shown at once: three on a TV or Mac, ninety minutes on a phone.
    private func windowMinutes(for width: CGFloat) -> Double {
        width < 700 ? 90 : 180
    }

    static func slot(containing date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 1800).rounded(.down) * 1800)
    }

    /// A provider group splits into a section and a subsection at its
    /// first bar: "VIP | UFC PPV" → ("VIP", "UFC PPV").
    static func split(_ category: String) -> (section: String, subsection: String?) {
        let parts = category.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return (category.trimmingCharacters(in: .whitespaces), nil) }
        let head = parts[0].trimmingCharacters(in: .whitespaces)
        let tail = parts[1].trimmingCharacters(in: .whitespaces)
        return (head.isEmpty ? category : head, tail.isEmpty ? nil : tail)
    }

    private var sections: [String] {
        var seen = Set<String>()
        return groups.map { Self.split($0.category).section }.filter { seen.insert($0).inserted }
    }

    private var subsections: [String] {
        guard let section else { return [] }
        var seen = Set<String>()
        return groups.compactMap { group -> String? in
            let parts = Self.split(group.category)
            return parts.section == section ? parts.subsection : nil
        }
        .filter { seen.insert($0).inserted }
    }

    private var shownGroups: [IPTVChannelGroup] {
        groups.filter { group in
            let parts = Self.split(group.category)
            if let section, parts.section != section { return false }
            if let subsection, parts.subsection != subsection { return false }
            return true
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let timelineWidth = max(proxy.size.width - Self.channelColumnWidth - horizontalPadding * 2, 200)
            let minutes = windowMinutes(for: timelineWidth)
            let perMinute = timelineWidth / minutes
            VStack(alignment: .leading, spacing: 18) {
                header
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if groups.isEmpty {
                    emptyState
                } else {
                    ruler(width: timelineWidth, perMinute: perMinute, minutes: minutes)
                    rows(timelineWidth: timelineWidth, perMinute: perMinute, minutes: minutes)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: IPTVSourceStore.changedNotification)) { _ in
            Task { await load() }
        }
        .onReceive(clock) { now = $0 }
        #if os(macOS)
        .onAppear { claimKeysIfActive() }
        .onChange(of: isActive) { _, _ in claimKeysIfActive() }
        .onDisappear { keyRouter.release(macKeyToken); macKeyToken = nil }
        .onReceive(keyRouter.presses.map(Optional.some)) { press in
            guard let press, keyRouter.isFront(macKeyToken) else { return }
            handleMacKey(press.key)
        }
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 48
        #endif
    }

    private var topPadding: CGFloat {
        #if os(macOS)
        return MacMenuMetrics.headerTopInset
        #elseif os(tvOS)
        return 40
        #else
        return 8
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text(L10n.string("nav_live_tv", fallback: "Live TV"))
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                ForEach(Array(timeButtons.enumerated()), id: \.offset) { index, item in
                    guideButton(item.title, symbol: item.symbol, highlighted: isHeaderCaret(0, index), action: item.action)
                }
            }
            if sections.count > 1 {
                chipRow(row: 1, titles: [allTitle] + sections, selected: section.map { (sections.firstIndex(of: $0) ?? -1) + 1 } ?? 0) {
                    selectSection($0 == 0 ? nil : sections[$0 - 1])
                }
            }
            if subsections.count > 1 {
                chipRow(row: 2, titles: [allTitle] + subsections, selected: subsection.map { (subsections.firstIndex(of: $0) ?? -1) + 1 } ?? 0) {
                    selectSubsection($0 == 0 ? nil : subsections[$0 - 1])
                }
            }
        }
    }

    private var allTitle: String { L10n.string("library_type_all", fallback: "All") }

    private var timeButtons: [(title: String, symbol: String, action: () -> Void)] {
        [
            (L10n.string("guide_earlier", fallback: "Earlier"), "chevron.left", { shift(by: -1) }),
            (L10n.string("guide_now", fallback: "Now"), "clock", { windowStart = Self.slot(containing: Date()) }),
            (L10n.string("guide_later", fallback: "Later"), "chevron.right", { shift(by: 1) }),
        ]
    }

    private func chipRow(row: Int, titles: [String], selected: Int, onSelect: @escaping (Int) -> Void) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                        chip(title, selected: index == selected, highlighted: isHeaderCaret(row, index)) { onSelect(index) }
                            .id("chip.\(row).\(index)")
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            // A sideways scroll view takes any height offered; without this
            // the chips claimed half the screen above the guide.
            .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            .onChange(of: headerIndex) { _, index in
                guard headerRow == row else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chip.\(row).\(index)", anchor: .center) }
            }
            #endif
        }
    }

    private var titleSize: CGFloat {
        #if os(iOS)
        return 28
        #else
        return 40
        #endif
    }

    private func guideButton(_ title: String, symbol: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: chipFontSize, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().stroke(Color.white, lineWidth: highlighted ? 3 : 0))
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        #if os(tvOS)
        .focusable()
        #endif
    }

    private func chip(_ title: String, selected: Bool, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: chipFontSize, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.1)))
                .overlay(Capsule().stroke(selected ? Color.black.opacity(0.6) : Color.white, lineWidth: highlighted ? 3 : 0))
                .foregroundColor(selected ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private var chipFontSize: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 20
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.system(size: 54))
                .foregroundColor(.white.opacity(0.5))
            Text(L10n.string("guide_empty_title", fallback: "No live channels yet"))
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
            Text(L10n.string(
                "guide_empty_subtitle",
                fallback: "Add an M3U playlist or Xtream login in Settings ▸ Integrations ▸ IPTV, and its channels in your languages appear here with what's on."
            ))
            .font(.system(size: 18))
            .foregroundColor(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Ruler and rows

    private func ruler(width: CGFloat, perMinute: CGFloat, minutes: Double) -> some View {
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        let marks = Int(minutes / 30)
        return HStack(spacing: 0) {
            Color.clear.frame(width: Self.channelColumnWidth, height: 24)
            ZStack(alignment: .topLeading) {
                ForEach(0..<marks, id: \.self) { index in
                    Text(time.string(from: windowStart.addingTimeInterval(Double(index) * 1800)))
                        .font(.system(size: chipFontSize - 2, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .offset(x: CGFloat(index) * 30 * perMinute)
                }
                nowLine(perMinute: perMinute, minutes: minutes, height: 24)
            }
            .frame(width: width, height: 24, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func nowLine(perMinute: CGFloat, minutes: Double, height: CGFloat) -> some View {
        let offset = now.timeIntervalSince(windowStart) / 60
        if offset >= 0, offset <= minutes {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: height)
                .offset(x: CGFloat(offset) * perMinute)
        }
    }

    private func rows(timelineWidth: CGFloat, perMinute: CGFloat, minutes: Double) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(shownGroups.enumerated()), id: \.element.id) { index, group in
                        row(group, index: index, width: timelineWidth, perMinute: perMinute, minutes: minutes)
                            .id(group.id)
                            .task(id: group.id) { await loadProgrammes(for: group) }
                    }
                }
                .padding(.bottom, 60)
            }
            #if os(macOS)
            .onAppear { scrollProxy = proxy }
            #endif
        }
    }

    private func row(
        _ group: IPTVChannelGroup,
        index: Int,
        width: CGFloat,
        perMinute: CGFloat,
        minutes: Double
    ) -> some View {
        let cells = visibleProgrammes(for: group, minutes: minutes)
        return HStack(spacing: 0) {
            channelCell(group)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
                if cells.isEmpty {
                    programmeButton(
                        group: group,
                        // Event and pay-per-view channels rarely carry a guide:
                        // the channel itself, live, reads better than an error.
                        title: programmes[group.id] == nil
                            ? L10n.string("guide_loading", fallback: "Loading…")
                            : group.name,
                        subtitle: programmes[group.id] == nil
                            ? nil
                            : L10n.string("guide_live_no_info", fallback: "Live · no guide listing"),
                        isNow: true,
                        isCaret: isCaret(row: index, cell: 0)
                    )
                    .frame(width: width, height: Self.rowHeight)
                } else {
                    ForEach(Array(cells.enumerated()), id: \.offset) { cellIndex, programme in
                        let start = max(programme.start, windowStart)
                        let end = min(programme.end, windowStart.addingTimeInterval(minutes * 60))
                        let x = CGFloat(start.timeIntervalSince(windowStart) / 60) * perMinute
                        let w = max(CGFloat(end.timeIntervalSince(start) / 60) * perMinute - 4, 24)
                        programmeButton(
                            group: group,
                            title: programme.title,
                            subtitle: timeRange(programme),
                            isNow: programme.start <= now && programme.end > now,
                            isCaret: isCaret(row: index, cell: cellIndex)
                        )
                        .frame(width: w, height: Self.rowHeight)
                        .offset(x: x)
                    }
                }
                nowLine(perMinute: perMinute, minutes: minutes, height: Self.rowHeight)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: Self.rowHeight, alignment: .topLeading)
            .clipped()
        }
    }

    private func channelCell(_ group: IPTVChannelGroup) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: group.logo.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "tv").foregroundColor(.white.opacity(0.4))
            }
            .frame(width: logoSize, height: logoSize)
            #if !os(iOS)
            Text(group.name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            #endif
        }
        .padding(.horizontal, 8)
        .frame(width: Self.channelColumnWidth, height: Self.rowHeight, alignment: .leading)
    }

    private var logoSize: CGFloat {
        #if os(iOS)
        return 56
        #else
        return 72
        #endif
    }

    private func programmeButton(
        group: IPTVChannelGroup,
        title: String,
        subtitle: String?,
        isNow: Bool,
        isCaret: Bool
    ) -> some View {
        Button {
            onOpenChannel(group.id, "tv")
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: programmeFontSize, weight: .semibold))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: programmeFontSize - 3))
                        .opacity(0.65)
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isNow ? Color.white.opacity(0.16) : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white, lineWidth: isCaret ? 3 : 0)
            )
        }
        .buttonStyle(.plain)
    }

    private var programmeFontSize: CGFloat {
        #if os(iOS)
        return 13
        #else
        return 18
        #endif
    }

    private func timeRange(_ programme: IPTVProgramme) -> String {
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        return "\(time.string(from: programme.start)) – \(time.string(from: programme.end))"
    }

    /// Programmes overlapping the window, in order.
    private func visibleProgrammes(for group: IPTVChannelGroup, minutes: Double) -> [IPTVProgramme] {
        let end = windowStart.addingTimeInterval(minutes * 60)
        return (programmes[group.id] ?? []).filter { $0.end > windowStart && $0.start < end }
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        _ = await IPTVLibrary.shared.allChannels()
        groups = IPTVLibrary.shared.visibleGroups()
        if let section, !sections.contains(section) { self.section = nil; subsection = nil }
        if let subsection, !subsections.contains(subsection) { self.subsection = nil }
        isLoading = false
    }

    private func loadProgrammes(for group: IPTVChannelGroup) async {
        guard programmes[group.id] == nil else { return }
        programmes[group.id] = await IPTVGuide.shared.programmes(for: group)
    }

    private func shift(by hours: Int) {
        let earliest = Self.slot(containing: Date()).addingTimeInterval(-3600)
        windowStart = max(windowStart.addingTimeInterval(Double(hours) * 3600), earliest)
    }

    private func selectSection(_ name: String?) {
        section = name
        subsection = nil
        resetGridCaret()
    }

    private func selectSubsection(_ name: String?) {
        subsection = name
        resetGridCaret()
    }

    private func resetGridCaret() {
        #if os(macOS)
        caretRow = 0
        caretCell = 0
        #endif
    }

    private func isCaret(row: Int, cell: Int) -> Bool {
        #if os(macOS)
        return isActive && headerRow == nil && caretRow == row && caretCell == cell
        #else
        return false
        #endif
    }

    private func isHeaderCaret(_ row: Int, _ index: Int) -> Bool {
        #if os(macOS)
        return isActive && headerRow == row && headerIndex == index
        #else
        return false
        #endif
    }

    // MARK: Mac keyboard

    #if os(macOS)
    private func claimKeysIfActive() {
        keyRouter.release(macKeyToken)
        macKeyToken = isActive ? keyRouter.claim() : nil
    }

    /// The keyboard's highlight, as Home's: Left/Right walk a row's
    /// programmes and page the window at its ends, Up/Down change channel,
    /// Return opens the channel. Left at the start of the day opens the menu.
    private func handleMacKey(_ key: MacKey) {
        guard isActive else { return }
        let menu = MacMenuState.shared
        if key == .activate {
            if menu.handleReturn() { return }
        } else if let move = direction(for: key), menu.handleMove(move) {
            return
        }
        if headerRow != nil {
            handleHeaderKey(key)
            return
        }
        let shown = shownGroups
        guard !shown.isEmpty else {
            if key == .up { enterHeader(at: lastHeaderRow) }
            return
        }
        caretRow = min(caretRow, shown.count - 1)
        let cells = visibleProgrammes(for: shown[caretRow], minutes: 180)
        switch key {
        case .up, .down:
            let next = key == .up ? caretRow - 1 : caretRow + 1
            // Up from the first channel reaches the filters and time buttons.
            if key == .up, next < 0 { enterHeader(at: lastHeaderRow); return }
            guard shown.indices.contains(next) else { return }
            // Keep to the same time: the programme airing where the caret was.
            let anchor = cells.indices.contains(caretCell) ? max(cells[caretCell].start, windowStart) : windowStart
            caretRow = next
            let nextCells = visibleProgrammes(for: shown[next], minutes: 180)
            caretCell = nextCells.firstIndex { $0.end > anchor } ?? 0
            withAnimation(.easeOut(duration: 0.2)) { scrollProxy?.scrollTo(shown[next].id, anchor: .center) }
        case .right:
            if caretCell + 1 < cells.count {
                caretCell += 1
            } else {
                shift(by: 1)
                caretCell = 0
            }
        case .left:
            if caretCell > 0 {
                caretCell -= 1
            } else if windowStart > Self.slot(containing: Date()).addingTimeInterval(-3600) {
                shift(by: -1)
                caretCell = max(visibleProgrammes(for: shown[caretRow], minutes: 180).count - 1, 0)
            } else {
                MacMenuState.shared.open()
            }
        case .activate:
            onOpenChannel(shown[caretRow].id, "tv")
        default:
            break
        }
    }

    /// Header rows on screen, top to bottom, by their fixed numbers.
    private var headerRows: [Int] {
        [0] + (sections.count > 1 ? [1] : []) + (subsections.count > 1 ? [2] : [])
    }

    private var lastHeaderRow: Int { headerRows.last ?? 0 }

    private func headerCount(_ row: Int) -> Int {
        switch row {
        case 0: return timeButtons.count
        case 1: return sections.count + 1
        default: return subsections.count + 1
        }
    }

    /// Lands on the row's current choice, so Up from the guide shows where
    /// the filter stands.
    private func enterHeader(at row: Int) {
        headerRow = row
        switch row {
        case 1: headerIndex = section.flatMap { sections.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        case 2: headerIndex = subsection.flatMap { subsections.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        default: headerIndex = 1
        }
    }

    private func handleHeaderKey(_ key: MacKey) {
        guard let row = headerRow, let position = headerRows.firstIndex(of: row) else {
            headerRow = nil
            return
        }
        switch key {
        case .left:
            if headerIndex > 0 { headerIndex -= 1 } else { MacMenuState.shared.open() }
        case .right:
            headerIndex = min(headerIndex + 1, headerCount(row) - 1)
        case .up:
            if position > 0 { enterHeader(at: headerRows[position - 1]) }
        case .down:
            if position + 1 < headerRows.count {
                enterHeader(at: headerRows[position + 1])
            } else {
                headerRow = nil
                withAnimation(.easeOut(duration: 0.2)) {
                    if let first = shownGroups.first { scrollProxy?.scrollTo(first.id, anchor: .top) }
                }
            }
        case .activate:
            switch row {
            case 0:
                if timeButtons.indices.contains(headerIndex) { timeButtons[headerIndex].action() }
            case 1:
                selectSection(headerIndex == 0 ? nil : sections[headerIndex - 1])
            default:
                selectSubsection(headerIndex == 0 ? nil : subsections[headerIndex - 1])
            }
            // A chosen section may add or remove the subsection row below.
            if !headerRows.contains(row) { headerRow = lastHeaderRow }
        default:
            break
        }
    }

    private func direction(for key: MacKey) -> MoveCommandDirection? {
        switch key {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        default: return nil
        }
    }
    #endif
}
