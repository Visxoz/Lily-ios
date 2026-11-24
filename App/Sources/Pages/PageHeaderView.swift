import SwiftUI
import YTMCore

struct PageHeaderView: View {
    let header: PageHeader
    let canPlay: Bool
    let canShuffle: Bool
    let canRadio: Bool
    /// The artwork blurred, which a banner fades into towards its foot.
    let backdrop: PageBackdrop?
    /// The navigation bar's height, which a banner reaches up under.
    let topInset: CGFloat
    /// The banner's width in pixels, which its decode is cut to; nil until measured.
    let bannerPixelWidth: Int?
    /// Under iPhone Duo's column of tabs only; elsewhere it would mirror the banner into the pull to refresh's space.
    let extendsBanner: Bool
    /// Wider than tall, as iPhone Duo open.
    let isWide: Bool
    let download: DownloadButton?
    /// The page's address, which a menu at the end of the buttons copies.
    let link: String?
    /// The page from YouTube, which saves and subscribes; nil for one held on the device.
    let model: PageModel?
    /// Opens the rename or delete dialog of the account's own playlist; nil for any other page.
    let edit: ((PlaylistDialog) -> Void)?
    let perform: (HeaderAction) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var fit = ActionsFit()

    private nonisolated static let actionsSpace = "actions"

    /// The page samples its tint at this size (and a banner's width) too, so the decode is shared.
    static func artEdge(_ header: PageHeader, topInset: CGFloat) -> CGFloat {
        header.banner ? Metrics.bannerHeight + topInset : Metrics.headerArt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if header.banner {
                let height = Self.artEdge(header, topInset: topInset)
                ZStack(alignment: .bottomLeading) {
                    // Not loaded until the width is known, so an uncut decode never lands in the cache beside the cut one.
                    ArtworkImage(url: bannerPixelWidth == nil ? nil : header.thumbnail, edge: height, placeholder: false, pixelWidth: bannerPixelWidth)
                        .frame(height: height)
                        // Sharp down to just above the text, then as if behind frosted glass, which the text sits
                        // on. Laid out as the photograph, so the two line up.
                        .overlay {
                            if let frosted = backdrop?.frosted {
                                FrostedGlass(frosted: frosted)
                                    // The banner's size, so the fades are measured on it rather than on an image
                                    // overhanging it.
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .mask(PageTint.fade(from: 0.2, to: 0.45, edge: .bottom))
                                    .mask(besideText)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.5), value: backdrop?.frosted == nil)
                        // The page's colour behind the text, as the frost is set by the whole photograph, so a
                        // bright or dark patch of it there would still show through.
                        .overlay {
                            LinearGradient(colors: [theme.panel.opacity(0), theme.panel.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                                .mask(PageTint.fade(from: 0.15, to: 0.45, edge: .bottom))
                                .mask(besideText)
                        }
                        .clipped()
                        // Into the page's backdrop at the foot, so the songs below meet no edge.
                        .mask(PageTint.fade(from: isWide ? 0.8 : 0.7))
                        .backgroundExtensionEffect(isEnabled: extendsBanner)
                    // An artist's Subscribe beside its count of subscribers, leaving the row below room for words.
                    HeaderText(header: header, foreground: theme.text, secondary: theme.textSecondary) {
                        subscribe(small: true)
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.bottom, 20)
                }
                .frame(height: height)
                .padding(.top, -topInset)
            } else {
                let hasArt = header.thumbnail != nil || canPlay
                VStack(spacing: 20) {
                    if hasArt {
                        ArtworkView(
                            url: header.thumbnail, size: Self.artEdge(header, topInset: topInset), radius: 10,
                            shadow: (theme.shadowDeep, 28, 14)
                        )
                    }
                    HeaderText(header: header, foreground: theme.text, secondary: theme.textSecondary, centred: hasArt) {}
                        .frame(maxWidth: .infinity, alignment: hasArt ? .center : .leading)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, hasArt ? 4 : 24)
            }

            if canPlay || canRadio || link != nil || canSave || canSubscribe {
                // The room the row has, which the row inside measures itself against.
                Color.clear
                    .overlay(alignment: .leading) { actions }
                    .coordinateSpace(.named(Self.actionsSpace))
                    .padding(.horizontal, Metrics.pagePadding)
                    .frame(height: Metrics.actionsHeight)
            }
        }
    }

    /// On a wide screen, the banner's frost and wash only behind the text: right across, they read as a wall of blur.
    private var besideText: LinearGradient {
        isWide ? PageTint.fade(from: 0.3, to: 0.6, edge: .leading) : LinearGradient(colors: [.black], startPoint: .top, endPoint: .bottom)
    }

    private var canSave: Bool {
        model != nil && header.saved != nil && header.playlistId != nil && header.editable != true
    }

    private var canSubscribe: Bool {
        model != nil && header.subscribed != nil && header.channelId != nil
    }

    /// Built once, so its download button and menu aren't made again for each width tried. Shuffle, then Play, drop
    /// their words where the row would overflow, then the icons narrow, as on iPhone Duo's outer screen.
    private var actions: some View {
        let narrow = fit.narrow
        return HStack(spacing: 0) {
            // The rest to the far end, unless they are all there is.
            if canPlay || canShuffle {
                if narrow {
                    pills(labels: 0, gap: 0)
                } else {
                    // Offered the room the icons leave, so the first that fits is the first whole row that would.
                    ViewThatFits(in: .horizontal) {
                        pills(labels: 2, gap: 8)
                        pills(labels: 1, gap: 8)
                        pills(labels: 0, gap: 8)
                    }
                }
            }
            icons(target: narrow ? 36 : 44)
        }
        .onGeometryChange(for: ActionsMeasure.self) { proxy in
            ActionsMeasure(width: proxy.size.width, room: proxy.bounds(of: .named(Self.actionsSpace))?.width ?? proxy.size.width)
        } action: { measure in
            // Only a row with full-size icons says whether they fit, and one that fits changes nothing, so the
            // header isn't drawn again on every page opened.
            // shortcut: narrowed, the icons stay so after the row gets shorter (a button gone, Subscribed back to
            // Subscribe, a smaller text size), until the room changes; measure the full-size row apart should that show.
            if fit.narrow {
                fit.room = measure.room
            } else if measure.width > measure.room + 0.5 {
                fit = ActionsFit(room: measure.room, needed: measure.width)
            }
        }
    }

    /// `labels` is how many of Play and Shuffle keep their words; `gap` the least room before the icons.
    private func pills(labels: Int, gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            if canPlay {
                ActionPill(icon: .play, title: "Play", primary: true, compact: labels < 1) { perform(.play) }
                    .padding(.trailing, 8)
            }
            if canShuffle {
                ActionPill(icon: .shuffle, title: "Shuffle", compact: labels < 2) { perform(.shuffle) }
            }
            Spacer(minLength: gap)
        }
    }

    /// `target` is the width of each icon's.
    private func icons(target: CGFloat) -> some View {
        HStack(spacing: 0) {
            if canRadio {
                IconButton(icon: .radio, size: target, iconSize: 24) { perform(.radio) }
                    .accessibilityLabel("Start radio")
            }
            download
            if canSave, let model {
                let saved = header.saved == true
                IconButton(icon: saved ? .inLibrary : .saveToPlaylist, size: target, iconSize: 24, active: saved) {
                    app.toggleInLibrary(subscribe: false, in: model)
                }
                .accessibilityLabel(saved ? "Remove from library" : "Save to library")
            }
            if !header.banner {
                subscribe(small: false).padding(.horizontal, 4)
            }
            if let link {
                Menu {
                    Button("Copy link") { app.copyLink(link) }
                    if let edit {
                        Button("Rename") { edit(.rename) }
                        Divider()
                        Picker("Who can see it", selection: privacy) {
                            ForEach(PlaylistPrivacy.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("Delete playlist", role: .destructive) { edit(.delete) }
                    }
                } label: {
                    IconView(icon: .more, size: 24, colour: theme.textSecondary)
                        .frame(width: target, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("More")
            }
        }
    }

    @ViewBuilder private func subscribe(small: Bool) -> some View {
        if canSubscribe, let model {
            let subscribed = header.subscribed == true
            PillButton(title: subscribed ? "Subscribed" : "Subscribe", primary: !subscribed, small: small) {
                app.toggleInLibrary(subscribe: true, in: model)
            }
        }
    }

    /// Unknown shows as Private, as YouTube makes playlists.
    private var privacy: Binding<PlaylistPrivacy> {
        Binding(get: { header.privacy ?? .private }, set: { privacy in
            if let model { app.setPrivacy(privacy, in: model) }
        })
    }
}

/// The action row's width and the room it has, measured together so neither is stale against the other.
private nonisolated struct ActionsMeasure: Equatable {
    let width: CGFloat
    let room: CGFloat
}

/// The icons narrow once a row with full-size ones overflows, and widen again once the room reaches that row.
private nonisolated struct ActionsFit: Equatable {
    var room: CGFloat = 0
    /// The row with full-size icons, when it overflowed; zero while it fits.
    var needed: CGFloat = 0

    var narrow: Bool { needed > room + 0.5 }
}

private struct HeaderText<Trailing: View>: View {
    let header: PageHeader
    let foreground: Color
    let secondary: Color
    /// Under centred artwork.
    var centred = false
    /// After the details, on their line.
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: centred ? .center : .leading, spacing: 4) {
            if !header.label.isEmpty {
                Text(header.label)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(secondary)
            }
            Text(header.title)
                .font(.system(size: titleSize, weight: .heavy))
                .tracking(titleSize * -0.02)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            // Left out when empty, or the stack would space around nothing.
            if !header.subtitle.isEmpty || !header.meta.isEmpty || Trailing.self != EmptyView.self {
                HStack(spacing: 12) {
                    details
                        .font(.system(size: 14))
                        .lineLimit(2)
                    trailing
                }
                .padding(.top, 2)
            }
        }
        .multilineTextAlignment(centred ? .center : .leading)
        .foregroundStyle(foreground)
    }

    @ViewBuilder private var details: some View {
        let subtitle = Text(header.subtitle).fontWeight(.bold)
        let meta = Text(header.meta).foregroundStyle(secondary)
        switch (header.subtitle.isEmpty, header.meta.isEmpty) {
        case (false, false): Text("\(subtitle)  •  \(meta)")
        case (false, true): subtitle
        case (true, false): meta
        case (true, true): EmptyView()
        }
    }

    private var titleSize: CGFloat {
        switch header.title.count {
        case ...12: 48
        case ...18: 40
        case ...28: 34
        default: 28
        }
    }
}
