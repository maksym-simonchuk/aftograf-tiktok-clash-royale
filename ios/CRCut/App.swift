import SwiftUI

@main
struct CRCutApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ImportView()
            }
            .preferredColorScheme(.dark)
            .tint(Color.crGold)
        }
    }
}
