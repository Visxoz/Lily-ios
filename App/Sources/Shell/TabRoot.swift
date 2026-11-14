import SwiftUI
import YTMCore

/// One tab: its own stack of pages, with the account button that opens
/// Settings, as ytm-native's top bar has, and the toast above the mini
/// player while no sheet covers it (sheets show it too).
struct TabRoot<Content: View>: View {
    let tab: AppTab
    let content: Content

    @Environment(AppModel.self) private var app

    init(tab: AppTab, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.content = content()
    }

    var body: some View {
        @Bindable var navigation = app.navigation(for: tab)
        NavigationStack(path: $navigation.routes) {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AccountButton() }
                }
                .navigationDestination(for: Route.self) { PageScreen(route: $0) }
        }
        .overlay(alignment: .bottom) { ToastView() }
    }
}
