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

@_spi(MdocInternal) public final class BleGattServerTransport: NSObject, DataRetrievalTransportProtocol {

    public let events: AsyncStream<TransportEvent>
    private let emit: AsyncStream<TransportEvent>.Continuation
    private let profile: BleServiceProfile
    private let identValue: Data?
    private let publishesL2cap: Bool
    private var psm: CBL2CAPPSM?
    private var pipe: L2capChannelPipe?

    private var manager: CBPeripheralManager?
    private var s2c: CBMutableCharacteristic?
    private var stateChar: CBMutableCharacteristic?
    private var subscribedCentral: CBCentral?
    private var subscribed: Bool { subscribedCentral != nil }
    private var started = false
    private let buffer = ReassemblyBuffer()

    private var pending: [Data] = []

    private let drainLimit: TimeInterval
    private var closing = false
    private var peerGone = false
    private let waitLock = NSLock()
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var readyGeneration: UInt64 = 0
    private var unsubscribeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(profile: BleServiceProfile, identValue: Data? = nil,
                publishesL2cap: Bool = false, drainLimit: TimeInterval = 1.0) {
        self.profile = profile
        self.identValue = identValue
        self.publishesL2cap = publishesL2cap
        self.drainLimit = drainLimit
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
        super.init()
    }

    public func open(_ config: TransportConfig) async throws {
        manager = CBPeripheralManager(delegate: self, queue: nil,
                                      options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }

    public func send(_ message: Data) async throws {
        if let pipe {
            pipe.send(message)
            emit.yield(.progress(sent: message.count, total: message.count))
            return
        }
        guard subscribed else { pending.append(message); return }
        let mtu = subscribedCentral?.maximumUpdateValueLength ?? 20
        let parts = try BleFraming.split(message, mtu: mtu + 3)
        var sent = 0
        for part in parts {
            guard subscribed, let s2c, let manager else { throw MdocProximityError.peerDisconnected }
            while true {
                let generation = currentReadyGeneration()
                if manager.updateValue(part, for: s2c, onSubscribedCentrals: nil) { break }
                await waitUntilReady(since: generation)
                guard subscribed else { throw MdocProximityError.peerDisconnected }
            }
            sent += part.count - 1
            emit.yield(.progress(sent: sent, total: message.count))
        }
    }

    private func currentReadyGeneration() -> UInt64 {
        waitLock.lock(); defer { waitLock.unlock() }
        return readyGeneration
    }

    private func waitUntilReady(since generation: UInt64) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waitLock.lock()
            if readyGeneration != generation { waitLock.unlock(); c.resume(); return }
            readyWaiters.append(c)
            waitLock.unlock()
        }
    }

    private func waitForUnsubscribe(limit: TimeInterval) async {
        guard subscribed, limit > 0 else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waitLock.lock(); unsubscribeWaiters.append(c); waitLock.unlock()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                self?.resumeUnsubscribeWaiters()
            }
        }
    }

    private func resumeReadyWaiters() {
        waitLock.lock()
        readyGeneration &+= 1
        let w = readyWaiters; readyWaiters.removeAll()
        waitLock.unlock()
        w.forEach { $0.resume() }
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

    public func close(_ reason: TransportCloseReason) {
        manager?.stopAdvertising()
        guard !closing else { return }
        closing = true
        let sendsEnd = subscribed && pipe == nil
        Task { [self] in
            if let pipe {
                await pipe.waitUntilDrained(limit: drainLimit)
                try? await Task.sleep(nanoseconds: 100_000_000)
                pipe.close(); self.pipe = nil
            }
            if let psm { manager?.unpublishL2CAPChannel(psm) }
            if sendsEnd, let stateChar, let manager {
                while subscribed {
                    let generation = currentReadyGeneration()
                    if manager.updateValue(Data([BleState.end.rawValue]), for: stateChar,
                                           onSubscribedCentrals: nil) { break }
                    await waitUntilReady(since: generation)
                }
            }
            await waitForUnsubscribe(limit: drainLimit)
            manager?.removeAllServices()
            buffer.discard()
            resumeReadyWaiters()
            emit.finish()
        }
    }
}

extension BleGattServerTransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if publishesL2cap { peripheral.publishL2CAPChannel(withEncryption: false) }
            else { registerService(peripheral) }
        case .poweredOff:
            emit.yield(.failed(.configurationRequired(action: .enableBluetooth)))
        case .unauthorized:
            emit.yield(.failed(.configurationRequired(action: .grantPermission("bluetooth"))))
        case .unsupported:
            emit.yield(.failed(.bleUnavailable(reason: .noHardware)))
        default: break
        }
    }

    private func registerService(_ peripheral: CBPeripheralManager) {
        let state = CBMutableCharacteristic(type: profile.state,
                                            properties: [.notify, .writeWithoutResponse],
                                            value: nil, permissions: [.writeable])
        let c2s = CBMutableCharacteristic(type: profile.client2Server,
                                          properties: [.writeWithoutResponse],
                                          value: nil, permissions: [.writeable])
        let s2c = CBMutableCharacteristic(type: profile.server2Client,
                                          properties: [.notify], value: nil, permissions: [])
        var chars: [CBCharacteristic] = [state, c2s, s2c]
        if let psm {
            chars.append(CBMutableCharacteristic(type: profile.l2cap, properties: [.read],
                                                 value: L2capPsmCodec.encode(psm), permissions: [.readable]))
        }
        if let identUUID = profile.ident, let identValue {
            chars.append(CBMutableCharacteristic(type: identUUID, properties: [.read],
                                                 value: identValue, permissions: [.readable]))
        }
        let service = CBMutableService(type: profile.serviceUUID, primary: true)
        service.characteristics = chars
        self.s2c = s2c
        self.stateChar = state
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didAdd service: CBService, error: Error?) {
        guard error == nil else {
            emit.yield(.failed(.connectionFailed(detail: "add service")))
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [profile.serviceUUID]])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == profile.server2Client else { return }
        subscribedCentral = central
        emit.yield(.ready)
        let queued = pending; pending.removeAll()
        Task { for p in queued { try? await send(p) } }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == profile.server2Client,
              central.identifier == subscribedCentral?.identifier else { return }
        subscribedCentral = nil
        resumeReadyWaiters()
        resumeUnsubscribeWaiters()
        if !closing { emitPeerClosed() }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let value = r.value ?? Data()
            if r.characteristic.uuid == profile.state {
                if value.first == BleState.start.rawValue { started = true }
                if value.first == BleState.end.rawValue { emitPeerClosed() }
            } else if r.characteristic.uuid == profile.client2Server {
                guard started else { continue }
                do {
                    if let complete = try buffer.append(value) {
                        if pipe != nil {
                            pipe?.close(); pipe = nil
                            emit.yield(.downgradedToGatt(reason: "peer used GATT"))
                        }
                        emit.yield(.message(complete))
                    }
                } catch {
                    emit.yield(.failed(error as? MdocProximityError ?? .decodeFailed(detail: "reassembly")))
                }
            }
        }
        peripheral.respond(to: requests[0], withResult: .success)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        resumeReadyWaiters()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        psm = error == nil ? PSM : nil
        registerService(peripheral)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else { return }
        let pipe = L2capChannelPipe(channel: channel)
        pipe.onMessage = { [weak self] in self?.emit.yield(.message($0)) }
        pipe.onError = { [weak self] error in
            self?.pipe?.close(); self?.pipe = nil
            self?.emit.yield(.downgradedToGatt(reason: "\(error)"))
        }
        pipe.onClosed = { [weak self] in self?.emit.yield(.peerClosed(.remote)) }
        self.pipe = pipe
        buffer.discard()
        emit.yield(.ready)
    }
}
