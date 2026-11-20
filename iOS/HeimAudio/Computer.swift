import Foundation
import SwiftData

// A computer the app can control, e.g. the Mac or the Arch machine.
@Model
final class Computer {
    var uuid: UUID
    var name: String
    var address: String
    var port: Int
    var key: String
    var createdAt: Date

    init(uuid: UUID = UUID(), name: String, address: String = "", port: Int = 8765, key: String = "", createdAt: Date = .now) {
        self.uuid = uuid
        self.name = name
        self.address = address
        self.port = port
        self.key = key
        self.createdAt = createdAt
    }

    // nil as long as the address or key is missing.
    var api: ComputerAPI? {
        ComputerAPI(address: address, port: port, key: key)
    }
}
