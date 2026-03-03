import Foundation

enum KSMPCallKind: String, Codable {
    case voice = "VOICE"
    case video = "VIDEO"
}

struct KSMPCallE2EAcceptEvent: Codable, Hashable {
    let callId: String
    let calleePubKey: String
}

struct KSMPCallEndEvent: Codable, Hashable {
    let callId: String
    let by: Int?
    let reason: String?
}

struct KSMPCallBillingSponsorRequestEvent: Codable, Hashable {
    let callId: String
    let from: Int?
    let to: Int?
}

struct KSMPCallBillingSponsorResponseEvent: Codable, Hashable {
    let callId: String
    let from: Int?
    let to: Int?
    let accept: Bool
}

struct KSMPCallPayload: Codable, Hashable {
    let callId: String
    let groupId: Int
    let kind: KSMPCallKind
    let roomId: String
    let roomSecret: String
    let e2eVersion: Int?
    let callerPubKey: String?
    let expiresAt: Date?
    let callerId: Int?
    let calleeId: Int?

    init(callId: String,
         groupId: Int,
         kind: KSMPCallKind,
         roomId: String,
         roomSecret: String,
         e2eVersion: Int? = nil,
         callerPubKey: String? = nil,
         expiresAt: Date?,
         callerId: Int?,
         calleeId: Int?) {
        self.callId = callId
        self.groupId = groupId
        self.kind = kind
        self.roomId = roomId
        self.roomSecret = roomSecret
        self.e2eVersion = e2eVersion
        self.callerPubKey = callerPubKey
        self.expiresAt = expiresAt
        self.callerId = callerId
        self.calleeId = calleeId
    }

    private enum CodingKeys: String, CodingKey {
        case callId
        case groupId
        case kind
        case roomId
        case roomSecret
        case e2eVersion
        case callerPubKey
        case expiresAt
        case callerId
        case calleeId
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let callId = try container.decodeIfPresent(String.self, forKey: .callId) ??
            container.decodeIfPresent(String.self, forKey: .id) {
            self.callId = callId
        } else {
            throw DecodingError.keyNotFound(CodingKeys.callId,
                                            .init(codingPath: decoder.codingPath,
                                                  debugDescription: "Missing callId"))
        }

        guard let groupId = Self.decodeInt(from: container, forKey: .groupId) else {
            throw DecodingError.keyNotFound(CodingKeys.groupId,
                                            .init(codingPath: decoder.codingPath,
                                                  debugDescription: "Missing groupId"))
        }
        self.groupId = groupId
        let rawKind = (try? container.decode(String.self, forKey: .kind)) ?? ""
        if let kind = KSMPCallKind(rawValue: rawKind.uppercased()) {
            self.kind = kind
        } else {
            throw DecodingError.dataCorruptedError(forKey: .kind,
                                                   in: container,
                                                   debugDescription: "Invalid call kind")
        }

        guard let roomId = try? container.decode(String.self, forKey: .roomId), !roomId.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.roomId,
                                            .init(codingPath: decoder.codingPath,
                                                  debugDescription: "Missing roomId"))
        }
        self.roomId = roomId

        let e2eVersion = Self.decodeInt(from: container, forKey: .e2eVersion)
        self.e2eVersion = e2eVersion
        self.callerPubKey = (try? container.decodeIfPresent(String.self, forKey: .callerPubKey)) ?? nil

        // Legacy calls: roomSecret must be present and non-empty.
        // E2E-DH calls: roomSecret is derived client-side, so backend may omit it.
        if let secret = try? container.decodeIfPresent(String.self, forKey: .roomSecret), !secret.isEmpty {
            self.roomSecret = secret
        } else if (e2eVersion ?? 0) > 0 {
            self.roomSecret = ""
        } else {
            throw DecodingError.keyNotFound(CodingKeys.roomSecret,
                                            .init(codingPath: decoder.codingPath,
                                                  debugDescription: "Missing roomSecret"))
        }
        self.expiresAt = Self.decodeDate(from: container, forKey: .expiresAt)
        self.callerId = Self.decodeInt(from: container, forKey: .callerId)
        self.calleeId = Self.decodeInt(from: container, forKey: .calleeId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callId, forKey: .callId)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(kind, forKey: .kind)
        try container.encode(roomId, forKey: .roomId)
        if !roomSecret.isEmpty {
            try container.encode(roomSecret, forKey: .roomSecret)
        }
        try container.encodeIfPresent(e2eVersion, forKey: .e2eVersion)
        try container.encodeIfPresent(callerPubKey, forKey: .callerPubKey)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(callerId, forKey: .callerId)
        try container.encodeIfPresent(calleeId, forKey: .calleeId)
    }

    private static func decodeInt(from container: KeyedDecodingContainer<CodingKeys>,
                                  forKey key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key),
           let value = Int(string) {
            return value
        }
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(doubleValue)
        }
        return nil
    }

    private static func decodeDate(from container: KeyedDecodingContainer<CodingKeys>,
                                   forKey key: CodingKeys) -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
            return date
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key),
           let date = string.asISODate {
            return date
        }
        if let timestamp = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let timestamp = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        return nil
    }
}

struct KSMPCallSession: Identifiable, Equatable {
    let id: String
    let groupId: Int
    let kind: KSMPCallKind
    let roomId: String
    let roomSecret: String
    let e2eVersion: Int?
    let peerPubKey: String?
    let isIncoming: Bool
    let callerId: Int?
    let expiresAt: Date?

    init(id: String,
         groupId: Int,
         kind: KSMPCallKind,
         roomId: String,
         roomSecret: String,
         e2eVersion: Int? = nil,
         peerPubKey: String? = nil,
         isIncoming: Bool,
         callerId: Int?,
         expiresAt: Date?) {
        self.id = id
        self.groupId = groupId
        self.kind = kind
        self.roomId = roomId
        self.roomSecret = roomSecret
        self.e2eVersion = e2eVersion
        self.peerPubKey = peerPubKey
        self.isIncoming = isIncoming
        self.callerId = callerId
        self.expiresAt = expiresAt
    }

    init(payload: KSMPCallPayload, isIncoming: Bool) {
        self.id = payload.callId
        self.groupId = payload.groupId
        self.kind = payload.kind
        self.roomId = payload.roomId
        self.roomSecret = payload.roomSecret
        self.e2eVersion = payload.e2eVersion
        self.peerPubKey = isIncoming ? payload.callerPubKey : nil
        self.isIncoming = isIncoming
        self.callerId = payload.callerId
        self.expiresAt = payload.expiresAt
    }

    var callId: String { id }

    var isReady: Bool {
        !roomId.isEmpty && !roomSecret.isEmpty
    }
}
