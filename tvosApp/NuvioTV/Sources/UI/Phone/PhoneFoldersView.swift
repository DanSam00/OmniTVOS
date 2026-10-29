#if os(iOS)
import SwiftUI

/// Library → Folders: the viewer's own on-demand libraries as their sources
/// arrange them. An IPTV provider's films and shows by its categories, and a
/// Jellyfin server's libraries and folders. A film or show opens its page,
/// which plays it from where it was found.
struct PhoneFoldersView: View {
    let onSelect: (String, String) -> Void

    @ObservedObject private var jellyfin = JellyfinServerStore.shared
    @State private var iptvSources: [IPTVSource] = IPTVVODBrowser.sources()

    /// Whether there is anything to browse: the Library only offers Folders then.
    static var isAvailable: Bool { LibraryFoldersModel.isAvailable }

    var body: some View {
        List {
            ForEach(iptvSources, id: \.id) { source in
                Section(source.name.vodNonBlank ?? "IPTV") {
                    ForEach(IPTVVODBrowser.Kind.allCases, id: \.self) { kind in
                        NavigationLink {
                            PhoneIPTVCategoriesView(source: source, kind: kind, onSelect: onSelect)
                        } label: {
                            Label(kind.title, systemImage: kind == .movies ? "film" : "tv")
                        }
                    }
                }
            }
            ForEach(jellyfin.servers, id: \.id) { server in
                PhoneJellyfinServerSection(server: server, onSelect: onSelect)
            }
            if iptvSources.isEmpty && jellyfin.servers.isEmpty {
                Text("Add an IPTV login or a Jellyfin server in Settings to browse its folders here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .phoneTabBarFoldsOnScroll()
        .onReceive(NotificationCenter.default.publisher(for: IPTVSourceStore.changedNotification)) { _ in
            iptvSources = IPTVVODBrowser.sources()
        }
    }
}

// MARK: - IPTV

private struct PhoneIPTVCategoriesView: View {
    let source: IPTVSource
    let kind: IPTVVODBrowser.Kind
    let onSelect: (String, String) -> Void

    @State private var categories: [IPTVVODBrowser.Category]?
    @State private var filter = ""

    private var shown: [IPTVVODBrowser.Category] {
        let all = categories ?? []
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        List(shown) { category in
            NavigationLink {
                PhoneIPTVEntriesView(source: source, kind: kind, category: category, onSelect: onSelect)
            } label: {
                Text(category.name)
            }
        }
        .listStyle(.plain)
        .overlay {
            if categories == nil {
                ProgressView()
            } else if categories?.isEmpty == true {
                PhoneFoldersEmpty(text: "Your provider lists no \(kind.title.lowercased()).")
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Categories")
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if categories == nil { categories = await IPTVVODBrowser.shared.categories(source: source, kind: kind) } }
        .phoneTabBarFoldsOnScroll()
    }
}

private struct PhoneIPTVEntriesView: View {
    let source: IPTVSource
    let kind: IPTVVODBrowser.Kind
    let category: IPTVVODBrowser.Category
    let onSelect: (String, String) -> Void

    @State private var entries: [IPTVVODBrowser.Entry]?
    @State private var filter = ""

    private var shown: [IPTVVODBrowser.Entry] {
        let all = entries ?? []
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        ScrollView {
            PhoneFolderGrid {
                ForEach(shown) { entry in
                    Button { onSelect(entry.contentID, entry.type) } label: {
                        PhoneFolderCard(title: entry.name, subtitle: entry.year.map(String.init), poster: entry.poster, placeholder: kind == .movies ? "film" : "tv")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if entries == nil {
                ProgressView()
            } else if entries?.isEmpty == true {
                PhoneFoldersEmpty(text: "Nothing in this category.")
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titles")
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if entries == nil { entries = await IPTVVODBrowser.shared.entries(source: source, kind: kind, categoryID: category.id) } }
        .phoneTabBarFoldsOnScroll()
    }
}

// MARK: - Jellyfin

private struct PhoneJellyfinServerSection: View {
    let server: JellyfinServerConfig
    let onSelect: (String, String) -> Void

    @State private var libraries: [JellyfinLibrary]?
    @State private var failed = false

    var body: some View {
        Section(server.displayName) {
            if let libraries {
                ForEach(libraries) { library in
                    NavigationLink {
                        PhoneJellyfinFolderView(server: server, folderID: library.id, title: library.name, onSelect: onSelect)
                    } label: {
                        Label(library.name, systemImage: JellyfinBrowse.symbol(for: library.collectionType))
                    }
                }
            } else if failed {
                Text("Couldn't reach this server.").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task {
            guard libraries == nil, let client = JellyfinBrowse.client(for: server) else {
                if libraries == nil { failed = true }
                return
            }
            do { libraries = try await client.libraries(userId: server.userId) } catch { failed = true }
        }
    }
}

private struct PhoneJellyfinFolderView: View {
    let server: JellyfinServerConfig
    let folderID: String
    let title: String
    let onSelect: (String, String) -> Void

    @State private var items: [JellyfinBrowseItem]?
    @State private var filter = ""
    @State private var notSynced: JellyfinBrowseItem?

    private var shown: [JellyfinBrowseItem] {
        let all = items ?? []
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        ScrollView {
            PhoneFolderGrid {
                ForEach(shown) { item in
                    if item.isTitle {
                        Button { open(item) } label: { card(item) }
                            .buttonStyle(.plain)
                    } else if item.isFolder {
                        NavigationLink {
                            PhoneJellyfinFolderView(server: server, folderID: item.id, title: item.name, onSelect: onSelect)
                        } label: { card(item) }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay {
            if items == nil {
                ProgressView()
            } else if items?.isEmpty == true {
                PhoneFoldersEmpty(text: "This folder is empty.")
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titles")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard items == nil, let client = JellyfinBrowse.client(for: server) else { return }
            items = (try? await client.children(userId: server.userId, parentId: folderID)) ?? []
        }
        .alert(
            "Not synced yet",
            isPresented: Binding(get: { notSynced != nil }, set: { if !$0 { notSynced = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(notSynced?.name ?? "This title") is in a library Omni hasn't synced. Turn that library on in Settings → Jellyfin, then sync.")
        }
        .phoneTabBarFoldsOnScroll()
    }

    /// Titles open from the synced index, which holds their episodes and files.
    private func open(_ item: JellyfinBrowseItem) {
        let contentID = JellyfinLibraryIndex.contentId(serverID: server.id, itemId: item.id)
        guard JellyfinLibraryIndex.shared.meta(forContentId: contentID) != nil else {
            notSynced = item
            return
        }
        onSelect(contentID, item.type == "Series" ? "series" : "movie")
    }

    private func card(_ item: JellyfinBrowseItem) -> some View {
        PhoneFolderCard(
            title: item.name,
            subtitle: item.year.map(String.init),
            poster: JellyfinBrowse.imageURL(server: server, item: item),
            placeholder: item.isTitle ? (item.type == "Series" ? "tv" : "film") : "folder.fill"
        )
    }
}

// MARK: - Pieces

private struct PhoneFolderGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16, content: content)
            .padding(.horizontal, PhoneLayout.gutter)
            .padding(.vertical, 8)
    }
}

/// A poster card as the Library draws them; a folder or a title without
/// artwork shows its symbol instead.
private struct PhoneFolderCard: View {
    let title: String
    let subtitle: String?
    let poster: String?
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1 / PhoneLayout.posterAspect, contentMode: .fit)
                .overlay {
                    if let poster {
                        PhoneArtwork(url: poster)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: placeholder)
                                .font(.system(size: 30, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct PhoneFoldersEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
    }
}
#endif
