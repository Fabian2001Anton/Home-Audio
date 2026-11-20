import SwiftUI
import SwiftData

// The saved links. Tapping one opens it on the computer.
struct SavedLinksSection: View {
    let links: [SavedLink]
    let open: (URL) -> Void
    let copyToField: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var linkToRename: SavedLink?
    @State private var newTitle = ""

    var body: some View {
        Section {
            if links.isEmpty {
                Text("Noch keine Links. Gib oben eine Adresse ein und tippe auf das Lesezeichen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(links) { link in
                Button {
                    if let url = URL(string: link.url) {
                        open(url)
                    }
                } label: {
                    // Color.primary instead of .primary: inside a button, .primary would be the blue accent color.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.title)
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                        Text(link.displayAddress)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }
                .contextMenu {
                    Button("Umbenennen", systemImage: "pencil") {
                        newTitle = link.title
                        linkToRename = link
                    }
                    Button("Ins Adressfeld übernehmen", systemImage: "square.and.pencil") {
                        copyToField(link.url)
                    }
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        modelContext.delete(link)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    modelContext.delete(links[index])
                }
            }
        } header: {
            Text("Gespeicherte Links")
        } footer: {
            if !links.isEmpty {
                Text("Antippen öffnet den Link am Rechner. Gedrückt halten zum Umbenennen, nach links wischen zum Löschen.")
            }
        }
        .alert("Link umbenennen", isPresented: isRenaming, presenting: linkToRename) { link in
            TextField("Name", text: $newTitle)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    link.title = title
                }
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { linkToRename != nil },
            set: { if !$0 { linkToRename = nil } }
        )
    }
}
