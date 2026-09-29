#if os(iOS)
import SwiftUI

/// Discover for the phone's Search tab: the same `DiscoverViewModel` the TV
/// and Mac embed in Search, so the filters come from the installed add-ons —
/// every type they declare, every catalog of that type, and its genres.
struct PhoneDiscoverSection: View {
    @ObservedObject var viewModel: DiscoverViewModel
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
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.items, id: \.id) { meta in
                        Button { onSelect(meta) } label: {
                            GeometryReader { proxy in
                                PhonePosterCard(meta: meta, width: proxy.size.width)
                            }
                            .aspectRatio(1 / (PhoneLayout.posterAspect + 0.18), contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .onAppear { viewModel.loadMoreIfNeeded(currentItem: meta) }
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)

                if viewModel.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Type: one chip per type the add-ons offer.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.availableTypes) { type in
                        chip(type.title, isOn: viewModel.type == type) { viewModel.setType(type) }
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)
            }

            HStack(spacing: 8) {
                if !viewModel.catalogs.isEmpty {
                    Menu {
                        ForEach(viewModel.catalogs) { catalog in
                            Button { viewModel.setCatalog(catalog) } label: {
                                if catalog == viewModel.catalog {
                                    Label(catalog.title, systemImage: "checkmark")
                                } else {
                                    Text(catalog.title)
                                }
                            }
                        }
                    } label: {
                        menuLabel(viewModel.catalog?.title ?? "Catalog", systemImage: "square.stack")
                    }
                }

                if !viewModel.genres.isEmpty {
                    Menu {
                        Button { viewModel.setGenre(nil) } label: {
                            if viewModel.genre == nil {
                                Label("All Genres", systemImage: "checkmark")
                            } else {
                                Text("All Genres")
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
                        menuLabel(viewModel.genre ?? "All Genres", systemImage: "theatermasks")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PhoneLayout.gutter)
        }
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

    private func menuLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption)
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.12), in: Capsule())
    }
}
#endif
