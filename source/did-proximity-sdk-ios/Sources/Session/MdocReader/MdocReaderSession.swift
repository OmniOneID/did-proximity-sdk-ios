/*
 * Copyright 2026 OmniOne.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
#if canImport(MdocProximityCore)
@_exported @_spi(MdocInternal) import MdocProximityCore
@_exported @_spi(MdocInternal) import MdocTrust
@_spi(MdocInternal) import MdocNFC
#endif

public enum MdocReaderState: String {
    case idle, connecting, connected, awaitingResponse, verifying, completed, terminated, failed
}

public struct IssuerDataAuthResult {
    public let signatureValid: Bool
    public let verificationSkipped: Bool
    public let trust: TrustVerdict
    public let source: TrustSource
    public let docTypeChecked: Bool
    public let docTypeMatches: Bool
    public let validity: ValidityCheck?
}

public enum DocumentWarning: Equatable {
    case unrequestedElement(NameSpace, DataElementIdentifier)
    /// A deviceSigned element that the MSO `keyAuthorizations` does not authorize for the deviceKey (9.1.3.4).
    /// Its value has been removed from `deviceSignedElements`.
    case unauthorizedDeviceSignedElement(NameSpace, DataElementIdentifier)
}

public struct VerifiedDocument {
    public let docType: DocType

    public let issuerSignedElements: [NameSpace: [DataElementIdentifier: MdocValue]]
    public let deviceSignedElements: [NameSpace: [DataElementIdentifier: MdocValue]]
    public var allElements: [NameSpace: [DataElementIdentifier: MdocValue]] {
        var out = issuerSignedElements
        for (ns, elems) in deviceSignedElements {
            out[ns] = elems.merging(out[ns] ?? [:]) { _, issuer in issuer }
        }
        return out
    }

    public let issuerDataAuth: IssuerDataAuthResult
    public let mdocAuth: MdocAuthResult
    public let digests: DigestCheckResult?
    public let warnings: [DocumentWarning]

    public let notReturned: [NameSpace: [DataElementIdentifier]]
    public let elementErrors: [NameSpace: [DataElementIdentifier: Int64]]

    let intentToRetain: [NameSpace: [DataElementIdentifier: Bool]]
    let issuerKid: String?
    let issuerAlgorithm: Int
    let issuerAuth: CoseSign1?
    /// Whether an issuer key was available and the signature was actually checked — otherwise `signatureValid == false` means "could not check".
    let signatureChecked: Bool

    func replacingTrust(_ t: TrustVerdict, source s: TrustSource,
                        signatureValid: Bool, signatureChecked: Bool) -> VerifiedDocument {
        let a = issuerDataAuth
        return VerifiedDocument(
            docType: docType, issuerSignedElements: issuerSignedElements,
            deviceSignedElements: deviceSignedElements,
            issuerDataAuth: IssuerDataAuthResult(
                signatureValid: signatureValid, verificationSkipped: a.verificationSkipped,
                trust: t, source: s, docTypeChecked: a.docTypeChecked,
                docTypeMatches: a.docTypeMatches, validity: a.validity),
            mdocAuth: mdocAuth, digests: digests, warnings: warnings,
            notReturned: notReturned, elementErrors: elementErrors,
            intentToRetain: intentToRetain, issuerKid: issuerKid, issuerAlgorithm: issuerAlgorithm,
            issuerAuth: issuerAuth, signatureChecked: signatureChecked)
    }

    public var verdict: VerificationVerdict {
        guard issuerDataAuth.docTypeMatches, digests?.allMatch == true, mdocAuth.valid,
              issuerDataAuth.validity?.isCurrentlyValid == true else { return .invalid }
        // Not checked (skipped or no key) ≠ wrong — the best possible verdict is .unverified.
        if issuerDataAuth.verificationSkipped || !signatureChecked { return .unverified }
        guard issuerDataAuth.signatureValid else { return .invalid }
        if case .trusted = issuerDataAuth.trust { return .valid }
        return .unverified
    }

    public func provenance(_ nameSpace: NameSpace, _ id: DataElementIdentifier) -> ElementProvenance? {
        if issuerSignedElements[nameSpace]?[id] != nil { return .issuerSigned }
        if deviceSignedElements[nameSpace]?[id] != nil { return .deviceSigned }
        return nil
    }

    public var retainable: [NameSpace: [DataElementIdentifier]] {
        var out: [NameSpace: [DataElementIdentifier]] = [:]
        for (ns, elems) in intentToRetain {
            let ids = elems.filter { $0.value }.keys.sorted()
            if !ids.isEmpty { out[ns] = ids }
        }
        return out
    }

    public func retainableElements(requiringValidDigest: Bool = true)
        -> [NameSpace: [DataElementIdentifier: MdocValue]] {
        var out: [NameSpace: [DataElementIdentifier: MdocValue]] = [:]
        for (ns, elems) in allElements {
            var keep: [DataElementIdentifier: MdocValue] = [:]
            for (id, v) in elems where intentToRetain[ns]?[id] == true {
                if requiringValidDigest, digests?.matches[ns]?[id] != true { continue }
                keep[id] = v
            }
            if !keep.isEmpty { out[ns] = keep }
        }
        return out
    }
}

public struct VerifiedResponse {
    public let documents: [VerifiedDocument]
    public let documentErrors: [DocType: Int64]
    public let status: UInt64
}

public protocol MdocReaderSessionDelegate: AnyObject {
    func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState)
    func readerSessionDidConnect(_ s: MdocReaderSession)
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int)
    func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError)
}

public extension MdocReaderSessionDelegate {
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int) {}
}

public final class MdocReaderSession {

    /// Every mutable property is touched only while holding `lock` — the app's calls, the transport event
    /// pump and `terminate()` run on different threads. Recursive because session methods call each other.
    /// Never held across an `await`; callbacks are queued, never run inside it.
    private let lock = NSRecursiveLock()
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private var _state: MdocReaderState = .idle
    public private(set) var state: MdocReaderState {
        get { locked { _state } }
        set { locked { _state = newValue; notify { $0.readerSession(self, didChangeState: newValue) } } }
    }
    private weak var _delegate: MdocReaderSessionDelegate?
    public var delegate: MdocReaderSessionDelegate? {
        get { locked { _delegate } }
        set { locked { _delegate = newValue } }
    }
    public let configuration: MdocReaderConfiguration
    let factory: TransportFactoryProtocol
    private let nfcSource: NfcTagSource
    private var transport: DataRetrievalTransportProtocol?
    private var router: TransportEventRouter?
    private var pumping = false
    private var claim: SessionRegistry.Claim?
    private let trust: TrustEvaluatorProtocol
    private var cipher: SessionCipher?
    private var transcript: SessionTranscriptBytes?
    private var eReaderKeyBytes: OpaqueCBOR?
    private var ephemeral: EphemeralKeyPair?
    private var _onTransportEvent: ((TransportEvent) -> Void)?
    @_spi(MdocInternal) public var onTransportEvent: ((TransportEvent) -> Void)? {
        get { locked { _onTransportEvent } }
        set { locked { _onTransportEvent = newValue } }
    }
    private var requested = false
    private var ended = false
    private var negotiatedCentralUUID: Data?
    private var usesNfcSource = false

    /// Always queued (never run in place), so the order of callbacks follows the order of state changes
    /// made under `lock`, and app code never runs while the lock is held.
    private func notify(_ call: @escaping (MdocReaderSessionDelegate) -> Void) {
        configuration.callbackQueue.async { [weak self] in
            guard let self, let d = self.delegate else { return }
            call(d)
        }
    }

    public convenience init(configuration: MdocReaderConfiguration = MdocReaderConfiguration(),
                            trust: TrustEvaluatorProtocol) {
        self.init(configuration: configuration, trust: trust,
                  transportFactory: ReaderTransportFactory(),
                  nfcTagSource: DefaultNfcTagSource.make())
    }

    @_spi(MdocInternal)
    public init(configuration: MdocReaderConfiguration = MdocReaderConfiguration(),
                trust: TrustEvaluatorProtocol,
                transportFactory: TransportFactoryProtocol,
                nfcTagSource: NfcTagSource) {
        self.configuration = configuration
        self.factory = transportFactory
        self.nfcSource = nfcTagSource
        self.trust = trust
    }

    @_spi(MdocInternal)
    public init(configuration: MdocReaderConfiguration = MdocReaderConfiguration(),
                transport: DataRetrievalTransportProtocol,
                trust: TrustEvaluatorProtocol) {
        self.configuration = configuration
        self.factory = ReaderTransportFactory()
        self.nfcSource = UnavailableNfcTagSource()
        self.transport = transport
        self.trust = trust
    }

    public func connect(to engagement: EngagementPayload) async throws {
        try locked {
            guard _state == .idle else {
                throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "connect")
            }
            claim = try SessionRegistry.claim("MdocReaderSession")
            state = .connecting
        }
        try await establish(engagement, over: nil)
        notify { $0.readerSessionDidConnect(self) }
    }

    @discardableResult
    public func connectViaNFC() async throws -> EngagementPayload {
        try locked {
            guard _state == .idle else {
                throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "connectViaNFC")
            }
            claim = try SessionRegistry.claim("MdocReaderSession")
            state = .connecting
            usesNfcSource = true
        }
        var channel: Iso7816Channel?
        let payload: EngagementPayload
        do {
            var tag: Type4TagEngagementReader.Result
            while true {
                try ensureConnecting()
                let link = try await nfcSource.openChannel()
                channel = link
                do {
                    tag = try await Type4TagEngagementReader(channel: link).read(negotiated: { [self] _ in
                        handoverRequest()
                    })
                    break
                } catch is Type4TagEngagementReader.NotAnMdocTag {
                    link.close(); channel = nil
                    try Task.checkCancellation()
                }
            }
            var artifacts = EngagementArtifacts(handoverSelectBytes: tag.handoverSelectBytes,
                                                handoverRequestBytes: tag.handoverRequestBytes)
            artifacts.carriers = tag.handover.carriers
            artifacts.nfcMaxCommandDataLength = tag.handover.nfc?.maxCommandDataLength
            artifacts.nfcMaxResponseDataLength = tag.handover.nfc?.maxResponseDataLength
            artifacts.bleServiceUUID = tag.handover.bleServiceUUID
            payload = try EngagementPayload.make(
                tag.engagementBytes,
                technology: tag.handoverRequestBytes == nil ? .nfcStaticHandover : .nfcNegotiatedHandover,
                handover: artifacts)
        } catch {
            channel?.close()
            try locked {
                guard _state != .terminated else { throw CancellationError() }
                settleConnecting(after: error)
            }
            throw error
        }
        try await establish(payload, over: channel)
        notify { $0.readerSessionDidConnect(self) }
        return payload
    }

    private func handoverRequest() -> Data {
        let available = factory.availableTechnologies
        let uuid = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        var carriers: [HandoverSelect.Carrier] = []
        for kind in configuration.transmissionPriority {
            switch kind {
            case .ble:
                let central = available.contains(.ble(.centralClient))
                let peripheral = available.contains(.ble(.peripheralServer))
                let role: UInt8
                switch (central, peripheral) {
                case (true, true): role = configuration.blePreferredMode == .central ? 0x02 : 0x03
                case (true, false): role = 0x00
                case (false, true): role = 0x01
                case (false, false): continue
                }
                locked { negotiatedCentralUUID = central ? uuid : nil }
                carriers.append(.ble(role: role, serviceUUID: central ? uuid : nil))
            case .nfc where available.contains(.nfc):
                carriers.append(.nfcReader)
            default: continue
            }
        }
        return HandoverRequest.build(carriers: carriers, collisionResolution: UInt16.random(in: 0...UInt16.max))
    }

    /// The caller sets `state` to `connecting`. State is re-checked after every `await` — link setup must not
    /// revive a `terminate()` that arrived in between back to `connected`. Terminal states are final.
    private func establish(_ engagement: EngagementPayload, over channel: Iso7816Channel?) async throws {
        do {
            try ensureConnecting()
            let technology = try select(engagement)
            if technology != .nfc { channel?.close() }
            let transport: DataRetrievalTransportProtocol
            if let injected = locked({ self.transport }) {
                transport = injected
            } else {
                transport = try await makeTransport(technology, engagement, channel: channel)
            }
            let router = TransportEventRouter(transport)
            try locked {
                // terminate() never saw this transport — close it here instead of opening it
                guard _state == .connecting else { transport.close(.normal); throw CancellationError() }
                self.transport = transport
                self.router = router
                startPump(router)
            }
            try await transport.open(TransportConfig(role: .mdocReader))
            try ensureConnecting()
            try await Deadline.run(seconds: configuration.connectTimeout,
                                   onTimeout: .connectionFailed(detail: "connect timeout")) {
                try await router.waitReady()
            }
            try locked {
                try ensureConnecting()
                let ephemeral = EphemeralKeyPair()
                self.ephemeral = ephemeral
                let zab = try ephemeral.sharedSecret(
                    withPeerKeyBytes: engagement.deviceEngagement.eDeviceKeyBytes)
                begin(transcript: engagement.sessionTranscript(eReaderKeyBytes: ephemeral.keyBytes),
                      sharedSecret: zab, eReaderKeyBytes: ephemeral.keyBytes)
            }
        } catch {
            try locked {
                // After terminate(), that path closes the link along with the termination notice. Follow-on link errors are cancellation too
                guard _state != .terminated else { throw CancellationError() }
                if let transport {
                    transport.close(.protocolError)
                } else {
                    channel?.close()
                }
                settleConnecting(after: error)
            }
            throw error
        }
    }

    private func ensureConnecting() throws {
        try locked { guard _state == .connecting else { throw CancellationError() } }
    }

    private func settleConnecting(after error: Error) {
        locked {
            guard _state == .connecting else { return }
            state = error is CancellationError ? .terminated : .failed
            releaseClaim()
        }
    }

    private func makeTransport(_ technology: TransmissionTechnology,
                               _ engagement: EngagementPayload,
                               channel: Iso7816Channel?) async throws -> DataRetrievalTransportProtocol {
        guard technology == .nfc else {
            return try factory.makeTransport(parameters(for: technology, engagement))
        }
        let link: Iso7816Channel
        if let channel { link = channel } else {
            locked { usesNfcSource = true }
            link = try await nfcSource.openChannel()
        }
        return NfcDataRetrievalTransport(
            channel: link,
            maxCommandDataLength: Int(clamping: engagement.nfcMaxCommandDataLength ?? 255),
            maxResponseDataLength: Int(clamping: engagement.nfcMaxResponseDataLength ?? 256),
            selectsApplication: true)
    }

    private func select(_ engagement: EngagementPayload) throws -> TransmissionTechnology {
        guard let chosen = TransportSelection.select(
                advertised: engagement.transmissions,
                priority: configuration.transmissionPriority,
                blePreferredMode: configuration.blePreferredMode,
                available: factory.availableTechnologies.filter { connectable($0, engagement) }) else {
            let wanted = configuration.transmissionPriority.filter { kind in
                engagement.transmissions.contains { t in
                    switch kind {
                    case .nfc: return t == .nfc
                    case .wifiAware: return t == .wifiAware
                    case .ble: if case .ble = t { return true } else { return false }
                    }
                }
            }
            if let e = MdocCapabilities.current().mdocReader.blockingError(among: wanted) { throw e }
            throw MdocProximityError.unsupportedTransmissionTechnology
        }
        return chosen
    }

    private func connectable(_ technology: TransmissionTechnology, _ engagement: EngagementPayload) -> Bool {
        let ble = engagement.bleOptions
        let oobUUID = engagement.handover?.bleServiceUUID
        switch technology {
        case .ble(.peripheralServer): return (ble?.peripheralServerUUID ?? oobUUID) != nil
        case .ble(.centralClient):    return (ble?.centralClientUUID ?? centralUUID(engagement)) != nil
        case .nfc:                    return true
        case .wifiAware:              return true
        }
    }

    private func parameters(for technology: TransmissionTechnology,
                            _ engagement: EngagementPayload) throws -> TransportParameters {
        let ble = engagement.bleOptions
        let oobUUID = engagement.handover?.bleServiceUUID
        switch technology {
        case .ble(.peripheralServer):
            return TransportParameters(technology: technology, role: .mdocReader,
                                       l2cap: configuration.l2capUpgrade,
                                       serviceUUID: ble?.peripheralServerUUID ?? oobUUID,
                                       l2capPSM: ble?.l2capPSM)
        case .ble(.centralClient):
            return TransportParameters(
                technology: technology, role: .mdocReader, l2cap: configuration.l2capUpgrade,
                serviceUUID: ble?.centralClientUUID ?? centralUUID(engagement),
                ident: KeyDerivation.bleIdent(
                    eDeviceKeyBytes: engagement.deviceEngagement.eDeviceKeyBytes.raw))
        case .nfc:
            return TransportParameters(technology: .nfc, role: .mdocReader,
                                       maxCommandDataLength: engagement.nfcMaxCommandDataLength,
                                       maxResponseDataLength: engagement.nfcMaxResponseDataLength)
        case .wifiAware:
            return TransportParameters(technology: .wifiAware, role: .mdocReader)
        }
    }

    private func centralUUID(_ engagement: EngagementPayload) -> Data? {
        engagement.technology == .nfcNegotiatedHandover ? locked { negotiatedCentralUUID } : engagement.handover?.bleServiceUUID
    }

    public static func resolveTrust(for document: VerifiedDocument,
                                    using trust: TrustEvaluatorProtocol,
                                    at now: Date) async -> VerifiedDocument {
        // Documents marked as skipped never gain trust — they must not become .trusted without a signature check.
        guard !document.issuerDataAuth.verificationSkipped,
              case .unknown = document.issuerDataAuth.trust else { return document }
        let header = COSEHeaderSummary(kid: document.issuerKid, algorithm: document.issuerAlgorithm)
        let r = await trust.evaluate(header: header, purpose: .issuerDataAuthentication, at: now)
        // Re-check the signature with the newly resolved key (9.3.1 step 2). Documents whose key was not found the first time get their verdict here.
        var checked = false, valid = false
        if let key = r.publicKey, let auth = document.issuerAuth,
           let outcome = IssuerDataAuthVerifier.verifySignature(auth, issuerPublicKeySEC1: key) {
            checked = true
            valid = outcome
        }
        return document.replacingTrust(r.trust, source: r.source, signatureValid: valid, signatureChecked: checked)
    }

    @_spi(MdocInternal)
    public func begin(transcript: SessionTranscriptBytes, sharedSecret: Data,
                      eReaderKeyBytes: OpaqueCBOR) {
        locked {
            guard _state != .terminated else { return }
            self.transcript = transcript
            self.eReaderKeyBytes = eReaderKeyBytes
            self.cipher = SessionCipher(role: .mdocReader, sharedSecret: sharedSecret, transcript: transcript)
            if router == nil, let transport { router = TransportEventRouter(transport) }
            if let router { startPump(router) }
            state = .connected
        }
    }

    public func request(_ specs: [ItemsRequestSpec], at now: Date) async throws -> VerifiedResponse {
        let bytes = try RequestCodec.encode(DeviceRequest(docRequests: specs))
        let (cipher, transcript, eReaderKeyBytes, transport) = try locked {
            () -> (SessionCipher, SessionTranscriptBytes, OpaqueCBOR, DataRetrievalTransportProtocol) in
            guard _state == .connected, !requested,
                  let cipher, let transcript, let eReaderKeyBytes, let transport else {
                throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "request")
            }
            requested = true
            state = .awaitingResponse
            return (cipher, transcript, eReaderKeyBytes, transport)
        }
        try await orFail { try await transport.send(try SessionCodec.encodeEstablishment(
            eReaderKeyBytes: eReaderKeyBytes, data: try cipher.encrypt(bytes))) }

        let raw: Data
        do {
            raw = try await Deadline.run(seconds: configuration.responseTimeout,
                                         onTimeout: .responseTimeout) { [self] in
                guard let m = await nextMessage() else { throw MdocProximityError.peerDisconnected }
                return m
            }
        } catch {
            try locked {
                try ensureNotTerminated()
                advance(.failed)
            }
            throw error
        }
        try ensureNotTerminated()

        let envelope = try await orFail { try SessionCodec.decodeData(raw) }
        guard let payload = envelope.data else {
            locked {
                ended = true
                transport.close(.remote)
                router?.stop()
                discardKeys()
                advance(.failed)
            }
            throw MdocProximityError.terminatedByPeer(status: envelope.status ?? 20)
        }
        locked { ended = true }
        try? await transport.send(SessionCodec.encodeData(SessionData.terminate))
        transport.close(.normal)
        locked {
            router?.stop()
            advance(.verifying)
        }
        let response = try await orFail { try ResponseCodec.decode(try cipher.decrypt(payload)) }
        let verified = await verify(response, specs: specs, transcript: transcript, at: now)
        // Never hand over results of a transaction the app has ended (8.3.2.1.2.1 — retain nothing beyond what the transaction needs)
        try locked {
            try ensureNotTerminated()
            advance(.completed)
        }
        return verified
    }

    private func orFail<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch {
            try locked {
                try ensureNotTerminated()
                advance(.failed)
            }
            throw error
        }
    }

    /// After `terminate()`, throws `CancellationError` instead of follow-on link errors or verification results
    private func ensureNotTerminated() throws {
        try locked { guard _state != .terminated else { throw CancellationError() } }
    }

    private func advance(_ next: MdocReaderState) {
        locked {
            guard _state != .terminated else { return }
            state = next
        }
    }

    private func releaseClaim() {
        locked {
            if let claim { SessionRegistry.release(claim) }
            claim = nil
        }
    }

    public func terminate() {
        lock.lock(); defer { lock.unlock() }
        switch _state {
        case .terminated: transport?.close(.normal)
        case .completed, .failed:
            if !ended, cipher != nil, let transport {
                ended = true
                let bye = SessionCodec.encodeData(SessionData.terminate)
                Task { try? await transport.send(bye); transport.close(.normal) }
            } else {
                transport?.close(.normal)
            }
        default:
            let bye = SessionCodec.encodeData(SessionData.terminate)
            if let transport {
                Task { try? await transport.send(bye); transport.close(.normal) }
            } else if usesNfcSource {
                // NFC-source path only: on the QR path the source would keep a cancellation mark and the next connectViaNFC() would end at once
                nfcSource.cancel()
            }
            state = .terminated
        }
        router?.stop()
        discardKeys()
        releaseClaim()
    }

    private func discardKeys() {
        locked {
            cipher = nil
            ephemeral = nil
        }
    }

    // MARK: -

    private func startPump(_ router: TransportEventRouter) {
        guard !pumping else { return }
        pumping = true
        router.onEvent = { [weak self] event in
            guard let self else { return }
            onTransportEvent?(event)
            self.locked {
                switch event {
                case .progress(let n, let total):
                    self.notify { $0.readerSession(self, didProgress: n, of: total) }
                case .peerClosed:
                    self.ended = true
                    if self._state == .connected { self.fail(.peerDisconnected) }
                case .failed(let e) where self._state == .connected:
                    self.fail(e)
                default: break
                }
            }
        }
        router.start()
    }

    private func fail(_ e: MdocProximityError) {
        locked {
            state = .failed
            notify { $0.readerSession(self, didFailWith: e) }
        }
    }

    private func nextMessage() async -> Data? {
        await locked({ router })?.nextMessage()
    }

    private func eMacKey(for deviceKeySEC1: Data?, transcript: SessionTranscriptBytes) -> Data? {
        guard let deviceKeySEC1, let ephemeral = locked({ ephemeral }),
              let zabPrime = try? ephemeral.sharedSecret(withPeerX963: deviceKeySEC1) else {
            return nil
        }
        return KeyDerivation.eMacKey(zabPrime: zabPrime, transcript: transcript)
    }

    private func verify(_ response: DeviceResponse,
                        specs: [ItemsRequestSpec],
                        transcript: SessionTranscriptBytes,
                        at now: Date) async -> VerifiedResponse {
        var docs: [VerifiedDocument] = []
        for doc in response.documents {
            let issuerAuth = doc.issuerSigned.issuerAuth
            let header = COSEHeaderSummary(kid: issuerAuth.keyIdentifier, algorithm: issuerAuth.algorithm ?? -7)
            let resolution: IssuerKeyResolution = configuration.skipIssuerAuth
                ? .notResolved
                : await trust.evaluate(header: header, purpose: .issuerDataAuthentication, at: now)
            let check = IssuerDataAuthVerifier.verifyCryptographic(
                doc.issuerSigned, docType: doc.docType,
                issuerPublicKeySEC1: resolution.publicKey, at: now,
                skippingSignature: configuration.skipIssuerAuth)
            let mdocAuth = MdocAuthVerifier.verify(
                doc.deviceSigned.deviceAuth, transcript: transcript, docType: doc.docType,
                deviceNameSpacesBytes: doc.deviceSigned.nameSpacesBytes,
                deviceKeySEC1: check.deviceKeySEC1,
                eMacKey: eMacKey(for: check.deviceKeySEC1, transcript: transcript))

            var issuerElements: [NameSpace: [DataElementIdentifier: MdocValue]] = [:]
            for (ns, items) in doc.issuerSigned.nameSpaces {
                issuerElements[ns] = Dictionary(
                    items.map { ($0.elementIdentifier, MdocValue($0.elementValue)) },
                    uniquingKeysWith: { first, _ in first })
            }
            let (deviceElements, unauthorized) = Self.authorized(
                Self.deviceSignedElements(doc.deviceSigned.nameSpacesBytes), by: check.keyAuthorizations)

            let spec = specs.first { $0.docType == doc.docType }
            var notReturned: [NameSpace: [DataElementIdentifier]] = [:]
            for (ns, requestedItems) in spec?.items ?? [:] {
                let got = Set(issuerElements[ns]?.keys.map { $0 } ?? [])
                    .union(deviceElements[ns]?.keys.map { $0 } ?? [])
                let missing = requestedItems.keys.filter { !got.contains($0) }
                if !missing.isEmpty { notReturned[ns] = missing.sorted() }
            }

            docs.append(VerifiedDocument(
                docType: doc.docType,
                issuerSignedElements: issuerElements, deviceSignedElements: deviceElements,
                issuerDataAuth: IssuerDataAuthResult(
                    signatureValid: check.signatureValid,
                    verificationSkipped: check.verificationSkipped,
                    trust: resolution.trust, source: resolution.source,
                    docTypeChecked: check.docTypeChecked,
                    docTypeMatches: check.docTypeMatches, validity: check.validity),
                mdocAuth: mdocAuth, digests: check.digests,
                warnings: Self.warnings(issuer: issuerElements, device: deviceElements,
                                        requested: spec?.items ?? [:]) + unauthorized,
                notReturned: notReturned, elementErrors: doc.errors,
                intentToRetain: spec?.items ?? [:],
                issuerKid: header.kid, issuerAlgorithm: header.algorithm,
                issuerAuth: issuerAuth, signatureChecked: check.signatureChecked))
        }
        return VerifiedResponse(documents: docs, documentErrors: response.documentErrors,
                                status: response.status)
    }

    private static func deviceSignedElements(_ bytes: OpaqueCBOR)
        -> [NameSpace: [DataElementIdentifier: MdocValue]] {
        guard let outer = try? CborDecoder.decode(bytes.raw),
              case .tagged(24, .bytes(let inner)) = outer,
              let spaces = try? CborDecoder.decode(inner), case .map(let nsPairs) = spaces else {
            return [:]
        }
        var out: [NameSpace: [DataElementIdentifier: MdocValue]] = [:]
        for p in nsPairs {
            guard let ns = p.key.asText, case .map(let items) = p.value else { continue }
            var m: [DataElementIdentifier: MdocValue] = [:]
            for item in items { if let id = item.key.asText { m[id] = MdocValue(item.value) } }
            out[ns] = m
        }
        return out
    }

    /// 9.1.3.4 — deviceSigned elements not authorized for the deviceKey are removed from the values and kept as warnings.
    /// If the MSO could not be read (`nil`), nothing is authorized.
    private static func authorized(_ elements: [NameSpace: [DataElementIdentifier: MdocValue]],
                                   by auth: KeyAuthorizations?)
        -> ([NameSpace: [DataElementIdentifier: MdocValue]], [DocumentWarning]) {
        var kept: [NameSpace: [DataElementIdentifier: MdocValue]] = [:]
        var dropped: [DocumentWarning] = []
        for ns in elements.keys.sorted() {
            for (id, v) in elements[ns]!.sorted(by: { $0.key < $1.key }) {
                if auth?.allows(ns, id) == true { kept[ns, default: [:]][id] = v }
                else { dropped.append(.unauthorizedDeviceSignedElement(ns, id)) }
            }
        }
        return (kept, dropped)
    }

    private static func warnings(issuer: [NameSpace: [DataElementIdentifier: MdocValue]],
                                 device: [NameSpace: [DataElementIdentifier: MdocValue]],
                                 requested: [NameSpace: [DataElementIdentifier: Bool]]) -> [DocumentWarning] {
        var out: [DocumentWarning] = []
        let spaces = Set(issuer.keys).union(device.keys).sorted()
        for ns in spaces {
            let issuerIDs = issuer[ns]?.keys.sorted() ?? []
            let deviceIDs = device[ns]?.keys.sorted() ?? []
            let asked = requested[ns] ?? [:]
            for id in Set(issuerIDs).union(deviceIDs).sorted() where asked[id] == nil {
                out.append(.unrequestedElement(ns, id))
            }
        }
        return out
    }
}

