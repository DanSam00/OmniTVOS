#if os(macOS)
import SwiftUI

/// Carries a "play this download" from the Downloads tab up to ContentView,
/// which owns the player. A notification rather than a closure threaded
/// through the tab view, which takes enough parameters already.
struct MacPlayDownloadModifier: ViewModifier {
    private static let notification = Notification.Name("omni.downloads.play")

    static func request(_ record: DownloadRecord) {
        NotificationCenter.default.post(name: notification, object: record.contentId)
    }

    let play: (DownloadRecord) -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: Self.notification)) { note in
            guard let id = note.object as? String,
                  let record = DownloadManager.shared.record(for: id) else { return }
            play(record)
        }
    }
}

/// The Mac's Downloads tab: movies, then each show's episodes in order, with
/// their status. Up and Down move; Return plays a finished download and
/// pauses, resumes or retries the rest; Right reaches the row's delete
/// button; Left from a row opens the menu. The mouse does the same.
struct MacDownloadsView: View {
    let isActive: Bool
    let onPlay: (DownloadRecord) -> Void
    let onOpen: (String, String) -> Void

    @ObservedObject private var downloads = DownloadManager.shared
    @State private var caret = 0
    @State private var caretOnDelete = false
    @State private var macKeyToken: UUID?
    @State private var scrollProxy: ScrollViewProxy?
    private let keyRouter = MacKeyRouter.shared

    private var mine: [DownloadRecord] {
        let profile = ProfileSettings.activeProfileScope
        return downloads.records.values.filter { $0.profileId == profile }
    }

    /// Sections in order, each with its rows.
    private var sections: [(title: String, rows: [DownloadRecord])] {
        let movies = mine.filter { $0.season == nil }.sorted { $0.createdAt > $1.createdAt }
        let shows = Dictionary(grouping: mine.filter { $0.season != nil }, by: \.meta.id).values
            .map { records in
                (records[0].meta.name, records.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) })
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        return (movies.isEmpty ? [] : [("Movies", movies)]) + shows.map { ($0.0, $0.1) }
    }

    private var flatRows: [DownloadRecord] { sections.flatMap(\.rows) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Downloads")
                            .font(.system(size: 52, weight: .bold))
                        Text(subtitle)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    if flatRows.isEmpty {
                        Text("Movies and episodes you download appear here, ready to watch without a connection. Use the download button on a title's page, or press D on an episode.")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 900, alignment: .leading)
                            .padding(.top, 40)
                    }
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.title)
                                .font(.system(size: 30, weight: .semibold))
                            ForEach(section.rows) { record in
                                row(record).id(record.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 70)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollProxy = proxy }
        }
        .foregroundStyle(.white)
        .onAppear { claimKeysIfActive() }
        .onChange(of: isActive) { _, _ in claimKeysIfActive() }
        .onDisappear { keyRouter.release(macKeyToken); macKeyToken = nil }
        .onReceive(keyRouter.presses.map(Optional.some)) { press in
            guard let press, keyRouter.isFront(macKeyToken) else { return }
            handleKey(press.key)
        }
    }

    private var subtitle: String {
        let folder = DownloadManager.directory.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return "\(DownloadSettings.label(for: max(downloads.storageUsed, 0))) used · Saved in \(folder)"
    }

    private func isCaret(_ record: DownloadRecord) -> Bool {
        isActive && flatRows.indices.contains(caret) && flatRows[caret].id == record.id
    }

    private func row(_ record: DownloadRecord) -> some View {
        let highlighted = isCaret(record)
        let waiting = downloads.isWaitingForWiFi(record)
        return HStack(spacing: 22) {
            Button { primary(record) } label: {
                HStack(spacing: 22) {
                    AsyncImage(url: URL(string: DownloadManager.listArtwork(for: record) ?? "")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .frame(width: 220, height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title(record))
                            .font(.system(size: 26, weight: .semibold))
                            .lineLimit(1)
                        Text(DownloadStatusText.status(record: record, waiting: waiting) ?? "")
                            .font(.system(size: 20))
                            .foregroundStyle(record.state == .failed || record.state == .needsSource ? Color.orange : Color.secondary)
                            .lineLimit(2)
                        if record.state == .downloading || record.state == .paused {
                            ProgressView(value: record.progress)
                                .tint(.white)
                                .frame(maxWidth: 520)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: symbol(record))
                        .font(.system(size: 30, weight: .semibold))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(highlighted && !caretOnDelete ? 0.16 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white, lineWidth: highlighted && !caretOnDelete ? 3 : 0)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { downloads.delete(record.contentId) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Color.white.opacity(highlighted && caretOnDelete ? 0.22 : 0.08)))
                    .overlay(Circle().stroke(Color.white, lineWidth: highlighted && caretOnDelete ? 3 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete Download")
        }
    }

    private func title(_ record: DownloadRecord) -> String {
        guard let season = record.season, let episode = record.episode else { return record.meta.name }
        return "S\(season) E\(episode) · \(record.episodeTitle ?? "Episode \(episode)")"
    }

    private func symbol(_ record: DownloadRecord) -> String {
        switch record.state {
        case .completed: return "play.circle.fill"
        case .downloading, .queued, .resolving: return "pause.circle"
        case .paused: return "arrow.down.circle"
        case .failed: return "exclamationmark.arrow.triangle.2.circlepath"
        case .needsSource: return "questionmark.circle"
        case .findingSource: return "ellipsis.circle"
        }
    }

    private func primary(_ record: DownloadRecord) {
        switch record.state {
        case .completed: onPlay(record)
        case .downloading, .queued, .resolving: downloads.pause(record.contentId)
        case .paused, .failed: downloads.resume(record.contentId)
        case .needsSource: onOpen(record.meta.id, record.meta.type)
        case .findingSource: break
        }
    }

    // MARK: Keyboard

    private func claimKeysIfActive() {
        keyRouter.release(macKeyToken)
        macKeyToken = isActive ? keyRouter.claim() : nil
    }

    private func handleKey(_ key: MacKey) {
        guard isActive else { return }
        let menu = MacMenuState.shared
        if key == .activate {
            if menu.handleReturn() { return }
        } else if let move = direction(for: key), menu.handleMove(move) {
            return
        }
        let rows = flatRows
        guard !rows.isEmpty else {
            if key == .left { menu.open() }
            return
        }
        caret = min(caret, rows.count - 1)
        switch key {
        case .up, .down:
            let next = caret + (key == .up ? -1 : 1)
            guard rows.indices.contains(next) else { return }
            caret = next
            caretOnDelete = false
            withAnimation(.easeOut(duration: 0.2)) { scrollProxy?.scrollTo(rows[next].id, anchor: .center) }
        case .right:
            caretOnDelete = true
        case .left:
            if caretOnDelete { caretOnDelete = false } else { menu.open() }
        case .activate:
            let record = rows[caret]
            if caretOnDelete {
                downloads.delete(record.contentId)
                caretOnDelete = false
            } else {
                primary(record)
            }
        default:
            break
        }
    }

    private func direction(for key: MacKey) -> MoveCommandDirection? {
        switch key {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        default: return nil
        }
    }
}
#endif
