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
import CryptoKit
@_spi(MdocInternal) @testable import MdocProximityCore
@_spi(MdocInternal) @testable import MdocTrust
@_spi(MdocInternal) @testable import MdocDevice
@_spi(MdocInternal) @testable import MdocReader

/// 전송 이벤트가 세션을 움직인다 — 앱이 `receive()` 를 직접 부르지 않는다.
final class EventPumpTests: XCTestCase, MdocDeviceSessionDelegate {

    private var received: (request: Data, transcript: Data)?
    private var finished = false
    private var failure: MdocProximityError?
    private var onRequest: (() -> Void)?

    func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) {}
    func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                     sessionTranscript: Data) {
        received = (deviceRequest, sessionTranscript); onRequest?()
    }
    func mdocSessionDidFinish(_ s: MdocDeviceSession) { finished = true }
    func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) { failure = error }

    override func tearDown() { SessionRegistry.release() }

    func testTransportEventDrivesSession() async throws {
        let eD = P256.KeyAgreement.PrivateKey(), eR = P256.KeyAgreement.PrivateKey()
        let zab = try eR.sharedSecretFromKeyAgreement(with: eD.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)

        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in
            issuerKey.publicKey.x963Representation }

        let (rl, ml) = LoopbackTransport.pair()
        let cfg = verifyingReaderConfiguration(responseTimeout: 3)
        let reader = MdocReaderSession(configuration: cfg, transport: rl, trust: trust)
        let mdoc = MdocDeviceSession(transport: ml)
        mdoc.delegate = self

        // 앱은 콜백을 받으면 월렛에 넘기고 respond 한다 — receive 를 직접 부르지 않는다
        onRequest = { [weak mdoc] in
            Task {
                try? await mdoc?.respond(deviceResponse: Fixtures.response(
                    transcript: transcript, issuerKey: issuerKey, deviceKey: deviceKey, did: did))
            }
        }
        mdoc.begin(transcript: transcript, sharedSecret: zab)     // 여기서 펌프가 돈다
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: erk)

        let result = try await reader.request([ItemsRequestPresets.identity], at: Date())

        await drainCallbacks()
        XCTAssertNotNil(received, "전송 이벤트가 콜백을 띄워야 한다")
        print("DEBUG state=\(mdoc.state) finished=\(finished) failure=\(String(describing: failure))")
        XCTAssertEqual(received?.transcript, transcript.raw, "트랜스크립트를 바이트 그대로 넘긴다")
        XCTAssertTrue(finished)
        XCTAssertNil(failure)
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.documents[0].verdict, .valid)
        XCTAssertEqual(mdoc.state, .completed)
    }
}
