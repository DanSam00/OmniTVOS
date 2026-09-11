import SwiftUI

private enum SystemSearchMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
    static let contentInset: CGFloat = 36
}

/// Search built on tvOS's own search experience.
///
/// Unlike the Netflix and Classic styles — which draw their own inline A–Z
/// keyboard — this hands the field to `.searchable`, so selecting it presents
/// the system keyboard with dictation. That means the Siri Remote's mic, voice
/// entry, and any future system search affordances come for free rather than
/// being reimplemented.
struct SystemSearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @FocusState private var focusedResultID: String?
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        NavigationStack {
            ZStack {
                Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
                content
            }
            // tvOS presents its full-screen search UI — system keyboard plus
            // dictation — when this field is selected.
            .searchable(
                text: $viewModel.searchText,
                placement: .automatic,
                prompt: Text(L10n.string("search_placeholder", fallback: "Search movies & series"))
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.results.isEmpty {
            resultsGrid
        } else if viewModel.hasQuery {
            message(L10n.string("search_no_results", fallback: "No results"))
        } else {
            message(L10n.string(
                "search_prompt_hint",
                fallback: "Select the search field to look up movies and series."
            ))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 26))
            .foregroundColor(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: SystemSearchMetrics.posterGap) {
                ForEach(viewModel.results) { item in
                    PosterGridCard(
                        meta: item,
                        width: SystemSearchMetrics.posterWidth,
                        height: SystemSearchMetrics.posterHeight,
                        externalFocus: $focusedResultID,
                        onLongPress: onLongPress.map { callback in { callback(item) } },
                        forceShowLabels: true
                    ) {
                        viewModel.lastFocusedResultID = item.id
                        onContentClick(item.id, item.type)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, SystemSearchMetrics.contentInset)
        }
        .focusSection()
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: SystemSearchMetrics.posterWidth,
                maximum: SystemSearchMetrics.posterWidth
            ),
            spacing: SystemSearchMetrics.posterGap,
            alignment: .top
        )]
    }
}
