import SwiftUI

// Shows the open browser tabs on the computer. A tab can be closed with the cross or by swiping.
struct TabsView: View {
    let api: ComputerAPI?

    @State private var tabs: [BrowserTab] = []
    @State private var message: String?
    @State private var hasLoaded = false

    // One group per browser window, in the order from the computer.
    private struct TabGroup: Identifiable {
        let id: String
        var tabs: [BrowserTab]
    }

    private var windowGroups: [TabGroup] {
        var groups: [TabGroup] = []
        for tab in tabs {
            let name = "\(tab.browser) · Fenster \(tab.window)"
            if let index = groups.firstIndex(where: { $0.id == name }) {
                groups[index].tabs.append(tab)
            } else {
                groups.append(TabGroup(id: name, tabs: [tab]))
            }
        }
        return groups
    }

    var body: some View {
        List {
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            ForEach(windowGroups) { group in
                Section(group.id) {
                    ForEach(group.tabs) { tab in
                        row(tab)
                    }
                }
            }
        }
        .overlay {
            if !hasLoaded {
                ProgressView("Lade Tabs …")
            } else if tabs.isEmpty && message == nil {
                ContentUnavailableView(
                    "Keine offenen Tabs",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("In Brave oder Chrome ist am Rechner gerade kein Tab offen.")
                )
            }
        }
        .navigationTitle("Offene Tabs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Aktualisieren", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
        }
        .refreshable {
            await load()
        }
        .task {
            await load()
        }
    }

    private func row(_ tab: BrowserTab) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .lineLimit(2)
                Text(shortForm(tab.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if tab.active {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Sichtbarer Tab")
            }

            Button("Schließen", systemImage: "xmark.circle.fill") {
                close(tab)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title2)
            .foregroundStyle(.secondary)
        }
        .swipeActions {
            Button("Schließen", systemImage: "xmark", role: .destructive) {
                close(tab)
            }
        }
    }

    // Address without https:// and www.
    private func shortForm(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }

    private func load() async {
        defer { hasLoaded = true }
        guard let api else {
            message = "Bitte zuerst in den Einstellungen Adresse und Schlüssel eintragen."
            return
        }
        do {
            tabs = try await api.tabs()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func close(_ tab: BrowserTab) {
        guard let api else { return }
        // Hide it right away; the list from the computer follows shortly.
        withAnimation {
            tabs.removeAll { $0.id == tab.id }
        }
        Task {
            do {
                let updatedTabs = try await api.closeTab(tab)
                withAnimation {
                    tabs = updatedTabs
                }
                message = nil
            } catch {
                message = error.localizedDescription
                await load()
            }
        }
    }
}
