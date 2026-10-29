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

@_spi(MdocInternal) public final class TransportEventRouter: @unchecked Sendable {

    private let transport: DataRetrievalTransportProtocol
    private let lock = NSLock()
    private var pending: [Data] = []
    private var messageWaiter: CheckedContinuation<Data?, Never>?
    private var readyWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var readyOutcome: Result<Void, Error>?
    private var finished = false
    private var task: Task<Void, Never>?

    public var onEvent: ((TransportEvent) -> Void)?

    public init(_ transport: DataRetrievalTransportProtocol) { self.transport = transport }

    public func start() {
        guard task == nil else { return }
        let stream = transport.events
        task = Task { [weak self] in
            for await event in stream { self?.handle(event) }
            self?.finish()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        finish()
    }

    public func waitReady() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let outcome = readyOutcome {
                    lock.unlock(); c.resume(with: outcome)
                } else if Task.isCancelled {
                    lock.unlock(); c.resume(throwing: CancellationError())
                } else {
                    readyWaiters.append((id, c)); lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = readyWaiters.first { $0.id == id }?.continuation
            readyWaiters.removeAll { $0.id == id }
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }

    public func nextMessage() async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                lock.lock()
                if !pending.isEmpty {
                    let d = pending.removeFirst(); lock.unlock(); c.resume(returning: d)
                } else if finished || Task.isCancelled {
                    lock.unlock(); c.resume(returning: nil)
                } else {
                    messageWaiter = c; lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = messageWaiter; messageWaiter = nil
            lock.unlock()
            waiter?.resume(returning: nil)
        }
    }

    // MARK: -

    private func handle(_ event: TransportEvent) {
        switch event {
        case .message(let d): deliver(d)
        case .ready: resolveReady(.success(()))
        case .failed(let e): resolveReady(.failure(e)); finish()
        case .peerClosed: finish()
        default: break
        }
        onEvent?(event)
    }

    private func deliver(_ message: Data) {
        lock.lock()
        if let waiter = messageWaiter {
            messageWaiter = nil; lock.unlock(); waiter.resume(returning: message)
        } else {
            pending.append(message); lock.unlock()
        }
    }

    private func resolveReady(_ outcome: Result<Void, Error>) {
        lock.lock()
        guard readyOutcome == nil else { return lock.unlock() }
        readyOutcome = outcome
        let waiters = readyWaiters; readyWaiters.removeAll()
        lock.unlock()
        for w in waiters { w.continuation.resume(with: outcome) }
    }

    private func finish() {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let waiter = messageWaiter; messageWaiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
        resolveReady(.failure(MdocProximityError.peerDisconnected))
    }
}
