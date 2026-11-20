import SwiftUI
import SwiftData

// List of computers: add, edit, delete.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Computer.createdAt) private var computers: [Computer]
    @AppStorage("activeComputer") private var activeComputerID = ""

    @State private var newComputer: Computer?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(computers) { computer in
                        NavigationLink {
                            ComputerEditor(computer: computer)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(computer.name.isEmpty ? "Ohne Namen" : computer.name)
                                Text(computer.address.isEmpty ? "Adresse fehlt" : "\(computer.address):\(String(computer.port))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            modelContext.delete(computers[index])
                        }
                    }

                    Button("Rechner hinzufügen", systemImage: "plus", action: addComputer)
                } header: {
                    Text("Rechner")
                } footer: {
                    Text("Adresse, Port und Schlüssel zeigt der HeimAudio-Dienst an. Mac: ~/Library/Logs/heimaudio.log, Linux: journalctl --user -u heimaudio")
                }

                Section("Unterwegs") {
                    Label("Vorher in der WireGuard-App das VPN zur FRITZ!Box einschalten.", systemImage: "lock.shield")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $newComputer) { computer in
                ComputerEditor(computer: computer)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func addComputer() {
        let computer = Computer(name: computers.isEmpty ? "Mac" : "Rechner \(computers.count + 1)")
        modelContext.insert(computer)
        if computers.isEmpty {
            activeComputerID = computer.uuid.uuidString
        }
        newComputer = computer
    }
}

// Edit the connection details of a computer. Changes are saved immediately.
struct ComputerEditor: View {
    @Bindable var computer: Computer

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("z. B. Arch", text: $computer.name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Adresse") {
                    TextField("192.168.178.24", text: $computer.address)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Port") {
                    TextField("8765", value: $computer.port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                LabeledContent("Schlüssel") {
                    SecureField("aus dem Dienst", text: $computer.key)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text("Tipp: Den Schlüssel auf dem Mac kopieren und hier einfügen.")
            }
        }
        .navigationTitle(computer.name.isEmpty ? "Rechner" : computer.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: Computer.self, inMemory: true)
}
