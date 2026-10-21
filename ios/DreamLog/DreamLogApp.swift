import SwiftUI

@main
struct DreamLogApp: App {
    @State private var model = AppModel()
    init() { applyHeaderStyle() }
    var body: some Scene { WindowGroup { RootView().environment(model) } }
}
