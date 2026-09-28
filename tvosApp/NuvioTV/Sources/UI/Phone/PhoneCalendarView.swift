#if os(iOS)
import SwiftUI

/// The Calendar tab on the phone: the same `CalendarViewModel` as tvOS (Library
/// and Continue Watching episodes, upcoming movies, sports fixtures), the same
/// filters, and the same List / Month choice from Settings → Layout.
struct PhoneCalendarView: View {
    let onOpenDetails: (String, String) -> Void

    @StateObject private var viewModel = CalendarViewModel()
    @AppStorage(SettingsKey.calendarViewMode) private var viewModeRaw = CalendarViewMode.list.rawValue
    @State private var monthAnchor = Date()
    @State private var selectedDayKey = CalendarDayKey.dayKey(from: Date())
    /// Landscape month view: the tapped day's entries beside the grid.
    @State private var isDayPanelOpen = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isLandscape: Bool { verticalSizeClass == .compact }

    private var viewMode: CalendarViewMode { CalendarViewMode.from(viewModeRaw) }
    private var todayKey: String { CalendarDayKey.dayKey(from: Date()) }

    var body: some View {
        Group {
            if viewMode == .month && isLandscape {
                landscapeMonth
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        controls
                        if viewMode == .month {
                            monthGrid
                            dayEntries(selectedDayKey)
                        } else {
                            list
                        }
                    }
                    .padding(.vertical, 12)
                }
                .refreshable { await viewModel.load() }
            }
        }
        .background(Color.black.ignoresSafeArea())
        // No title: the tab bar already says where you are, and the space
        // goes to the calendar.
        .toolbar(.hidden, for: .navigationBar)
        .task { await viewModel.load() }
        .onChange(of: isLandscape) { _, _ in isDayPanelOpen = false }
    }

    /// Landscape month: the grid alone, full width, until a day is tapped;
    /// then that day's entries slide in on the right and the grid narrows.
    private var landscapeMonth: some View {
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        controls
                        monthGrid
                    }
                    .padding(.vertical, 12)
                }
                .refreshable { await viewModel.load() }
                .frame(maxWidth: .infinity)

                if isDayPanelOpen {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Spacer()
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) { isDayPanelOpen = false }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 32, height: 32)
                                        .background(Color.white.opacity(0.12), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close day")
                            }
                            .padding(.horizontal, PhoneLayout.gutter)
                            dayEntries(selectedDayKey)
                        }
                        .padding(.vertical, 12)
                    }
                    .frame(width: proxy.size.width * 0.44)
                    // Black at the calendar's edge, lifting to grey on the right.
                    .background(
                        LinearGradient(
                            colors: [.black, Color(white: 0.1)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .ignoresSafeArea()
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("View", selection: $viewModeRaw) {
                ForEach(CalendarViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CalendarFilter.allCases) { filter in
                        chip(filter.title, isOn: viewModel.filters.contains(filter)) {
                            viewModel.toggle(filter)
                        }
                    }
                    if viewModel.filters.contains(.sports), !viewModel.availableSportGenres.isEmpty {
                        Menu {
                            Button("All Sports") { viewModel.selectedSportGenre = nil }
                            ForEach(viewModel.availableSportGenres, id: \.self) { genre in
                                Button(genre) { viewModel.selectedSportGenre = genre }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(viewModel.selectedSportGenre ?? "All Sports")
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.12), in: Capsule())
                        }
                    }
                    if viewModel.isLoading || viewModel.isLoadingSports || viewModel.isLoadingMovies {
                        ProgressView().padding(.leading, 4)
                    }
                }
            }
        }
        .padding(.horizontal, PhoneLayout.gutter)
        .padding(.top, 4)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isOn ? Color.white : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(isOn ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let days = viewModel.days
        if days.isEmpty {
            emptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Self.dayTitle(day.id, todayKey: todayKey))
                            .font(.headline)
                            .foregroundStyle(day.id == todayKey ? Color.white : Color.white.opacity(0.85))
                        ForEach(day.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            .padding(.horizontal, PhoneLayout.gutter)
        }
    }

    private func entryRow(_ entry: CalendarEntry) -> some View {
        Button { onOpenDetails(entry.metaId, entry.type) } label: {
            HStack(alignment: .top, spacing: 12) {
                Color.clear
                    .frame(width: 124, height: 70)
                    .overlay { PhoneArtwork(url: entry.imageUrl ?? entry.backdropUrl ?? entry.posterUrl) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if entry.isLiveNow {
                            Text("LIVE")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                                .padding(5)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(Self.subtitle(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Month

    private var monthGrid: some View {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: monthAnchor)) ?? monthAnchor
        let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        // Laid out as explicit weeks. Blank cells and day numbers used to
        // share one lazy grid and collided on their ids, dropping the first
        // week and overlapping rows after a rotation.
        var cells: [Int?] = Array(repeating: nil, count: leading) + (1...dayCount).map { Optional($0) }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
        let symbols = Self.weekdaySymbols(calendar)

        return VStack(spacing: 6) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(monthStart.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .font(.headline)
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            HStack(spacing: 4) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 4) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                            let key = CalendarDayKey.dayKey(from: date)
                            dayCell(day: day, key: key, count: viewModel.entries(on: key).count)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, PhoneLayout.gutter)
    }

    private func dayCell(day: Int, key: String, count: Int) -> some View {
        let isSelected = key == selectedDayKey
        let isToday = key == todayKey
        return Button {
            selectedDayKey = key
            if isLandscape {
                withAnimation(.easeInOut(duration: 0.25)) { isDayPanelOpen = true }
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(day)")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? .black : .white)
                Circle()
                    .fill(count > 0 ? (isSelected ? Color.black : Color.white) : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white : (isToday ? Color.white.opacity(0.15) : .clear))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func dayEntries(_ key: String) -> some View {
        let entries = viewModel.entries(on: key)
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.dayTitle(key, todayKey: todayKey)).font(.headline)
            if entries.isEmpty {
                Text("Nothing scheduled")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entryRow($0) }
            }
        }
        .padding(.horizontal, PhoneLayout.gutter)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        monthAnchor = next
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if !viewModel.hasLoaded {
                ProgressView()
            } else {
                Image(systemName: "calendar").font(.largeTitle)
                Text("Nothing coming up. Episodes of shows in your Library appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    // MARK: Formatting

    private static let dayKeyParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayTitle(_ key: String, todayKey: String) -> String {
        guard let date = dayKeyParser.date(from: key) else { return key }
        let formatted = date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        if key == todayKey { return "Today · " + formatted }
        if key == CalendarDayKey.dayKey(offsetFromToday: 1) { return "Tomorrow · " + formatted }
        if key == CalendarDayKey.dayKey(offsetFromToday: -1) { return "Yesterday · " + formatted }
        return formatted
    }

    private static func subtitle(_ entry: CalendarEntry) -> String {
        switch entry.kind {
        case .movie:
            return "Movie release"
        case .sport:
            return [entry.sportGenre, entry.overview].compactMap { $0 }.joined(separator: " · ")
        case .series:
            return [entry.episodeCode, entry.episodeTitle].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private static func weekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}
#endif
