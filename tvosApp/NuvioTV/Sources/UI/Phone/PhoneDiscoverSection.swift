#if os(iOS)
import SwiftUI

/// Discover for the phone's Search tab: the same `DiscoverViewModel` the TV
/// and Mac embed in Search, so the filters come from the installed add-ons —
/// every type they declare, every catalog of that type, and its genres.
struct PhoneDiscoverSection: View {
    @ObservedObject var viewModel: DiscoverViewModel
    @ObservedObject private var nsfw = NSFWVisibility.shared
    let onSelect: (NuvioMeta) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discover")
                .font(.title3.weight(.bold))
                .padding(.horizontal, PhoneLayout.gutter)

            filters

            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else if viewModel.items.isEmpty {
                Text(viewModel.error ?? "Nothing in this catalog.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                // A kids profile sees only what the kids filter allows; when
                // that leaves a page short, the next one is fetched.
                PhoneKidsFiltered(items: viewModel.items) { visible, checking in
                    let shown = visible.uniquedByID()
                    if shown.isEmpty {
                        VStack(spacing: 10) {
                            if checking || viewModel.isLoadingMore {
                                ProgressView()
                            } else {
                                Text("Nothing for a kids profile in this catalog.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .task(id: "\(viewModel.items.count)-\(checking)") {
                            guard !checking, let last = viewModel.items.last else { return }
                            viewModel.loadMoreIfNeeded(currentItem: last)
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(shown, id: \.id) { meta in
                                Button { onSelect(meta) } label: {
                                    PhoneFlexiblePoster(meta: meta)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if shown.suffix(4).contains(where: { $0.id == meta.id }), let last = viewModel.items.last {
                                        viewModel.loadMoreIfNeeded(currentItem: last)
                                    } else {
                                        viewModel.loadMoreIfNeeded(currentItem: meta)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, PhoneLayout.gutter)
                    }
                }

                if viewModel.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
    }

    // MARK: Filters

    /// One scrolling row: Type, Catalog, Genre, then 18+. Each narrows the
    /// next, so they read left to right; the type chips took a row of their
    /// own above the menus.
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(viewModel.availableTypes) { type in
                        Button { viewModel.setType(type) } label: {
                            if type == viewModel.type {
                                Label(type.title, systemImage: "checkmark")
                            } else {
                                Text(type.title)
                            }
                        }
                    }
                } label: {
                    menuLabel(viewModel.type.title)
                }

                if !viewModel.catalogs.isEmpty {
                    Menu {
                        ForEach(viewModel.catalogs) { catalog in
                            Button { viewModel.setCatalog(catalog) } label: {
                                if catalog == viewModel.catalog {
                                    Label(viewModel.title(of: catalog), systemImage: "checkmark")
                                } else {
                                    Text(viewModel.title(of: catalog))
                                }
                            }
                        }
                    } label: {
                        menuLabel(viewModel.catalog.map { viewModel.title(of: $0) } ?? "Catalog")
                    }
                }

                if !viewModel.genres.isEmpty {
                    Menu {
                        if viewModel.allowsAllGenres {
                            Button { viewModel.setGenre(nil) } label: {
                                if viewModel.genre == nil {
                                    Label("All Genres", systemImage: "checkmark")
                                } else {
                                    Text("All Genres")
                                }
                            }
                        }
                        ForEach(viewModel.genres, id: \.self) { genre in
                            Button { viewModel.setGenre(genre) } label: {
                                if genre == viewModel.genre {
                                    Label(genre, systemImage: "checkmark")
                                } else {
                                    Text(genre)
                                }
                            }
                        }
                    } label: {
                        menuLabel(viewModel.genre ?? "All Genres")
                    }
                }

                // Search's NSFW toggle, which Discover follows; never on a
                // kids profile.
                if AdultContent.shared.hasAdultSources, !PhoneKidsMode.isActive {
                    chip("18+", isOn: nsfw.showsInSearch, onColor: .red) { nsfw.showsInSearch.toggle() }
                }
            }
            .padding(.horizontal, PhoneLayout.gutter)
        }
    }

    private func chip(
        _ title: String,
        isOn: Bool,
        onColor: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isOn ? onColor : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(isOn && onColor == .white ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.12), in: Capsule())
    }
}
#endif
