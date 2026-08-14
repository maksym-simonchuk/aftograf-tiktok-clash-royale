import SwiftUI

@main
struct CRCutApp: App {
    @State private var store = QueueStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                QueueView(store: store)
            }
            .preferredColorScheme(.dark)
            .tint(Color.crGold)
        }
    }
}
