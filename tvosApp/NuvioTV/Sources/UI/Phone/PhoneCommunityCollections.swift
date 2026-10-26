#if os(iOS)
import SwiftUI

/// Settings → Layout → Collections → Community: browse the collections
/// shared on nuvio.tv and add them. In a kids profile the child-friendly
/// ones come first, marked as such.
struct PhoneCommunityCollectionsSheet: View {
    let accentColor: Color
    /// Adds the chosen entry's collections (the same merge as Import).
    let onAdd: (_ rows: [[String: Any]], _ title: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sort: CommunityCollections.Sort = .popular
    @State private var search = ""
    @State private var items: [CommunityCollections.Item] = []
    @State private var page = 1
    @State private var hasNextPage = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var adding: String?
    @State private var added: Set<String> = []

    private var forKids: Bool { PhoneKidsMode.isActive }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Sort", selection: $sort) {
                        ForEach(CommunityCollections.Sort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    if forKids {
                        Label("Kids profile: collections for children are listed first.", systemImage: "figure.and.child.holdinghands")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                }
                ForEach(CommunityCollections.ordered(items, forKids: forKids)) { item in
                    row(item)
                }
                if hasNextPage {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .onAppear { Task { await load(reset: false) } }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if isLoading, items.isEmpty { ProgressView() }
            }
            .searchable(text: $search, prompt: "Search collections")
            .onSubmit(of: .search) { Task { await load(reset: true) } }
            .navigationTitle("Community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: sort) { await load(reset: true) }
        }
    }

    private func row(_ item: CommunityCollections.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: FixtureArtwork.displayURL(item.imageURL)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.08)
                    .overlay(Image(systemName: "rectangle.stack").foregroundStyle(.secondary))
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if forKids, item.isKidFriendly {
                        Image(systemName: "star.circle.fill")
                            .foregroundStyle(accentColor)
                            .accessibilityLabel("For kids")
                    }
                }
                if !item.description.isEmpty {
                    Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(item.isPack ? "Pack · " : "")\(item.installs) installs · \(item.likes) likes")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await add(item) }
            } label: {
                Group {
                    if adding == item.id {
                        ProgressView()
                    } else if added.contains(item.id) {
                        Image(systemName: "checkmark")
                    } else {
                        Text("Add")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 52, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .disabled(adding != nil || added.contains(item.id))
        }
        .padding(.vertical, 2)
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let next = reset ? 1 : page + 1
        do {
            let result = try await CommunityCollections.list(sort: sort, search: search, page: next)
            items = reset ? result.items : items + result.items
            page = next
            hasNextPage = result.hasNextPage
            error = items.isEmpty ? "No collections found." : nil
        } catch {
            if reset { items = [] }
            hasNextPage = false
            self.error = error.localizedDescription
        }
    }

    private func add(_ item: CommunityCollections.Item) async {
        adding = item.id
        defer { adding = nil }
        do {
            var rows = try await CommunityCollections.collections(for: item)
            // A kids profile gets only the children's part of a big library.
            if forKids { rows = CommunityCollections.forKids(rows) }
            onAdd(rows, item.title)
            added.insert(item.id)
            await CommunityCollections.recordInstall(item)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
