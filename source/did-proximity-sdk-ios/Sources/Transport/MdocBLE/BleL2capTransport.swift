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
import CoreBluetooth
#if canImport(MdocProximityCore)
@_spi(MdocInternal) import MdocProximityCore
#endif

final class L2capChannelPipe: NSObject, StreamDelegate {

    private let channel: CBL2CAPChannel?
    private let input: InputStream
    private let output: OutputStream
    private let reassembler = L2capFraming.Reassembler()
    private var outbox = Data()
    private var readBuffer = [UInt8](repeating: 0, count: 4096)
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    private var closed = false
    private var inputEnded = false   // touched only by the stream delegate (main)

    var onMessage: ((Data) -> Void)?
    var onError: ((MdocProximityError) -> Void)?
    var onClosed: (() -> Void)?

    convenience init(channel: CBL2CAPChannel) {
        self.init(channel: channel, input: channel.inputStream, output: channel.outputStream)
    }

    init(channel: CBL2CAPChannel?, input: InputStream, output: OutputStream) {
        self.channel = channel
        self.input = input
        self.output = output
        super.init()
        for stream in [input as Stream, output as Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
    }

    func send(_ message: Data) {
        let frame = L2capFraming.frame(message)
        lock.lock(); outbox.append(frame); lock.unlock()
        drain()
    }

    var hasPendingOutput: Bool { lock.lock(); defer { lock.unlock() }; return !outbox.isEmpty }

    func waitUntilDrained(limit: TimeInterval) async {
        guard hasPendingOutput, limit > 0 else { return }
        let deadline = Task { try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000)) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if outbox.isEmpty { lock.unlock(); c.resume(); return }
            drainWaiters.append(c)
            lock.unlock()
            Task { [weak self] in
                await deadline.value
                self?.resumeDrainWaiters()
            }
        }
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        outbox.removeAll()
        lock.unlock()
        let streams = [input as Stream, output as Stream]
        // Only the stream delegate (main) touches the reassembly buffer — clearing it from a close on another thread would race with `read()`.
        let release = { [reassembler] in
            for stream in streams {
                stream.delegate = nil
                stream.close()
                stream.remove(from: .main, forMode: .default)
            }
            reassembler.discard()
        }
        if Thread.isMainThread { release() } else { DispatchQueue.main.async(execute: release) }
        resumeDrainWaiters()
    }

    private func resumeDrainWaiters() {
        lock.lock(); let w = drainWaiters; drainWaiters.removeAll(); lock.unlock()
        w.forEach { $0.resume() }
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable where stream === input: read()
        case .hasSpaceAvailable where stream === output: drain()
        case .errorOccurred:
            reassembler.discard()
            let which = stream === input ? "input" : "output"
            let detail = stream.streamError.map { "\($0)" } ?? "unknown"
            onError?(.connectionFailed(detail: "L2CAP \(which) stream: \(detail)"))
        // Only the input stream's end closes the link — the output stream also reports one when the peer
        // closes, and acting on it would discard a message still being received. Handled once: a read
        // at the end re-posts the end event, so reading on every end would loop.
        case .endEncountered where stream === input && !inputEnded:
            inputEnded = true
            read()                  // bytes still buffered ahead of the end
            reassembler.discard()
            onClosed?()
        default: break
        }
    }

    private func read() {
        while input.hasBytesAvailable {
            let n = input.read(&readBuffer, maxLength: readBuffer.count)
            guard n > 0 else { break }
            do {
                for message in try reassembler.append(Data(readBuffer[0..<n])) { onMessage?(message) }
            } catch {
                onError?(error as? MdocProximityError ?? .decodeFailed(detail: "L2CAP reassembly"))
                return
            }
        }
    }

    private func drain() {
        lock.lock()
        if closed { lock.unlock(); return }
        while !outbox.isEmpty, output.hasSpaceAvailable {
            let written = outbox.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base, maxLength: outbox.count)
            }
            guard written > 0 else { break }
            outbox.removeSubrange(0..<written)
        }
        let drained = outbox.isEmpty
        lock.unlock()
        if drained { resumeDrainWaiters() }
    }
}

@_spi(MdocInternal) public class BleL2capTransportBase: NSObject, DataRetrievalTransportProtocol {

    public let events: AsyncStream<TransportEvent>
    let emit: AsyncStream<TransportEvent>.Continuation
    let profile: BleServiceProfile
    private let makeFallback: () -> DataRetrievalTransportProtocol

    var pipe: L2capChannelPipe?
    private var carriedMessage = false
    private var fallback: DataRetrievalTransportProtocol?
    var hasDowngraded: Bool { fallback != nil }
    private var fallbackPump: Task<Void, Never>?
    private var fallbackReady = false
    private var fallbackWaiters: [CheckedContinuation<Void, Never>] = []
    private let fallbackLock = NSLock()
    private var closing = false
    private let closeLock = NSLock()
    var isClosing: Bool { closeLock.lock(); defer { closeLock.unlock() }; return closing }
    private var config: TransportConfig?

    init(profile: BleServiceProfile, fallback: @escaping () -> DataRetrievalTransportProtocol) {
        self.profile = profile
        self.makeFallback = fallback
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
        super.init()
    }

    public func open(_ config: TransportConfig) async throws {
        self.config = config
    }

    public func send(_ message: Data) async throws {
        if let fallback {
            await waitForFallback()
            return try await fallback.send(message)
        }
        guard let pipe else { throw MdocProximityError.peerDisconnected }
        pipe.send(message)
        carriedMessage = true
        emit.yield(.progress(sent: message.count, total: message.count))
    }

    let drainLimit: TimeInterval = 3.0

    public func close(_ reason: TransportCloseReason) {
        closeLock.lock()
        if closing { closeLock.unlock(); return }
        closing = true
        closeLock.unlock()
        fallback?.close(reason)
        fallbackPump?.cancel()
        guard let pipe else { tearDownLink(); emit.finish(); return }
        Task { [self] in
            await pipe.waitUntilDrained(limit: drainLimit)
            try? await Task.sleep(nanoseconds: 100_000_000)
            pipe.close()
            self.pipe = nil
            tearDownLink()
            emit.finish()
        }
    }

    func tearDownLink() {}

    func attach(_ channel: CBL2CAPChannel) {
        let pipe = L2capChannelPipe(channel: channel)
        pipe.onMessage = { [weak self] in
            self?.carriedMessage = true
            self?.emit.yield(.message($0))
        }
        pipe.onError = { [weak self] error in
            guard let self, !isClosing else { return }
            guard carriedMessage else {
                self.pipe?.close(); self.pipe = nil
                return downgrade(reason: "\(error)")
            }
            emit.yield(.failed(error))
        }
        pipe.onClosed = { [weak self] in self?.emit.yield(.peerClosed(.remote)) }
        self.pipe = pipe
        emit.yield(.ready)
    }

    private func markFallbackReady() {
        fallbackLock.lock()
        guard !fallbackReady else { fallbackLock.unlock(); return }
        fallbackReady = true
        let waiters = fallbackWaiters; fallbackWaiters.removeAll()
        fallbackLock.unlock()
        for w in waiters { w.resume() }
    }

    private func waitForFallback() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            fallbackLock.lock()
            if fallbackReady { fallbackLock.unlock(); c.resume(); return }
            fallbackWaiters.append(c)
            fallbackLock.unlock()
        }
    }

    func downgrade(reason: String) {
        guard fallback == nil, !isClosing, let config else { return }
        let transport = makeFallback()
        fallback = transport
        emit.yield(.downgradedToGatt(reason: reason))
        fallbackPump = Task { [weak self] in
            for await event in transport.events {
                if case .ready = event { self?.markFallbackReady() }
                self?.emit.yield(event)
            }
        }
        Task { try? await transport.open(config) }
    }
}

@_spi(MdocInternal) public final class BleL2capOpeningTransport: BleL2capTransportBase {

    private let announcedPSM: UInt64?
    private let expectedIdent: Data?
    private var central: CBCentralManager?
    private var peer: CBPeripheral?

    public init(profile: BleServiceProfile, psm: UInt64? = nil, expectedIdent: Data? = nil,
                fallback: @escaping () -> DataRetrievalTransportProtocol) {
        self.announcedPSM = psm
        self.expectedIdent = expectedIdent
        super.init(profile: profile, fallback: fallback)
    }

    public override func open(_ config: TransportConfig) async throws {
        try await super.open(config)
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    public override func close(_ reason: TransportCloseReason) {
        central?.stopScan()
        super.close(reason)
    }

    override func tearDownLink() {
        if let peer { central?.cancelPeripheralConnection(peer) }
    }
}

extension BleL2capOpeningTransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn: manager.scanForPeripherals(withServices: [profile.serviceUUID])
        case .poweredOff: emit.yield(.failed(.configurationRequired(action: .enableBluetooth)))
        case .unauthorized: emit.yield(.failed(.configurationRequired(action: .grantPermission("bluetooth"))))
        case .unsupported: emit.yield(.failed(.bleUnavailable(reason: .noHardware)))
        default: break
        }
    }

    public func centralManager(_ manager: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        manager.stopScan()
        peer = p
        p.delegate = self
        manager.connect(p)
    }

    public func centralManager(_ manager: CBCentralManager, didConnect p: CBPeripheral) {
        if let psm = announcedPSM, expectedIdent == nil {
            openChannel(p, psm: psm)
        } else {
            p.discoverServices([profile.serviceUUID])
        }
    }

    public func centralManager(_ manager: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        emit.yield(.failed(.connectionFailed(detail: "connect: \(error.map { "\($0)" } ?? "unknown")")))
    }

    public func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                               error: Error?) {
        guard p === peer, !hasDowngraded else { return }
        emit.yield(.peerClosed(.remote))
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == profile.serviceUUID }) else {
            return downgrade(reason: "service not found")
        }
        var wanted = [profile.l2cap]
        if let ident = profile.ident { wanted.append(ident) }
        p.discoverCharacteristics(wanted, for: service)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let identChar = service.characteristics?.first(where: { $0.uuid == profile.ident }),
           expectedIdent != nil {
            p.readValue(for: identChar)
            return
        }
        proceedToChannel(p, service)
    }

    private func proceedToChannel(_ p: CBPeripheral, _ service: CBService) {
        if let psm = announcedPSM { return openChannel(p, psm: psm) }
        guard let psmChar = service.characteristics?.first(where: { $0.uuid == profile.l2cap }) else {
            return downgrade(reason: "no L2CAP characteristic")
        }
        p.readValue(for: psmChar)
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.uuid == profile.ident {
            guard let expected = expectedIdent, c.value == expected else {
                central?.cancelPeripheralConnection(p)
                peer = nil
                central?.scanForPeripherals(withServices: [profile.serviceUUID])
                return
            }
            if let service = c.service { proceedToChannel(p, service) }
            return
        }
        guard c.uuid == profile.l2cap else { return }
        guard let value = c.value, let psm = L2capPsmCodec.decode(value) else {
            return downgrade(reason: "bad PSM value")
        }
        p.openL2CAPChannel(psm)
    }

    private func openChannel(_ p: CBPeripheral, psm: UInt64) {
        guard let psm16 = CBL2CAPPSM(exactly: psm) else { return downgrade(reason: "bad PSM value") }
        p.openL2CAPChannel(psm16)
    }

    public func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else {
            return downgrade(reason: "channel open failed")
        }
        attach(channel)
    }
}
