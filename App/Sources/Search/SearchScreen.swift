import SwiftUI
import YTMCore

struct SearchScreen: View {
    private static let suggestDelay: Duration = .milliseconds(150)
    private static let suggestFrom = 2
    private static let suggestionLimit = 8
    private static let filters = ["All"] + SearchKind.allCases.map(\.title)

    @Environment(AppModel.self) private var app
    @State private var query = ""
    /// Typed since focusing the field, so suggestions replace the recent searches.
    @State private var typed = false
    @State private var suggestions: [String] = []
    @State private var shown: String?
    /// An index into `filters`; each new search starts on All, with its top result.
    @State private var filter = 0

    var body: some View {
        @Bindable var app = app
        let recents = app.history.searches.queries
        // The results stay in the tree under the choices, so cancelling a search shows them again where they were.
        ZStack {
            if let shown {
                let route = Route.search(shown, filter == 0 ? nil : SearchKind.allCases[filter - 1])
                PageScreen(route: route)
                    .id(route)
                    .safeAreaBar(edge: .top) {
                        PillGroup(titles: Self.filters, selection: $filter)
                            .padding(.horizontal, Metrics.pagePadding)
                            .padding(.vertical, 8)
                    }
                    // Covered by the choices while searching, so VoiceOver skips it.
                    .accessibilityHidden(app.isSearching)
            } else if recents.isEmpty {
                SearchPrompt()
            }
            // Before the first search, recent searches fill the page instead of waiting for focus.
            if app.isSearching || (shown == nil && !recents.isEmpty) {
                SearchChoices(
                    choices: showsRecent ? recents : suggestions,
                    recent: showsRecent,
                    pick: search
                )
            }
        }
        // Our own bar, as the system's field always takes a row of its own under the account button on iPhone, and
        // focus doesn't reach a field put in the toolbar.
        .safeAreaBar(edge: .top) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    SearchField(query: $query, isSearching: $app.isSearching) { search(query) }
                    AccountButton(edge: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 4)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: app.isSearching) { _, active in
            // Each focus starts with the recent searches, even over the last query.
            typed = false
            guard !active else { return }
            suggestions = []
            // Cancelled, the field names the results under it again.
            if let shown { query = shown }
        }
        .onChange(of: query) {
            if app.isSearching { typed = true }
        }
        .task(id: suggestKey) { await suggest(suggestKey) }
    }

    private var showsRecent: Bool {
        query.isEmpty || !typed
    }

    /// The query to suggest for, or nil when none is wanted; each change restarts the wait, dropping the last request.
    private var suggestKey: String? {
        guard app.isSearching, !showsRecent else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= Self.suggestFrom ? trimmed : nil
    }

    private func suggest(_ query: String?) async {
        guard let query else {
            suggestions = []
            return
        }
        do {
            try await Task.sleep(for: Self.suggestDelay)
        } catch {
            return
        }
        let found = await app.api.suggestions(for: query)
        guard !Task.isCancelled else { return }
        suggestions = Array(found.prefix(Self.suggestionLimit))
    }

    private func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.isSearching = false
        query = trimmed
        app.history.recordSearch(trimmed)
        app.navigation(for: .search).routes.removeAll()
        filter = 0
        shown = trimmed
    }
}

private struct SearchField: View {
    @Binding var query: String
    @Binding var isSearching: Bool
    let submit: () -> Void

    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: .search, size: 17, colour: theme.textSecondary)
            TextField("What do you want to play?", text: $query)
                .scaledFont(17)
                .foregroundStyle(theme.text)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(submit)
                .accessibilityAddTraits(.isSearchField)
                .accessibilityAction(.escape) { isSearching = false }
            if isSearching {
                // Clears the text first, as the system's field does, then ends the search.
                IconButton(icon: .close, size: 44, iconSize: 15) {
                    if query.isEmpty { isSearching = false } else { query = "" }
                }
                .accessibilityLabel(query.isEmpty ? "Cancel" : "Clear text")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, isSearching ? 0 : 14)
        .frame(maxWidth: .infinity, minHeight: 44)
        // The whole capsule focuses the field, not only its line of text.
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .glassEffect(.regular.interactive(), in: Capsule())
        // Only focus starts a search: the keyboard going, as a scroll or a sheet sends it, leaves the search open.
        .onChange(of: focused) { if $1 { isSearching = true } }
        .onChange(of: isSearching) { focused = $1 }
    }
}

private struct SearchChoices: View {
    let choices: [String]
    let recent: Bool
    let pick: (String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            ForEach(choices, id: \.self) { choice in
                HStack(spacing: 14) {
                    Button { pick(choice) } label: {
                        HStack(spacing: 14) {
                            IconView(icon: recent ? .history : .search, size: 18, colour: theme.textSecondary)
                            Text(choice)
                                .scaledFont(15)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if recent {
                        IconButton(icon: .close, iconSize: 16) { remove(choice) }
                            .accessibilityLabel("Remove \u{201C}\(choice)\u{201D}")
                    }
                }
                .listRowBackground(theme.panel)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    if recent {
                        Button("Remove", role: .destructive) { remove(choice) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.panel)
        .scrollDismissesKeyboard(.immediately)
    }

    /// Animated, so rows slide out rather than snap.
    private func remove(_ choice: String) {
        withAnimation { app.history.removeSearch(choice) }
    }
}

private struct SearchPrompt: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            IconView(icon: .search, size: 48, colour: theme.textDim)
            Text("What do you want to play?")
                .scaledFont(18, weight: .semibold)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel)
    }
}
