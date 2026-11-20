import Foundation
import SwiftData

// Earlier versions of the app used German names for their stored data and settings.
// This file copies that data once into the current models (Computer, SavedLink).

// MARK: - Stored data of earlier versions

// The class and property names must stay exactly as they are (German):
// SwiftData finds the old data by these names.

@Model
final class Rechner {
    var kennung: UUID
    var name: String
    var adresse: String
    var port: Int
    var schluessel: String
    var erstelltAm: Date

    init(kennung: UUID, name: String, adresse: String, port: Int, schluessel: String, erstelltAm: Date) {
        self.kennung = kennung
        self.name = name
        self.adresse = adresse
        self.port = port
        self.schluessel = schluessel
        self.erstelltAm = erstelltAm
    }
}

@Model
final class GespeicherterLink {
    var titel: String
    var url: String
    var erstelltAm: Date

    init(titel: String, url: String, erstelltAm: Date) {
        self.titel = titel
        self.url = url
        self.erstelltAm = erstelltAm
    }
}

// MARK: - Migration

enum LegacyStoreMigration {
    private static let doneKey = "legacyStoreMigrated"

    @MainActor
    static func run(into context: ModelContext) {
        let defaults = UserDefaults.standard
        migrateSettings(defaults)
        guard !defaults.bool(forKey: doneKey) else { return }
        if migrateStore(into: context) {
            defaults.set(true, forKey: doneKey)
        }
    }

    // Settings: same values, new keys.
    private static func migrateSettings(_ defaults: UserDefaults) {
        if let activeComputer = defaults.string(forKey: "aktiverRechner") {
            if defaults.object(forKey: "activeComputer") == nil {
                defaults.set(activeComputer, forKey: "activeComputer")
            }
            defaults.removeObject(forKey: "aktiverRechner")
        }
        if let quality = defaults.string(forKey: "tonqualitaet") {
            let newValues = ["automatisch": "automatic", "beste": "best", "sparsam": "economical"]
            if defaults.object(forKey: "audioQuality") == nil, let newValue = newValues[quality] {
                defaults.set(newValue, forKey: "audioQuality")
            }
            defaults.removeObject(forKey: "tonqualitaet")
        }
    }

    // Returns true when there is nothing (more) to do.
    @MainActor
    private static func migrateStore(into context: ModelContext) -> Bool {
        let fileManager = FileManager.default
        let folder = URL.applicationSupportDirectory
        let oldStoreName = "default.store"
        guard fileManager.fileExists(atPath: folder.appending(path: oldStoreName).path(percentEncoded: false)) else {
            return true
        }
        let computerCount = (try? context.fetchCount(FetchDescriptor<Computer>())) ?? 0
        let linkCount = (try? context.fetchCount(FetchDescriptor<SavedLink>())) ?? 0
        guard computerCount == 0 && linkCount == 0 else { return true }

        // Work on a copy: the old store stays untouched no matter what happens.
        let copyFolder = fileManager.temporaryDirectory.appending(path: "legacy-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: copyFolder) }
        do {
            try fileManager.createDirectory(at: copyFolder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = folder.appending(path: oldStoreName + suffix)
                if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                    try fileManager.copyItem(at: source, to: copyFolder.appending(path: oldStoreName + suffix))
                }
            }
            let oldContainer = try ModelContainer(
                for: Rechner.self, GespeicherterLink.self,
                configurations: ModelConfiguration(url: copyFolder.appending(path: oldStoreName))
            )
            let oldContext = ModelContext(oldContainer)
            for old in try oldContext.fetch(FetchDescriptor<Rechner>()) {
                context.insert(Computer(
                    uuid: old.kennung, name: old.name, address: old.adresse,
                    port: old.port, key: old.schluessel, createdAt: old.erstelltAm
                ))
            }
            for old in try oldContext.fetch(FetchDescriptor<GespeicherterLink>()) {
                context.insert(SavedLink(title: old.titel, url: old.url, createdAt: old.erstelltAm))
            }
            try context.save()
            return true
        } catch {
            // Try again at the next start. The old data is still there.
            print("Old data could not be migrated: \(error)")
            return false
        }
    }
}
