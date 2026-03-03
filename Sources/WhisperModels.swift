import Foundation

struct AnonRelayEnvelope: Codable {
    let roomId: String
    let channel: String
    let type: String
    let sender: String
    let counter: Int?
    let ratchetPub: String?
    let payload: String?
    // Ratchet message-crypto wire version (v1 legacy, v2 next-gen). Optional for backward compatibility.
    let messageCryptoVersion: Int?

    init(roomId: String,
         channel: String,
         type: String,
         sender: String,
         counter: Int? = nil,
         ratchetPub: String? = nil,
         payload: String? = nil,
         messageCryptoVersion: Int? = nil) {
        self.roomId = roomId
        self.channel = channel
        self.type = type
        self.sender = sender
        self.counter = counter
        self.ratchetPub = ratchetPub
        self.payload = payload
        self.messageCryptoVersion = messageCryptoVersion
    }
}

struct AnonCallMediaFrame: Equatable {
    let roomId: String
    let callId: String
    let kind: String
    let epoch: Int?
    let data: Data
}

struct WhisperPayload: Codable {
    let kind: String
    let text: String?
    let publicKey: String?
    let identityKey: String?
    let identitySig: String?
    let mediaId: String?
    let mediaIndex: Int?
    let mediaTotal: Int?
    let mediaKind: String?
    let mediaData: String?
    let reason: String?
    let senderTag: String?
    let sessionId: String?
    let messageId: String?
    let signalPreKeyBundle: String?
    // Message-crypto negotiation fields:
    // - messageCryptoVersion: preferred/selected version
    // - messageCryptoVersions: supported versions advertised in hello
    let messageCryptoVersion: Int?
    let messageCryptoVersions: [Int]?
    let callId: String?
    let callEpoch: Int?
    let callCryptoMode: String?
    let callTransport: String?
    // Optional media transport capabilities. Unknown keys are ignored by older clients.
    // Currently used to negotiate wsBinary PCM frame coalescing (to reduce PPS).
    let callPcmBundle: Int?
    // Optional PCM lossless processing mode for call negotiation ("raw" / "echoCancelled").
    let callPcmMode: String?
    // Optional ws-binary relay pool negotiation (e.g. "v2"). Older clients ignore unknown keys.
    let callRelayPool: String?
    let pad: String?
    let ktRoot: String?
    let ktSize: Int?

    init(kind: String,
         text: String? = nil,
         publicKey: String? = nil,
         identityKey: String? = nil,
         identitySig: String? = nil,
         mediaId: String? = nil,
         mediaIndex: Int? = nil,
         mediaTotal: Int? = nil,
         mediaKind: String? = nil,
         mediaData: String? = nil,
         reason: String? = nil,
         senderTag: String? = nil,
         sessionId: String? = nil,
         messageId: String? = nil,
         signalPreKeyBundle: String? = nil,
         messageCryptoVersion: Int? = nil,
         messageCryptoVersions: [Int]? = nil,
         callId: String? = nil,
         callEpoch: Int? = nil,
         callCryptoMode: String? = nil,
         callTransport: String? = nil,
         callPcmBundle: Int? = nil,
         callPcmMode: String? = nil,
         callRelayPool: String? = nil,
         pad: String? = nil,
         ktRoot: String? = nil,
         ktSize: Int? = nil) {
        self.kind = kind
        self.text = text
        self.publicKey = publicKey
        self.identityKey = identityKey
        self.identitySig = identitySig
        self.mediaId = mediaId
        self.mediaIndex = mediaIndex
        self.mediaTotal = mediaTotal
        self.mediaKind = mediaKind
        self.mediaData = mediaData
        self.reason = reason
        self.senderTag = senderTag
        self.sessionId = sessionId
        self.messageId = messageId
        self.signalPreKeyBundle = signalPreKeyBundle
        self.messageCryptoVersion = messageCryptoVersion
        self.messageCryptoVersions = messageCryptoVersions
        self.callId = callId
        self.callEpoch = callEpoch
        self.callCryptoMode = callCryptoMode
        self.callTransport = callTransport
        self.callPcmBundle = callPcmBundle
        self.callPcmMode = callPcmMode
        self.callRelayPool = callRelayPool
        self.pad = pad
        self.ktRoot = ktRoot
        self.ktSize = ktSize
    }
}

struct WhisperMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(String)
        case image(Data)
        case voice(Data, duration: TimeInterval?)
        case system(String)
    }

    let id: UUID
    let isMine: Bool
    let kind: Kind
    let createdAt: Date
}
