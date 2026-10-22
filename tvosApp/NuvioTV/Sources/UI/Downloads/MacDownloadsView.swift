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

/// The Mac's downloads, shown in Library beside Saved and Cloud: movies, then
/// each show's episodes in order, with their status. Library's keyboard model
/// drives it (one band, two columns: the row and its delete button), so this
/// view only draws the caret it is given. The mouse works as before: a click
/// plays a finished download and pauses, resumes or retries the rest.
struct MacDownloadsList: View {
    /// The row the caret is on, and whether it sits on that row's delete button.
    let focusedRowID: String?
    let focusOnDelete: Bool
    let onOpen: (String, String) -> Void

    @ObservedObject private var downloads = DownloadManager.shared

    /// Suffix that marks a row's delete button in Library's focus band.
    static let deleteSuffix = "#delete"

    /// The active profile's downloads.
    @MainActor
    private static var mine: [DownloadRecord] {
        let profile = ProfileSettings.activeProfileScope
        return DownloadManager.shared.records.values.filter { $0.profileId == profile }
    }

    /// Sections in order, each with its rows.
    @MainActor
    static var sections: [(title: String, rows: [DownloadRecord])] {
        let movies = mine.filter { $0.season == nil }.sorted { $0.createdAt > $1.createdAt }
        let shows = Dictionary(grouping: mine.filter { $0.season != nil }, by: \.meta.id).values
            .map { records in
                (records[0].meta.name, records.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) })
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        return (movies.isEmpty ? [] : [("Movies", movies)]) + shows.map { ($0.0, $0.1) }
    }

    /// Every row in display order: the focus band's order.
    @MainActor
    static var rows: [DownloadRecord] { sections.flatMap(\.rows) }

    /// Return or a click on a row.
    @MainActor
    static func activate(_ record: DownloadRecord, onOpen: (String, String) -> Void) {
        let downloads = DownloadManager.shared
        switch record.state {
        case .completed: MacPlayDownloadModifier.request(record)
        case .downloading, .queued, .resolving: downloads.pause(record.contentId)
        case .paused, .failed: downloads.resume(record.contentId)
        case .needsSource: onOpen(record.meta.id, record.meta.type)
        case .findingSource: break
        }
    }

    var body: some View {
        let sections = Self.sections
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    if sections.isEmpty {
                        Text("Movies and episodes you download appear here, ready to watch without a connection. Use the download button on a title's page, or press D on an episode.")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 900, alignment: .leading)
                            .padding(.top, 20)
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
                .padding(.top, 8)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: focusedRowID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .foregroundStyle(.white)
    }

    private var subtitle: String {
        let folder = DownloadManager.directory.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return "\(DownloadSettings.label(for: max(downloads.storageUsed, 0))) used · Saved in \(folder)"
    }

    private func row(_ record: DownloadRecord) -> some View {
        let highlighted = focusedRowID == record.id
        let caretOnDelete = focusOnDelete
        let waiting = downloads.isWaitingForWiFi(record)
        return HStack(spacing: 22) {
            Button { Self.activate(record, onOpen: onOpen) } label: {
                HStack(spacing: 22) {
                    AsyncImage(url: FixtureArtwork.displayURL(URL(string: DownloadManager.listArtwork(for: record) ?? ""))) { image in
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
}
#endif
