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

@_spi(MdocInternal) public final class FirstReadyTransport: DataRetrievalTransportProtocol {

    public let events: AsyncStream<TransportEvent>
    private let emit: AsyncStream<TransportEvent>.Continuation
    private var candidates: [DataRetrievalTransportProtocol]
    private var labels: [String]
    private var openedWith: TransportConfig?
    public var onCandidateEvent: ((String, TransportEvent) -> Void)?
    private let lock = NSLock()
    private var chosen: DataRetrievalTransportProtocol?
    private var pumps: [Task<Void, Never>] = []
    private var failed: [ObjectIdentifier: MdocProximityError] = [:]
    private var reportedAllFailed = false

    public convenience init(_ candidates: [DataRetrievalTransportProtocol]) {
        self.init(candidates.enumerated().map { ("#\($0.offset)", $0.element) })
    }

    public init(_ labeled: [(String, DataRetrievalTransportProtocol)]) {
        self.candidates = labeled.map(\.1)
        self.labels = labeled.map(\.0)
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    public func open(_ config: TransportConfig) async throws {
        remember(config)
        for candidate in candidates { pump(candidate) }
        var failures: [Error] = []
        for candidate in candidates {
            do { try await candidate.open(config) } catch {
                failures.append(error)
                recordOpenFailure(error, from: candidate)
            }
        }
        if failures.count == candidates.count, let first = failures.first {
            markAllFailedReported()
            throw first
        }
        if let first = firstErrorIfAllFailed() { emit.yield(.failed(first)) }
    }

    private func recordOpenFailure(_ error: Error, from candidate: DataRetrievalTransportProtocol) {
        lock.lock(); defer { lock.unlock() }
        if failed[ObjectIdentifier(candidate)] == nil {
            failed[ObjectIdentifier(candidate)] = error as? MdocProximityError
                ?? .connectionFailed(detail: "open: \(error)")
        }
    }

    private func markAllFailedReported() {
        lock.lock(); defer { lock.unlock() }
        reportedAllFailed = true
    }

    public func add(_ label: String, _ candidate: DataRetrievalTransportProtocol) async throws {
        guard let config = register(label, candidate) else { candidate.close(.normal); return }
        pump(candidate)
        if let config { try await candidate.open(config) }
    }

    private func remember(_ config: TransportConfig) {
        lock.lock(); defer { lock.unlock() }
        openedWith = config
    }

    private func register(_ label: String, _ candidate: DataRetrievalTransportProtocol) -> TransportConfig?? {
        lock.lock(); defer { lock.unlock() }
        guard chosen == nil else { return nil }
        candidates.append(candidate); labels.append(label)
        return .some(openedWith)
    }

    private func pump(_ candidate: DataRetrievalTransportProtocol) {
        pumps.append(Task { [weak self] in
            for await event in candidate.events { self?.handle(event, from: candidate) }
        })
    }

    public func send(_ message: Data) async throws {
        guard let transport = current else { throw MdocProximityError.peerDisconnected }
        try await transport.send(message)
    }

    public func close(_ reason: TransportCloseReason) {
        for candidate in candidates { candidate.close(reason) }
        for pump in pumps { pump.cancel() }
        emit.finish()
    }

    private var current: DataRetrievalTransportProtocol? {
        lock.lock(); defer { lock.unlock() }
        return chosen
    }

    private func handle(_ event: TransportEvent, from source: DataRetrievalTransportProtocol) {
        lock.lock()
        let label = candidates.firstIndex(where: { $0 === source }).map { labels[$0] }
        lock.unlock()
        if let label { onCandidateEvent?(label, event) }
        lock.lock()
        if let chosen {
            let isChosen = chosen === source
            lock.unlock()
            if isChosen { emit.yield(event) }
            return
        }
        switch event {
        case .ready, .message:
            chosen = source
            lock.unlock()
            for candidate in candidates where candidate !== source { candidate.close(.normal) }
            emit.yield(event)
        case .failed(let error):
            if failed[ObjectIdentifier(source)] == nil { failed[ObjectIdentifier(source)] = error }
            lock.unlock()
            if let first = firstErrorIfAllFailed() { emit.yield(.failed(first)) }
        default:
            lock.unlock()
        }
    }

    private func firstErrorIfAllFailed() -> MdocProximityError? {
        lock.lock(); defer { lock.unlock() }
        guard chosen == nil, failed.count == candidates.count, !reportedAllFailed else { return nil }
        reportedAllFailed = true
        return candidates.compactMap { failed[ObjectIdentifier($0)] }.first
    }
}
