import SwiftUI

@main
struct MHTMLSaverApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 320)
        }
        .windowResizability(.contentSize)
    }
}
