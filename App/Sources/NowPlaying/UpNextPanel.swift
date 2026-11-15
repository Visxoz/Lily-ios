import SwiftUI
import YTMCore
import YTMPlayback

/// The queue under "Up next", as `side-panel.slint` and `queue.slint` with
/// `queue_panel.rs` behind them: tap a row to play it, hold and drag it into
/// a new order, swipe it away, or pick several with Select (the desktop's
/// Ctrl-click) to remove them or play them next together. The header saves
/// the queue as a playlist or clears what is still to come.
///
/// A native `List` keeps the rows lazy and recycled and does the dragging,
/// so a long queue costs only the rows on screen. The list redraws when the
/// queue changes, never as the song plays. Rows, the selection and each
/// row's actions follow queue entries by ID, not place, so an edit animates
/// the rows it touched while the rest keep their state, and an open swipe or
/// menu acts on its own song however the queue has moved meanwhile.
struct UpNextPanel: View {
    /// Whether the panel is on screen; off it, the list keeps the song
    /// playing at its top, ready for the swipe up.
    let isShown: Bool
    /// Closes the panel, for a pull down past the top of the list.
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var editMode = EditMode.inactive
    /// Queue entries picked while selecting.
    @State private var selection = Set<Queue<Track>.Entry.ID>()

    var body: some View {
        let queue = app.player.queue
        VStack(spacing: 0) {
            header(count: queue.count)
            list(queue)
        }
        // Picks stay with their entries through an edit, such as Smart
        // Shuffle's inserts; a new queue, whose entries are all new, lets
        // them go, as ytm-native's `forget_selection`.
        .onChange(of: queue.revision) {
            guard !selection.isEmpty else { return }
            selection.formIntersection(app.player.queue.entries.lazy.map(\.id))
        }
    }

    private var editing: Bool { editMode.isEditing }

    private func header(count: Int) -> some View {
        HStack(spacing: 14) {
            Text(editing && !selection.isEmpty ? "\(selection.count) selected" : "Queue  •  \(Formatting.songs(count))")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer()
            if editing {
                Group {
                    PanelAction(title: "Play next") { app.player.playNext(queueOffsets: offsets(selection)) }
                    PanelAction(title: "Remove") { app.player.removeFromQueue(atOffsets: offsets(selection)) }
                }
                .disabled(selection.isEmpty)
                IconButton(icon: .close, size: 28, iconSize: 16) { stopSelecting() }
                    .accessibilityLabel("Done selecting")
            } else {
                if app.isSignedIn {
                    PanelAction(title: "Save") { app.player.saveQueueAsPlaylist() }
                }
                if count > 1 {
                    PanelAction(title: "Select") { editMode = .active }
                    PanelAction(title: "Clear") { app.player.clearUpcoming() }
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, NowPlayingScreen.padding)
        .animation(Theme.fast, value: editing)
    }

    private func list(_ queue: Queue<Track>) -> some View {
        let currentId = queue.currentIndex.map { queue.entries[$0].id }
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(queue.entries) { entry in
                    row(entry, current: entry.id == currentId)
                }
                .onMove { app.player.moveQueue(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Theme.queueRow)
            .environment(\.editMode, $editMode)
            .onScrollPhaseChange { old, new, context in
                if pulledPastTop(old, new, context.geometry) { close() }
            }
            .onAppear {
                if let currentId { proxy.scrollTo(currentId, anchor: .top) }
            }
            .onChange(of: currentId) {
                if !isShown, let currentId { proxy.scrollTo(currentId, anchor: .top) }
            }
            .onChange(of: isShown) {
                if !isShown, let currentId { proxy.scrollTo(currentId, anchor: .top) }
            }
        }
    }

    private func row(_ entry: Queue<Track>.Entry, current: Bool) -> some View {
        Button {
            if let index = offsets([entry.id]).first { app.player.jump(to: index) }
        } label: {
            QueueRow(track: entry.item, current: current, recommended: entry.isRecommended)
        }
        .buttonStyle(RowPress())
        // While selecting, a tap picks the row, which the list does.
        .allowsHitTesting(!editing)
        // Inset so the artwork lines up with the header, inside its own 8 points.
        .listRowInsets(EdgeInsets(top: 0, leading: NowPlayingScreen.padding - 8, bottom: 0, trailing: NowPlayingScreen.padding - 8))
        .listRowBackground(selection.contains(entry.id) ? theme.hover : Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            if !current {
                Button("Remove", role: .destructive) { app.player.removeFromQueue(atOffsets: offsets([entry.id])) }
            }
        }
        .contextMenu {
            Button("Play next") { app.player.playNext(queueOffsets: offsets([entry.id])) }
                .disabled(current)
            Button("Remove from queue") { app.player.removeFromQueue(atOffsets: offsets([entry.id])) }
                .disabled(current)
            TrackLibraryMenu(track: entry.item)
        }
    }

    /// Where the entries `ids` sit now, worked out only as an action runs;
    /// none for entries gone meanwhile.
    private func offsets(_ ids: Set<Queue<Track>.Entry.ID>) -> IndexSet {
        let entries = app.player.queue.entries
        return IndexSet(entries.indices.filter { ids.contains(entries[$0].id) })
    }

    private func stopSelecting() {
        editMode = .inactive
        selection.removeAll()
    }
}

/// `queue.slint`'s `PanelAction`: a text button in the panel's header.
private struct PanelAction: View {
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? theme.textSecondary : theme.textDim)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.95))
    }
}
