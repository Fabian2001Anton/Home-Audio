import SwiftUI
import SwiftData

struct ContentView: View {
    // The registered computers and which one is currently controlled
    @Query(sort: \Computer.createdAt) private var computers: [Computer]
    @AppStorage("activeComputer") private var activeComputerID = ""
    @AppStorage("audioQuality") private var audioQuality: AudioReceiver.Quality = .automatic

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    // Saved links, oldest first
    @Query(sort: \SavedLink.createdAt) private var links: [SavedLink]
    @State private var linkHint: String?
    @State private var openedCount = 0

    @State private var status: ComputerStatus?
    @State private var message: String?
    @State private var isLoading = false
    @State private var volume = 50.0
    @State private var webAddress = ""
    @State private var audio = AudioReceiver()
    @State private var showsSettings = false

    private var activeComputer: Computer? {
        computers.first { $0.uuid.uuidString == activeComputerID } ?? computers.first
    }

    private var api: ComputerAPI? {
        activeComputer?.api
    }

    private var isConnected: Bool {
        status != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                volumeSection
                playbackSection
                webPageSection
                SavedLinksSection(links: links, open: open, copyToField: { webAddress = $0 })
                Section {
                    NavigationLink {
                        TabsView(api: api)
                    } label: {
                        Label("Offene Tabs am Rechner", systemImage: "rectangle.stack")
                    }
                }
                .disabled(!isConnected)
                liveAudioSection
            }
            .navigationTitle("HeimAudio")
            // Short vibration when the computer has opened a page
            .sensoryFeedback(.success, trigger: openedCount)
            .onChange(of: webAddress) {
                linkHint = nil
            }
            // Quality changed while the audio is playing: reconnect with the new quality.
            .onChange(of: audioQuality) {
                if audio.isActive, let api {
                    audio.start(with: api, computerName: activeComputer?.name, quality: audioQuality)
                }
            }
            // After deleting a link, an old hint no longer fits.
            .onChange(of: links.count) { before, now in
                if now < before {
                    linkHint = nil
                }
            }
            // Another computer selected: stop the audio and reconnect.
            .onChange(of: activeComputerID) {
                audio.stop()
                status = nil
                message = nil
                Task { await refresh() }
            }
            .toolbar {
                Button("Einstellungen", systemImage: "gearshape") {
                    showsSettings = true
                }
            }
            .sheet(isPresented: $showsSettings, onDismiss: {
                checkSelection()
                Task { await refresh() }
            }) {
                SettingsView()
            }
            .refreshable {
                await refresh()
            }
            .task {
                checkSelection()
                if api == nil {
                    showsSettings = true
                } else {
                    await refresh()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await refresh() }
                }
            }
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            if computers.count > 1 {
                Picker("Rechner", selection: $activeComputerID) {
                    ForEach(computers) { computer in
                        Text(computer.name.isEmpty ? "Ohne Namen" : computer.name)
                            .tag(computer.uuid.uuidString)
                    }
                }
            }

            if let status {
                Label {
                    VStack(alignment: .leading) {
                        Text(status.computer)
                        Text("Verbunden · \(status.system)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.green)
                }
            } else if isLoading {
                HStack {
                    ProgressView()
                    Text("Verbinde …")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Nicht verbunden", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var volumeSection: some View {
        Section("Lautstärke") {
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                // Only send when released, not on every small movement.
                Slider(value: $volume, in: 0...100, step: 1, onEditingChanged: { isDragging in
                    if !isDragging {
                        let value = Int(volume)
                        Task { await perform { try await $0.setVolume(value) } }
                    }
                })
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
            .disabled(status?.volume == nil)

            Toggle("Stumm", isOn: mutedBinding)
        }
        .disabled(!isConnected)
    }

    private var playbackSection: some View {
        Section {
            HStack {
                mediaKeyButton("Zurück", symbol: "backward.fill", key: .previous)
                mediaKeyButton("Abspielen oder Pause", symbol: "playpause.fill", key: .play)
                mediaKeyButton("Weiter", symbol: "forward.fill", key: .next)
            }
            .font(.title)
            .padding(.vertical, 6)
        } header: {
            Text("Wiedergabe")
        } footer: {
            Text("Wirkt wie die Medientasten der Rechner-Tastatur, z. B. auf ein YouTube-Video im Browser.")
        }
        .disabled(!isConnected)
    }

    private var webPageSection: some View {
        Section {
            TextField("https://www.youtube.com/watch?v=…", text: $webAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(openWebPage)

            HStack {
                PasteButton(payloadType: String.self) { texts in
                    DispatchQueue.main.async {
                        webAddress = texts.first ?? ""
                    }
                }
                .labelStyle(.titleAndIcon)

                Spacer()

                Button("Merken", systemImage: "bookmark", action: saveLink)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .disabled(targetURL == nil)

                Button("Öffnen", systemImage: "arrow.up.forward.app", action: openWebPage)
                    .buttonStyle(.borderedProminent)
                    .disabled(targetURL == nil || !isConnected)
            }

            if let linkHint {
                Text(linkHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Webseite am Rechner öffnen")
        } footer: {
            Text("Öffnet die Adresse im Browser des Rechners. Mit dem Lesezeichen speicherst du sie. Den Ton hörst du über „Live-Ton“.")
        }
    }

    private var liveAudioSection: some View {
        Section {
            Button {
                if audio.isActive {
                    audio.stop()
                } else if let api {
                    audio.start(with: api, computerName: activeComputer?.name, quality: audioQuality)
                }
            } label: {
                Label(
                    audio.isActive ? "Live-Ton beenden" : "Live-Ton starten",
                    systemImage: audio.isActive ? "stop.circle.fill" : "headphones"
                )
            }

            switch audio.state {
            case .off:
                EmptyView()
            case .connecting:
                HStack {
                    ProgressView()
                    Text("Verbinde …")
                        .foregroundStyle(.secondary)
                }
            case .playing where audio.isPaused:
                // Nothing audible on the computer: the output waits until sound comes again.
                Label("Pausiert · am Rechner ist nichts zu hören", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            case .playing:
                Label(audio.isEconomical ? "Ton läuft · sparsam" : "Ton läuft · beste Qualität", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.green)
            case .failed(let text):
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Picker("Qualität", selection: $audioQuality) {
                ForEach(AudioReceiver.Quality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
        } header: {
            Text("Live-Ton")
        } footer: {
            Text("Spielt auf dem iPhone ab, was der Rechner gerade abspielt – auch bei gesperrtem Bildschirm. Beste Qualität: ca. 700 MB pro Stunde. Sparsam: ca. 45 MB pro Stunde. Automatisch: im WLAN beste Qualität, über Mobilfunk sparsam.")
        }
        .disabled(!isConnected && !audio.isActive)
    }

    // A button for one media key.
    private func mediaKeyButton(_ title: String, symbol: String, key: MediaKey) -> some View {
        Button(title, systemImage: symbol) {
            Task { await perform { try await $0.press(key) } }
        }
        .labelStyle(.iconOnly)
        // Without this line, all buttons in a form row fire at once.
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    // The saved selection matches no computer (e.g. deleted): take the first one.
    private func checkSelection() {
        if let activeComputer, activeComputer.uuid.uuidString != activeComputerID {
            activeComputerID = activeComputer.uuid.uuidString
        }
    }

    private var mutedBinding: Binding<Bool> {
        Binding(
            get: { status?.muted ?? false },
            set: { newValue in Task { await perform { try await $0.setMuted(newValue) } } }
        )
    }

    // Turns the input into a web address and adds https:// if needed.
    private var targetURL: URL? {
        var text = webAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowercased = text.lowercased()
        if !lowercased.hasPrefix("http://") && !lowercased.hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    private func openWebPage() {
        guard let url = targetURL else { return }
        open(url)
    }

    private func open(_ url: URL) {
        Task {
            if await perform({ try await $0.open(url) }) {
                openedCount += 1
            }
        }
    }

    // Saves the address from the input field. The app then loads the proper name from the internet.
    private func saveLink() {
        guard let url = targetURL else { return }
        guard !links.contains(where: { $0.url == url.absoluteString }) else {
            linkHint = "Diesen Link hast du schon gespeichert."
            return
        }
        let link = SavedLink(title: LinkTitle.provisional(for: url), url: url.absoluteString)
        modelContext.insert(link)
        linkHint = "Gespeichert."
        Task {
            if let title = await LinkTitle.load(for: url) {
                link.title = title
            }
        }
    }

    private func refresh() async {
        isLoading = true
        let succeeded = await perform { try await $0.status() }
        if !succeeded {
            status = nil
        }
        isLoading = false
    }

    // Runs a command and takes over the state the computer reports back.
    @discardableResult
    private func perform(_ command: (ComputerAPI) async throws -> ComputerStatus) async -> Bool {
        guard let api else {
            status = nil
            message = "Bitte zuerst in den Einstellungen einen Rechner mit Adresse und Schlüssel eintragen."
            return false
        }
        do {
            let newStatus = try await command(api)
            status = newStatus
            message = nil
            if let value = newStatus.volume {
                volume = Double(value)
            }
            return true
        } catch {
            message = errorText(for: error, api: api)
            return false
        }
    }

    // Turns network errors into a hint about what to check (German, shown to the user).
    private func errorText(for error: Error, api: ComputerAPI) -> String {
        guard let networkError = error as? URLError else {
            return error.localizedDescription
        }
        switch networkError.code {
        case .cannotConnectToHost, .timedOut, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            let target = "\(api.baseURL.host() ?? "?"):\(api.baseURL.port.map(String.init) ?? "?")"
            return "Keine Verbindung zu \(target). Läuft der Dienst auf dem Rechner? Stimmen Adresse und Port? Bist du im Heimnetz oder ist das VPN an?"
        default:
            return networkError.localizedDescription
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [SavedLink.self, Computer.self], inMemory: true)
}
