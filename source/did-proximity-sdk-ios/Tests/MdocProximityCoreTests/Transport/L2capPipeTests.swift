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

import XCTest
import CoreBluetooth
@_spi(MdocInternal) @testable import MdocProximityCore
@_spi(MdocInternal) @testable import MdocBLE

/// `CBL2CAPChannel` 은 만들 수 없으므로 **바운드 스트림 쌍**으로 파이프의 쓰기·닫기 순서를 본다.
/// 라디오 없이 검증 가능한 것은 이 한 가지 — "큐에 실린 것이 닫기 전에 전부 나가는가"다.
final class L2capPipeTests: XCTestCase {

    /// 응답을 큐에 싣고 **바로 닫아도** 반대편이 온전히 받아야 한다 — `send` 는 "큐에 실렸다"이고
    /// 링크는 큐를 비운 뒤 내린다. 소켓 버퍼(여기서는 바운드 스트림
    /// 버퍼)보다 큰 메시지를 써야 "바로 닫으면 잘린다"가 실제로 재현된다.
    func testCloseWaitsForQueuedOutputToDrain() async throws {
        var upIn: InputStream?, upOut: OutputStream?
        var downIn: InputStream?, downOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1024, inputStream: &upIn, outputStream: &downOut)
        Stream.getBoundStreams(withBufferSize: 1024, inputStream: &downIn, outputStream: &upOut)
        let sender = L2capChannelPipe(channel: nil, input: downIn!, output: downOut!)
        let receiver = L2capChannelPipe(channel: nil, input: upIn!, output: upOut!)

        let message = Data((0..<65_536).map { UInt8($0 % 251) })   // 버퍼 1KB 의 64배
        let got = expectation(description: "받음")
        var received: Data?
        receiver.onMessage = { received = $0; got.fulfill() }

        sender.send(message)
        XCTAssertTrue(sender.hasPendingOutput, "1KB 버퍼에 64KB 가 한 번에 들어갈 수 없다")

        // **전송체의 close 가 하는 순서 그대로** — 비운 뒤 닫는다
        await sender.waitUntilDrained(limit: 3)
        XCTAssertFalse(sender.hasPendingOutput, "상한 안에 큐가 비어야 한다")
        sender.close()

        await fulfillment(of: [got], timeout: 3)
        XCTAssertEqual(received, message, "닫기 전에 실은 것은 온전히 도착한다")
        receiver.close()
    }

    /// **출력 스트림의 end 는 받던 메시지를 버리지 않는다.** 상대가 닫으면 출력 쪽에도 end 가 오는데,
    /// 그것을 입력 end 와 같이 다뤄 조립 중이던 메시지를 버리고 닫힘을 두 번 알렸다 — 남은 바이트가
    /// 새 메시지 머리로 읽혀 `L2CAP message > 512 KiB` 로 끝났다(전체 실행에서 간헐 실패).
    /// 메인 스레드에서 이벤트를 직접 불러 순서를 고정한다 — 동기 테스트라 런루프는 돌지 않는다.
    func testOutputEndDoesNotDropMessageBeingReceived() {
        var upIn: InputStream?, downOut: OutputStream?
        var downIn: InputStream?, upOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 65_536, inputStream: &upIn, outputStream: &downOut)
        Stream.getBoundStreams(withBufferSize: 65_536, inputStream: &downIn, outputStream: &upOut)
        let receiver = L2capChannelPipe(channel: nil, input: upIn!, output: upOut!)
        downOut!.open()
        _ = downIn

        let message = Data((0..<4_096).map { UInt8($0 % 251) })
        let frame = [UInt8](L2capFraming.frame(message))
        var received: Data?
        var closedCount = 0
        receiver.onMessage = { received = $0 }
        receiver.onClosed = { closedCount += 1 }

        let half = frame.count / 2
        XCTAssertEqual(downOut!.write(frame, maxLength: half), half)
        receiver.stream(upIn!, handle: .hasBytesAvailable)
        receiver.stream(upOut!, handle: .endEncountered)          // 상대가 닫음 — 출력 쪽 end
        XCTAssertEqual(closedCount, 0, "출력 end 로는 닫힘을 알리지 않는다")

        XCTAssertEqual(frame[half...].withUnsafeBufferPointer { downOut!.write($0.baseAddress!, maxLength: $0.count) },
                       frame.count - half)
        receiver.stream(upIn!, handle: .hasBytesAvailable)
        XCTAssertEqual(received, message, "출력 end 전후로 나뉘어 온 메시지도 온전히 도착한다")

        receiver.stream(upIn!, handle: .endEncountered)
        XCTAssertEqual(closedCount, 1, "닫힘은 입력 end 에서 한 번만 알린다")
        receiver.close()
        downOut!.close()
    }

    /// 입력 end 가 버퍼에 남은 바이트보다 먼저 처리돼도 그 바이트를 읽고 나서 닫는다.
    func testInputEndReadsBufferedBytesFirst() {
        var upIn: InputStream?, downOut: OutputStream?
        var downIn: InputStream?, upOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 65_536, inputStream: &upIn, outputStream: &downOut)
        Stream.getBoundStreams(withBufferSize: 65_536, inputStream: &downIn, outputStream: &upOut)
        let receiver = L2capChannelPipe(channel: nil, input: upIn!, output: upOut!)
        downOut!.open()
        _ = downIn

        let message = Data(repeating: 0x5A, count: 1_000)
        let frame = [UInt8](L2capFraming.frame(message))
        var received: Data?
        var closedCount = 0
        receiver.onMessage = { received = $0 }
        receiver.onClosed = { closedCount += 1 }

        XCTAssertEqual(downOut!.write(frame, maxLength: frame.count), frame.count)
        receiver.stream(upIn!, handle: .endEncountered)           // hasBytesAvailable 없이 바로 end
        XCTAssertEqual(received, message)
        // 끝난 스트림을 읽으면 end 가 다시 온다 — 매번 읽으면 런루프가 그 자리에서 돈다
        receiver.stream(upIn!, handle: .endEncountered)
        XCTAssertEqual(closedCount, 1, "두 번째 end 는 무시한다")
        receiver.close()
        downOut!.close()
    }

    /// 반대편이 읽지 않으면 큐는 비지 않는다 — 그래도 상한을 넘기면 돌아와야 한다 (상위가 닫는다).
    func testWaitUntilDrainedReturnsAtLimit() async throws {
        var upIn: InputStream?, upOut: OutputStream?
        var downIn: InputStream?, downOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 256, inputStream: &upIn, outputStream: &downOut)
        Stream.getBoundStreams(withBufferSize: 256, inputStream: &downIn, outputStream: &upOut)
        let sender = L2capChannelPipe(channel: nil, input: downIn!, output: downOut!)
        _ = upIn; _ = upOut     // 읽는 쪽을 열지 않는다 — 버퍼가 차면 멈춘다

        sender.send(Data(repeating: 0xAB, count: 8_192))
        let started = Date()
        await sender.waitUntilDrained(limit: 0.3)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        XCTAssertTrue(sender.hasPendingOutput, "읽는 쪽이 없으니 남아 있어야 한다")
        sender.close()
    }
    /// **두 번 닫아도, 두 스레드에서 동시에 닫아도 한 번만 닫힌다.** 세션은 응답 직후와 `terminate()`
    /// 에서 close 를 두 번 부르고, 두 번째 unschedule 이 `CFArrayGetCount(NULL)` 로 죽었다
    /// (리더 앱 실기기, 2026-09-28). 크래시가 재현되던 경로라 죽지 않으면 통과다.
    func testCloseIsIdempotentAcrossThreads() async throws {
        for _ in 0..<50 {
            let (pipe, peer) = Self.pipePair()
            pipe.send(Data(repeating: 0x5A, count: 4_096))
            DispatchQueue.concurrentPerform(iterations: 4) { _ in pipe.close() }
            pipe.close()
            XCTAssertFalse(pipe.hasPendingOutput, "닫으면 큐도 비운다")
            peer.close()
        }
        await Self.drainMainQueue()              // 메인으로 넘긴 스트림 해제까지 돈다
    }

    /// 닫은 뒤의 `waitUntilDrained` 는 상한까지 매달리지 않는다 — 두 번째 close Task 가 상한만큼
    /// 기다렸다가 닫힌 파이프를 다시 만지던 것이 이번 경쟁의 창이었다.
    func testWaitUntilDrainedReturnsImmediatelyAfterClose() async throws {
        let (pipe, peer) = Self.pipePair(bufferSize: 256)
        pipe.send(Data(repeating: 0xAB, count: 8_192))
        pipe.close()
        let started = Date()
        await pipe.waitUntilDrained(limit: 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        peer.close()
        await Self.drainMainQueue()
    }

    /// 전송체 `close` 는 **한 번만 실행된다** — 두 번째는 아무것도 하지 않는다. GATT 전송체의
    /// `closing` 과 같다. `tearDownLink()`(여는 쪽이면 `cancelPeripheralConnection`)이 한 번인지로 본다.
    func testTransportCloseRunsOnce() async throws {
        let transport = CountingL2capTransport()
        let (pipe, peer) = Self.pipePair()
        transport.pipe = pipe
        transport.close(.normal)
        transport.close(.normal)
        for await _ in transport.events {}      // `emit.finish()` 까지
        try await Task.sleep(nanoseconds: 300_000_000)   // 두 번째 Task 가 있었다면 여기서 돈다
        XCTAssertEqual(transport.tearDowns, 1)
        XCTAssertNil(transport.pipe)
        peer.close()
        await Self.drainMainQueue()
    }

    private static func pipePair(bufferSize: Int = 1024) -> (L2capChannelPipe, L2capChannelPipe) {
        var upIn: InputStream?, upOut: OutputStream?
        var downIn: InputStream?, downOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &upIn, outputStream: &downOut)
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &downIn, outputStream: &upOut)
        return (L2capChannelPipe(channel: nil, input: downIn!, output: downOut!),
                L2capChannelPipe(channel: nil, input: upIn!, output: upOut!))
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
}

/// 링크 없이 close 경로만 도는 전송체. `tearDownLink()` 호출 수를 센다.
private final class CountingL2capTransport: BleL2capTransportBase {
    private let lock = NSLock()
    private var count = 0
    var tearDowns: Int { lock.lock(); defer { lock.unlock() }; return count }

    init() {
        super.init(profile: .peripheralServerMode(serviceUUID: CBUUID(nsuuid: UUID())),
                   fallback: { preconditionFailure("복귀하지 않는다") })
    }

    override func tearDownLink() { lock.lock(); count += 1; lock.unlock() }
}

