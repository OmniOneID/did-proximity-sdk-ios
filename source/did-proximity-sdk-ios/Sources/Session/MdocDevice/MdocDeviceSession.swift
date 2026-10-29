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
@_spi(MdocInternal) import MdocNFC
#endif

public enum MdocDeviceState: String {
    case idle, engaging, sessionEstablished, awaitingResponse, responding, completed, terminated, failed
}

public protocol MdocDeviceSessionDelegate: AnyObject {
    func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState)
    func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                     sessionTranscript: Data)
    func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int)
    func mdocSessionDidFinish(_ s: MdocDeviceSession)
    func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError)
}

public extension MdocDeviceSessionDelegate {
    func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int) {}
}

public final class MdocDeviceSession {

    /// Every mutable property is touched only while holding `lock` — the app's calls, the transport event
    /// pump and the deadline tasks run on different threads. Recursive because session methods call each
    /// other (`receive` → `terminate`). Never held across an `await`; callbacks are queued, never run inside it.
    private let lock = NSRecursiveLock()
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private var _state: MdocDeviceState = .idle
    public private(set) var state: MdocDeviceState {
        get { locked { _state } }
        set { locked { _state = newValue; notify { $0.mdocSession(self, didChangeState: newValue) } } }
    }
    private weak var _delegate: MdocDeviceSessionDelegate?
    public var delegate: MdocDeviceSessionDelegate? {
        get { locked { _delegate } }
        set { locked { _delegate = newValue } }
    }

    let factory: TransportFactoryProtocol
    private var transport: DataRetrievalTransportProtocol?
    private var router: TransportEventRouter?
    private var cipher: SessionCipher?
    private var transcript: SessionTranscriptBytes?
    private var responded = false
    private var ended = false
    private var deadline: Task<Void, Never>?
    private var pumping = false
    private var claim: SessionRegistry.Claim?
    private var _onTransportEvent: ((TransportEvent) -> Void)?
    private var _onCandidateEvent: ((String, TransportEvent) -> Void)?
    @_spi(MdocInternal) public var onTransportEvent: ((TransportEvent) -> Void)? {
        get { locked { _onTransportEvent } }
        set { locked { _onTransportEvent = newValue } }
    }
    @_spi(MdocInternal) public var onCandidateEvent: ((String, TransportEvent) -> Void)? {
        get { locked { _onCandidateEvent } }
        set { locked { _onCandidateEvent = newValue } }
    }

    private var ephemeral: EphemeralKeyPair?
    private var engagement: EngagementPayload?

    public let configuration: MdocDeviceConfiguration
    private let nfcCardEmulation: NfcCardEmulationProtocol?

    /// Always queued (never run in place), so the order of callbacks follows the order of state changes
    /// made under `lock`, and app code never runs while the lock is held.
    private func notify(_ call: @escaping (MdocDeviceSessionDelegate) -> Void) {
        configuration.callbackQueue.async { [weak self] in
            guard let self, let d = self.delegate else { return }
            call(d)
        }
    }

    public convenience init(configuration: MdocDeviceConfiguration = MdocDeviceConfiguration(),
                            nfcCardEmulation: NfcCardEmulationProtocol? = nil) {
        self.init(configuration: configuration,
                  transportFactory: DeviceTransportFactory(),
                  nfcCardEmulation: nfcCardEmulation)
    }

    @_spi(MdocInternal)
    public init(configuration: MdocDeviceConfiguration = MdocDeviceConfiguration(),
                transportFactory: TransportFactoryProtocol,
                nfcCardEmulation: NfcCardEmulationProtocol? = nil) {
        self.configuration = configuration
        self.factory = transportFactory
        self.nfcCardEmulation = nfcCardEmulation
    }

    @_spi(MdocInternal)
    public init(configuration: MdocDeviceConfiguration = MdocDeviceConfiguration(),
                transport: DataRetrievalTransportProtocol) {
        self.configuration = configuration
        self.factory = DeviceTransportFactory()
        self.transport = transport
        self.nfcCardEmulation = nil
    }

    @discardableResult
    public func start(technology: EngagementTechnology) async throws -> EngagementPayload {
        let injected: DataRetrievalTransportProtocol? = try locked {
            guard _state == .idle else {
                throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "start")
            }
            if technology.isNFC, nfcCardEmulation == nil {
                throw MdocProximityError.nfcUnavailable(reason: .vendorPolicy)
            }
            claim = try SessionRegistry.claim("MdocDeviceSession")
            return transport
        }
        if technology.isNFC, let emulation = nfcCardEmulation {
            return technology == .nfcNegotiatedHandover
                ? try await startNfcNegotiated(emulation, injected: injected)
                : try await startNfc(emulation, injected: injected)
        }
        do {
            let keys = EphemeralKeyPair()
            let serviceUUID = withUnsafeBytes(of: UUID().uuid) { Data($0) }
            let centralUUID = withUnsafeBytes(of: UUID().uuid) { Data($0) }
            var advertised = factory.availableTechnologies.filter(configuration.bleAdvertiseMode.allows)
            if nfcCardEmulation != nil { advertised.append(.nfc) }
            guard !advertised.isEmpty else {
                if let e = MdocCapabilities.current().mdoc.blockingError(among: [.ble]) { throw e }
                throw MdocProximityError.unsupportedTransmissionTechnology
            }
            let nfc = NfcCarrierConfiguration(maxCommandDataLength: 255, maxResponseDataLength: 256)
            let bytes = try EngagementCodec.encode(
                eDeviceKeyBytes: keys.keyBytes,
                retrievalMethods: Self.retrievalMethods(advertised, serviceUUID: serviceUUID,
                                                        centralUUID: centralUUID, nfc: nfc))
            let payload = try EngagementPayload.make(bytes, technology: technology)

            let ident = KeyDerivation.bleIdent(eDeviceKeyBytes: keys.keyBytes.raw)
            let transport: DataRetrievalTransportProtocol
            if let injected {
                transport = injected
            } else {
                let fanout = FirstReadyTransport(try advertised.map { technology -> (String, DataRetrievalTransportProtocol) in
                    if technology == .nfc, let emulation = nfcCardEmulation {
                        return ("nfc", NfcCardTransport(
                            emulation: emulation, handoverSelect: Data(),
                            maxCommandDataLength: Int(nfc.maxCommandDataLength),
                            maxResponseDataLength: Int(nfc.maxResponseDataLength)))
                    }
                    return ("\(technology)", try factory.makeTransport(TransportParameters(
                        technology: technology, role: .mdoc,
                        l2cap: configuration.l2capUpgrade,
                        serviceUUID: technology == .ble(.centralClient) ? centralUUID : serviceUUID,
                        ident: ident)))
                })
                fanout.onCandidateEvent = { [weak self] in self?.onCandidateEvent?($0, $1) }
                transport = fanout
            }
            install(transport, keys: keys, engagement: payload)
            try await openAndEngage(transport)
            return payload
        } catch {
            settleStart()
            throw error
        }
    }

    private func install(_ transport: DataRetrievalTransportProtocol, keys: EphemeralKeyPair,
                         engagement payload: EngagementPayload) {
        locked {
            let router = TransportEventRouter(transport)
            self.ephemeral = keys
            self.engagement = payload
            self.transport = transport
            self.router = router
            startPump(router)
        }
    }

    private func openAndEngage(_ transport: DataRetrievalTransportProtocol) async throws {
        try await transport.open(TransportConfig(role: .mdoc))
        try locked {
            guard _state == .idle else { throw CancellationError() }
            state = .engaging
            armEngagementDeadline()
        }
    }

    private func settleStart() {
        locked {
            if _state == .idle { state = .failed }
            releaseClaim()
        }
    }

    private func releaseClaim() {
        locked {
            if let claim { SessionRegistry.release(claim) }
            claim = nil
        }
    }

    private func startNfc(_ emulation: NfcCardEmulationProtocol,
                          injected: DataRetrievalTransportProtocol?) async throws -> EngagementPayload {
        do {
            let keys = EphemeralKeyPair()
            let bytes = try EngagementCodec.encode(eDeviceKeyBytes: keys.keyBytes, retrievalMethods: [])
            let nfc = NfcCarrierConfiguration(maxCommandDataLength: 255, maxResponseDataLength: 256)
            let handoverSelect = HandoverSelect.build(deviceEngagement: bytes, nfc: nfc)
            var artifacts = EngagementArtifacts(handoverSelectBytes: handoverSelect, handoverRequestBytes: nil)
            artifacts.carriers = [.nfc]
            artifacts.nfcMaxCommandDataLength = nfc.maxCommandDataLength
            artifacts.nfcMaxResponseDataLength = nfc.maxResponseDataLength
            let payload = try EngagementPayload.make(bytes, technology: .nfcStaticHandover, handover: artifacts)

            let transport: DataRetrievalTransportProtocol = injected ?? NfcCardTransport(
                emulation: emulation, handoverSelect: handoverSelect,
                maxCommandDataLength: Int(nfc.maxCommandDataLength),
                maxResponseDataLength: Int(nfc.maxResponseDataLength))
            install(transport, keys: keys, engagement: payload)
            try await openAndEngage(transport)
            return payload
        } catch {
            settleStart()
            throw error
        }
    }

    private func startNfcNegotiated(_ emulation: NfcCardEmulationProtocol,
                                    injected: DataRetrievalTransportProtocol?) async throws -> EngagementPayload {
        do {
            let keys = EphemeralKeyPair()
            let bytes = try EngagementCodec.encode(eDeviceKeyBytes: keys.keyBytes, retrievalMethods: [])
            let nfc = NfcCarrierConfiguration(maxCommandDataLength: 255, maxResponseDataLength: 256)
            let sp = Tnep.ServiceParameter(serviceName: Ndef.handoverServiceName, waitTimeCode: 24,
                                           maxWaitExtensions: 15, maxMessageSize: 1024)
            var artifacts = EngagementArtifacts(handoverSelectBytes: nil, handoverRequestBytes: nil)
            artifacts.nfcMaxCommandDataLength = nfc.maxCommandDataLength
            artifacts.nfcMaxResponseDataLength = nfc.maxResponseDataLength
            let payload = try EngagementPayload.make(bytes, technology: .nfcNegotiatedHandover, handover: artifacts)

            let transport: DataRetrievalTransportProtocol
            if let injected {
                transport = injected
            } else {
                let fanout = FirstReadyTransport([(String, DataRetrievalTransportProtocol)]())
                fanout.onCandidateEvent = { [weak self] in self?.onCandidateEvent?($0, $1) }
                let card = NfcCardTransport(
                    emulation: emulation, handoverSelect: Data(),
                    maxCommandDataLength: Int(nfc.maxCommandDataLength),
                    maxResponseDataLength: Int(nfc.maxResponseDataLength),
                    mode: .negotiated(sp) { [weak self, weak fanout] request in
                        guard let self, let fanout else { return nil }
                        return self.answerHandoverRequest(request, deviceEngagement: bytes, keys: keys,
                                                          nfc: nfc, fanout: fanout)
                    })
                try await fanout.add("nfc", card)
                transport = fanout
            }
            install(transport, keys: keys, engagement: payload)
            try await openAndEngage(transport)
            return payload
        } catch {
            settleStart()
            throw error
        }
    }

    private func answerHandoverRequest(_ request: Data, deviceEngagement: Data, keys: EphemeralKeyPair,
                                       nfc: NfcCarrierConfiguration, fanout: FirstReadyTransport) -> Data? {
        guard let records = try? Ndef.parse(request) else { return nil }
        let offer = HandoverRequest.parse(records)
        var mine = factory.availableTechnologies.filter(configuration.bleAdvertiseMode.allows)
        mine.append(.nfc)
        guard let chosen = offer.carriers.first(where: { mine.contains($0) }) else { return nil }

        let ident = KeyDerivation.bleIdent(eDeviceKeyBytes: keys.keyBytes.raw)
        let carrier: HandoverSelect.Carrier
        var ble: TransportParameters?
        switch chosen {
        case .nfc:
            carrier = .nfc(nfc)
        case .ble(.peripheralServer):
            let uuid = withUnsafeBytes(of: UUID().uuid) { Data($0) }
            carrier = .ble(role: 0x00, serviceUUID: uuid)
            ble = TransportParameters(technology: .ble(.peripheralServer), role: .mdoc,
                                      l2cap: configuration.l2capUpgrade, serviceUUID: uuid, ident: ident)
        case .ble(.centralClient):
            guard let readerUUID = offer.readerServiceUUID else { return nil }
            carrier = .ble(role: 0x01, serviceUUID: nil)
            ble = TransportParameters(technology: .ble(.centralClient), role: .mdoc,
                                      l2cap: configuration.l2capUpgrade, serviceUUID: readerUUID, ident: ident)
        case .wifiAware:
            return nil
        }
        let select = HandoverSelect.build(deviceEngagement: deviceEngagement, carrier: carrier)
        var artifacts = EngagementArtifacts(handoverSelectBytes: select, handoverRequestBytes: request)
        artifacts.carriers = [chosen]
        artifacts.nfcMaxCommandDataLength = nfc.maxCommandDataLength
        artifacts.nfcMaxResponseDataLength = nfc.maxResponseDataLength
        guard let payload = try? EngagementPayload.make(deviceEngagement, technology: .nfcNegotiatedHandover,
                                                        handover: artifacts) else { return nil }
        var bleTransport: DataRetrievalTransportProtocol?
        if let ble {
            guard let made = try? factory.makeTransport(ble) else { return nil }
            bleTransport = made
        }
        locked { engagement = payload }
        if let bleTransport {
            let label = "\(chosen)"
            Task { try? await fanout.add(label, bleTransport) }
        }
        return select
    }

    private static func retrievalMethods(_ technologies: [TransmissionTechnology],
                                         serviceUUID: Data,
                                         centralUUID: Data,
                                         nfc: NfcCarrierConfiguration) -> [DeviceRetrievalMethod] {
        var methods: [DeviceRetrievalMethod] = []
        if technologies.contains(.nfc) {
            methods.append(DeviceRetrievalMethod(type: 1, version: 1, options: .map([
                CborPair(.unsigned(0), .unsigned(nfc.maxCommandDataLength)),
                CborPair(.unsigned(1), .unsigned(nfc.maxResponseDataLength))])))
        }
        let peripheral = technologies.contains(.ble(.peripheralServer))
        let central = technologies.contains(.ble(.centralClient))
        if peripheral || central {
            var options: [CborPair] = [
                CborPair(.unsigned(0), .bool(peripheral)),
                CborPair(.unsigned(1), .bool(central))
            ]
            if peripheral { options.append(CborPair(.unsigned(10), .bytes(serviceUUID))) }
            if central { options.append(CborPair(.unsigned(11), .bytes(centralUUID))) }
            methods.append(DeviceRetrievalMethod(type: 2, version: 1, options: .map(options)))
        }
        return methods
    }

    private func armResponseDeadline() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.configuration.responseTimeout ?? 60)
                                                      * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Claim the response slot so a respond() racing the timeout is refused instead of overtaken
            let expired = self.locked { () -> Bool in
                guard self._state == .awaitingResponse, !self.responded else { return false }
                self.responded = true
                return true
            }
            guard expired else { return }
            try? await sendTermination()
            fail(.responseTimeout)
        }
    }

    private func armEngagementDeadline() {
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.configuration.engagementTimeout ?? 90)
                                                      * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.locked { if self._state == .engaging { self.fail(.engagementTimeout) } }
        }
    }

    @_spi(MdocInternal)
    public func begin(transcript: SessionTranscriptBytes, sharedSecret: Data) {
        locked {
            self.transcript = transcript
            self.cipher = SessionCipher(role: .mdoc, sharedSecret: sharedSecret, transcript: transcript)
            state = .sessionEstablished
            if router == nil, let transport { router = TransportEventRouter(transport) }
            if let router { startPump(router) }
        }
    }

    private func startPump(_ router: TransportEventRouter) {
        guard !pumping else { return }
        pumping = true
        router.onEvent = { [weak self] event in
            guard let self else { return }
            onTransportEvent?(event)
            self.locked {
                switch event {
                case .peerClosed:
                    self.ended = true
                    if !self.isTerminal { self.state = .terminated }
                case .failed(let e): self.fail(e)
                case .progress(let sent, let total):
                    self.notify { $0.mdocSession(self, didProgress: sent, of: total) }
                default: break
                }
            }
        }
        router.start()
        Task { [weak self] in
            while let raw = await router.nextMessage() {
                guard let self else { return }
                do { try receive(raw) }
                catch let e as MdocProximityError { fail(e) }
                catch { fail(.decodeFailed(detail: "\(error)")) }
            }
        }
    }

    private func establish(eReaderKeyBytes: OpaqueCBOR) throws {
        guard let ephemeral, let engagement else {
            throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "establish")
        }
        deadline?.cancel()
        let zab = try ephemeral.sharedSecret(withPeerKeyBytes: eReaderKeyBytes)
        let t = engagement.sessionTranscript(eReaderKeyBytes: eReaderKeyBytes)
        transcript = t
        cipher = SessionCipher(role: .mdoc, sharedSecret: zab, transcript: t)
        state = .sessionEstablished
    }

    private var isTerminal: Bool {
        locked { _state == .completed || _state == .terminated || _state == .failed }
    }

    private func fail(_ e: MdocProximityError) {
        locked {
            guard !isTerminal else { return }
            state = .failed
            notify { $0.mdocSession(self, didFailWith: e) }
        }
    }

    @_spi(MdocInternal)
    public func receive(_ encrypted: Data) throws {
        try locked {
            if let envelope = try? SessionCodec.decodeData(encrypted),
               envelope.data == nil, let status = envelope.status {
                ended = true
                deadline?.cancel()
                transport?.close(.remote)
                discardKeys()
                guard status == 20 else { throw MdocProximityError.terminatedByPeer(status: status) }
                if !isTerminal { state = .terminated }
                return
            }
            guard _state == .engaging || _state == .sessionEstablished else {
                terminate()
                throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "receive")
            }
            let payload: Data
            if let est = try? SessionCodec.decodeEstablishment(encrypted) {
                if cipher == nil { try establish(eReaderKeyBytes: est.eReaderKeyBytes) }
                payload = est.data
            } else {
                let envelope = try SessionCodec.decodeData(encrypted)
                guard let d = envelope.data else {
                    throw MdocProximityError.decodeFailed(detail: "SessionData: empty envelope")
                }
                payload = d
            }
            guard let cipher, let transcript else {
                throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "receive")
            }
            let plain = try cipher.decrypt(payload)
            state = .awaitingResponse
            armResponseDeadline()
            let raw = transcript.raw
            notify { $0.mdocSession(self, didReceiveRequest: plain, sessionTranscript: raw) }
        }
    }

    public func respond(deviceResponse: Data) async throws {
        let (cipher, transport) = try locked { () -> (SessionCipher, DataRetrievalTransportProtocol?) in
            guard _state == .awaitingResponse, !responded, let cipher else {
                throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "respond")
            }
            responded = true
            deadline?.cancel()
            state = .responding
            return (cipher, self.transport)
        }
        do {
            guard let transport else {
                throw MdocProximityError.invalidState(current: state.rawValue, attempted: "respond")
            }
            try await transport.send(SessionCodec.encodeData(
                SessionData(data: try cipher.encrypt(deviceResponse))))
        } catch {
            try locked {
                guard _state != .terminated else { throw CancellationError() }
                if _state == .responding { state = .failed }
            }
            throw error
        }
        // terminate() during the send — `terminated` stays, as on the reader side
        try locked {
            guard _state == .responding else { throw CancellationError() }
            state = .completed
            notify { $0.mdocSessionDidFinish(self) }
        }
    }

    public func reject() async throws {
        try locked {
            guard _state == .awaitingResponse, !responded else {
                throw MdocProximityError.invalidState(current: _state.rawValue, attempted: "reject")
            }
            responded = true
            deadline?.cancel()
        }
        do { try await sendTermination() } catch {
            locked { if _state == .awaitingResponse { state = .failed } }
            throw error
        }
        locked {
            state = .terminated
            notify { $0.mdocSessionDidFinish(self) }
        }
    }

    public func terminate() {
        locked {
            let transport = self.transport
            switch _state {
            case .terminated:
                transport?.close(.normal)
            case .completed, .failed:
                if !ended, cipher != nil {
                    Task { try? await sendTermination(); transport?.close(.normal) }
                } else {
                    transport?.close(.normal)
                }
            default:
                Task { try? await sendTermination(); transport?.close(.normal) }
                state = .terminated
            }
            deadline?.cancel()
            router?.stop()
            discardKeys()
            releaseClaim()
        }
    }

    private func sendTermination() async throws {
        let transport = locked { () -> DataRetrievalTransportProtocol? in
            guard let transport else { return nil }
            ended = true
            return transport
        }
        guard let transport else { return }
        try await transport.send(SessionCodec.encodeData(SessionData.terminate))
    }

    private func discardKeys() {
        locked {
            cipher = nil
            ephemeral = nil
        }
    }
}
