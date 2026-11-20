import SwiftUI
import SwiftData

@main
struct HeimAudioApp: App {
    // Storage for saved links and the list of computers
    let container: ModelContainer

    init() {
        do {
            // Own file name "HeimAudio.store": the old "default.store" stays untouched.
            container = try ModelContainer(
                for: Computer.self, SavedLink.self,
                configurations: ModelConfiguration("HeimAudio")
            )
        } catch {
            fatalError("Speicher konnte nicht geöffnet werden: \(error)")
        }
        // Before the first screen, so the list of computers is correct right away
        LegacyStoreMigration.run(into: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
