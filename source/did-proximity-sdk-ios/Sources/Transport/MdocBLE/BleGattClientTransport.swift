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

@_spi(MdocInternal) public final class BleGattClientTransport: NSObject, DataRetrievalTransportProtocol {

    public let events: AsyncStream<TransportEvent>
    private let emit: AsyncStream<TransportEvent>.Continuation
    private let profile: BleServiceProfile
    private let expectedIdent: Data?

    private var central: CBCentralManager?
    private var peer: CBPeripheral?
    private var stateChar: CBCharacteristic?
    private var c2s: CBCharacteristic?
    private var s2c: CBCharacteristic?
    private let buffer = ReassemblyBuffer()
    private var subscribed = false
    private let drainLimit: TimeInterval
    private var closing = false
    private var peerGone = false
    private let waitLock = NSLock()
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var unsubscribePending: Set<CBUUID> = []
    private var unsubscribeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(profile: BleServiceProfile, expectedIdent: Data? = nil, drainLimit: TimeInterval = 1.0) {
        self.profile = profile
        self.expectedIdent = expectedIdent
        self.drainLimit = drainLimit
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
        super.init()
    }

    public func open(_ config: TransportConfig) async throws {
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    public func send(_ message: Data) async throws {
        guard let peer, let c2s else { throw MdocProximityError.peerDisconnected }
        let mtu = peer.maximumWriteValueLength(for: .withoutResponse)
        let parts = try BleFraming.split(message, mtu: mtu + 3)
        var sent = 0
        for part in parts {
            while !peer.canSendWriteWithoutResponse {
                guard peer.state == .connected else { throw MdocProximityError.peerDisconnected }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            peer.writeValue(part, for: c2s, type: .withoutResponse)
            sent += part.count - 1
            emit.yield(.progress(sent: sent, total: message.count))
        }
    }

    public func close(_ reason: TransportCloseReason) {
        central?.stopScan()
        guard !closing else { return }
        closing = true
        guard let peer else { buffer.discard(); emit.finish(); return }
        guard let stateChar else {
            central?.cancelPeripheralConnection(peer); buffer.discard(); emit.finish(); return
        }
        Task { [self] in
            while !peer.canSendWriteWithoutResponse, peer.state == .connected {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if peer.state == .connected {
                peer.writeValue(Data([BleState.end.rawValue]), for: stateChar, type: .withoutResponse)
                await waitForDisconnect(limit: drainLimit)
                await unsubscribe(limit: drainLimit)
            }
            central?.cancelPeripheralConnection(peer)
            buffer.discard()
            emit.finish()
        }
    }

    private func waitForDisconnect(limit: TimeInterval) async {
        guard let peer, peer.state == .connected, limit > 0 else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waitLock.lock(); disconnectWaiters.append(c); waitLock.unlock()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                self?.resumeDisconnectWaiters()
            }
        }
    }

    private func resumeDisconnectWaiters() {
        waitLock.lock(); let w = disconnectWaiters; disconnectWaiters.removeAll(); waitLock.unlock()
        w.forEach { $0.resume() }
    }

    /// 8.3.3.1.1.7 — unsubscribes from State and Server2Client before disconnecting. Called after the queue drains
    /// (`waitForDisconnect`), so the CCCD writes never overtake remaining response fragments. Waiting for the confirmation
    /// callbacks keeps the writes from being dropped by the disconnect, and `limit` ends the wait if the peer never answers.
    private func unsubscribe(limit: TimeInterval) async {
        guard let peer, peer.state == .connected, limit > 0 else { return }
        let chars = [stateChar, s2c].compactMap { $0 }.filter(\.isNotifying)
        guard !chars.isEmpty else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waitLock.lock()
            unsubscribePending = Set(chars.map(\.uuid))
            unsubscribeWaiters.append(c)
            waitLock.unlock()
            chars.forEach { peer.setNotifyValue(false, for: $0) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                self?.resumeUnsubscribeWaiters()
            }
        }
    }

    private func unsubscribeConfirmed(_ uuid: CBUUID) {
        waitLock.lock()
        unsubscribePending.remove(uuid)
        let done = unsubscribePending.isEmpty
        waitLock.unlock()
        if done { resumeUnsubscribeWaiters() }
    }

    private func resumeUnsubscribeWaiters() {
        waitLock.lock(); let w = unsubscribeWaiters; unsubscribeWaiters.removeAll(); waitLock.unlock()
        w.forEach { $0.resume() }
    }

    private func emitPeerClosed() {
        guard !peerGone else { return }
        peerGone = true
        emit.yield(.peerClosed(.remote))
    }

    private func rejectAndRescan(_ p: CBPeripheral) {
        central?.cancelPeripheralConnection(p)
        peer = nil
        central?.scanForPeripherals(withServices: [profile.serviceUUID])
    }
}

extension BleGattClientTransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn:
            manager.scanForPeripherals(withServices: [profile.serviceUUID])
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
        p.discoverServices([profile.serviceUUID])
    }

    public func centralManager(_ manager: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        emit.yield(.failed(.connectionFailed(detail: "connect: \(error.map { "\($0)" } ?? "unknown")")))
    }

    public func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                               error: Error?) {
        guard p === peer else { return }
        buffer.discard()
        resumeDisconnectWaiters()
        resumeUnsubscribeWaiters()
        if !closing { emitPeerClosed() }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == profile.serviceUUID }) else {
            emit.yield(.failed(.connectionFailed(detail: "service not found")))
            return
        }
        var wanted = [profile.state, profile.client2Server, profile.server2Client]
        if let ident = profile.ident { wanted.append(ident) }
        p.discoverCharacteristics(wanted, for: service)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        let chars = service.characteristics ?? []
        stateChar = chars.first { $0.uuid == profile.state }
        c2s = chars.first { $0.uuid == profile.client2Server }
        s2c = chars.first { $0.uuid == profile.server2Client }

        if let identChar = chars.first(where: { $0.uuid == profile.ident }), expectedIdent != nil {
            p.readValue(for: identChar)
            return
        }
        subscribe(p, chars)
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.uuid == profile.ident {
            guard let expected = expectedIdent, c.value == expected else {
                return rejectAndRescan(p)
            }
            subscribe(p, p.services?.first?.characteristics ?? [])
            return
        }
        if c.uuid == profile.state {
            if c.value?.first == BleState.end.rawValue { emitPeerClosed() }
            return
        }
        guard c.uuid == profile.server2Client, let value = c.value else { return }
        do {
            if let complete = try buffer.append(value) { emit.yield(.message(complete)) }
        } catch {
            emit.yield(.failed(error as? MdocProximityError ?? .decodeFailed(detail: "reassembly")))
        }
    }

    private func subscribe(_ p: CBPeripheral, _ chars: [CBCharacteristic]) {
        for c in chars where c.uuid == profile.state || c.uuid == profile.server2Client {
            p.setNotifyValue(true, for: c)
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic,
                           error: Error?) {
        if closing, error != nil || !c.isNotifying { return unsubscribeConfirmed(c.uuid) }
        guard c.uuid == profile.server2Client, c.isNotifying, !subscribed else { return }
        subscribed = true
        if let stateChar {
            p.writeValue(Data([BleState.start.rawValue]), for: stateChar, type: .withoutResponse)
        }
        emit.yield(.ready)
    }
}
