import CryptoKit
import Foundation

/// Stable identity of one battery: a device's Keychain UUID (ADR-0007) or an
/// accessory component's UUIDv5 (ADR-0005). Also its CloudKit record name.
public struct DeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The wrapped UUID.
    public let uuid: UUID

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    /// Parses a CloudKit record name. Accepts upper or lower case (SYNC-002 R1).
    public init?(recordName: String) {
        guard let uuid = UUID(uuidString: recordName) else { return nil }
        self.uuid = uuid
    }

    /// The CloudKit record name: the lowercase `uuidString` (SYNC-002 R1).
    public var recordName: String { uuid.uuidString.lowercased() }

    public var description: String { recordName }

    /// Fixed forever (SYNC-002 R2). Changing it would duplicate every accessory record.
    public static let accessoryNamespace = UUID(uuidString: "3F6A1C52-8E0B-4D8F-9B67-2C4E1A7D90B3")!

    /// The ID of one accessory component: UUIDv5 of
    /// `"accessory:<key>:<component>"` in ``accessoryNamespace`` (SYNC-002 R2).
    /// `key` is used exactly as given (MAC-003 supplies the uppercase Bluetooth address).
    public static func accessory(key: String, component: AccessoryComponent) -> DeviceID {
        DeviceID(UUID.v5(namespace: accessoryNamespace, name: "accessory:\(key):\(component.rawValue)"))
    }

    /// The `accessoryGroupId` shared by every component of one accessory (MAC-003 R3a):
    /// UUIDv5 of `"accessory-group:<key>"` in ``accessoryNamespace``. One-way, like
    /// ``accessory(key:component:)``, so the raw key is never stored.
    public static func accessoryGroup(key: String) -> UUID {
        UUID.v5(namespace: accessoryNamespace, name: "accessory-group:\(key)")
    }

    // Encoded as its record name, so it reads well in snapshot.json.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = DeviceID(recordName: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a UUID: \(string)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(recordName)
    }
}

/// Lets `[DeviceID: T]` encode as a JSON object keyed by record name.
extension DeviceID: CodingKeyRepresentable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public var codingKey: any CodingKey { Key(stringValue: recordName) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(recordName: codingKey.stringValue)
    }
}

extension UUID {
    /// RFC 9562 §5.5 name-based UUID (SHA-1). Foundation has no initializer for it.
    static func v5(namespace: UUID, name: String) -> UUID {
        var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        data.append(Data(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 9562 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
