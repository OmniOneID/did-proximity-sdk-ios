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
@_spi(MdocInternal) @testable import MdocProximityCore

extension Data {
    init?(hex: String) {
        var d = Data(); var it = hex.startIndex
        while it < hex.endIndex {
            guard let n = hex.index(it, offsetBy: 2, limitedBy: hex.endIndex),
                  let b = UInt8(hex[it..<n], radix: 16) else { return nil }
            d.append(b); it = n
        }
        self = d
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    /// QR 본문 형식 — RFC 4648 base64url, 패딩 없음 (8.2.2.3)
    var base64urlNoPad: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

final class CborTests: XCTestCase {

    // 결정적 인코딩 — 맵 키를 bytewise 사전순으로 정렬한다
    func testDeterministicMapKeyOrder() {
        let m = CborValue.map([
            CborPair(.unsigned(7), .text("future")),
            CborPair(.unsigned(0), .text("1.0")),
            CborPair(.unsigned(5), .bytes(Data([0xde, 0xad])))
        ])
        // 0 → 5 → 7 순으로 나와야 한다
        XCTAssertEqual(CborEncoder.encode(m).hex, "a30063312e30054" + "2dead" + "0766667574757265")
    }

    // 최단 정수만 만든다
    func testShortestFormIntegers() {
        XCTAssertEqual(CborEncoder.encode(.unsigned(23)).hex, "17")
        XCTAssertEqual(CborEncoder.encode(.unsigned(24)).hex, "1818")
        XCTAssertEqual(CborEncoder.encode(.unsigned(256)).hex, "190100")
        XCTAssertEqual(CborEncoder.encode(.unsigned(65536)).hex, "1a00010000")
    }

    // 디코딩 관대 정책 — indefinite-length map + 비최단 정수 + 모르는 키 + version "1.1"
    // 벡터 engagement/decode-tolerant 의 입력 그대로다
    func testTolerantDecode() throws {
        let input = Data(hex: "bf0063312e3101821801d818584ba401022001215820101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f225820303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f0544deadbeef0766667574757265ff")!
        let node = try CborDecoder.decodeNode(input)

        XCTAssertEqual(node.value.member(0)?.asText, "1.1")

        // Security = [1, #6.24(...)] — 1 이 비최단(0x1801)으로 실려 있어도 받는다
        let security = node.value.member(1)?.asArray
        XCTAssertEqual(security?.first?.asUInt, 1)

        // 모르는 정수 키 5·7 은 무시하되 값은 남아 있다
        XCTAssertEqual(node.value.member(5)?.asBytes?.hex, "deadbeef")
        XCTAssertEqual(node.value.member(7)?.asText, "future")

        // 원본 바이트 보존 — 재인코딩하지 않는다
        XCTAssertEqual(OpaqueCBOR(node, in: input).raw.hex, input.hex)
    }

    // EDeviceKeyBytes 를 원본 바이트로 뽑는다 — 트랜스크립트 입력이 된다
    func testExtractEDeviceKeyBytesPreservingRaw() throws {
        let input = Data(hex: "bf0063312e3101821801d818584ba401022001215820101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f225820303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f0544deadbeef0766667574757265ff")!
        let node = try CborDecoder.decodeNode(input)
        // 최상위 맵의 자식은 [k0,v0, k1,v1, ...] 순이다. 키 1 의 값 = Security 배열
        let securityNode = node.children[3]
        let edkNode = securityNode.children[1]        // [cipherSuite, EDeviceKeyBytes]
        XCTAssertEqual(OpaqueCBOR(edkNode, in: input).raw.hex,
                       "d818584ba401022001215820101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f225820303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f")
    }

    // 거부하는 셋 중 둘
    func testLimits() {
        var deep = Data()
        for _ in 0...(CborDecoder.maxDepth + 1) { deep.append(0x81) }   // 중첩 배열
        deep.append(0xf6)
        XCTAssertThrowsError(try CborDecoder.decode(deep))
        XCTAssertThrowsError(try CborDecoder.decode(Data([0x18])))       // truncated
    }

    // 맵 길이 2^63 — 원소 수 상한을 곱하기 **전에** 건다. 전에는 `len * 2` 가 UInt64 오버플로로 트랩이었다
    func testHugeMapLengthIsRejectedNotTrapped() {
        let map = Data([0xBB, 0x80, 0, 0, 0, 0, 0, 0, 0])   // major 5, 8바이트 길이 = 0x8000000000000000
        XCTAssertThrowsError(try CborDecoder.decode(map)) { e in
            guard case .decodeFailed = (e as! MdocProximityError) else { return XCTFail("wrong code") }
        }
        let array = Data([0x9B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])   // 배열도 같은 상한
        XCTAssertThrowsError(try CborDecoder.decode(array))
    }

    /// well-formed 이면 받는다 — float16·32·64 와 simple value 를 값으로 올린다. 전에는
    /// `decodeFailed` 라 float 하나가 응답 전체를 실패시키거나 IssuerSignedItem 을 조용히 뺐다.
    func testFloatAndSimpleValuesDecode() throws {
        XCTAssertEqual(try CborDecoder.decode(Data(hex: "f93c00")!), .float(1.0))        // half
        XCTAssertEqual(try CborDecoder.decode(Data(hex: "f9c400")!), .float(-4.0))
        XCTAssertEqual(try CborDecoder.decode(Data(hex: "f90001")!), .float(5.960464477539063e-8))
        XCTAssertEqual(try CborDecoder.decode(Data(hex: "f97c00")!), .float(.infinity))
        XCTAssertEqual(try CborDecoder.decode(Data(hex: "fa47c35000")!), .float(100000.0))   // single
        XCTAssertEqual(try CborDecoder.decode(Data(hex: "fb3ff199999999999a")!), .float(1.1)) // double
        XCTAssertEqual(try CborDecoder.decode(Data(hex: "f0")!), .simple(16))
        XCTAssertEqual(try CborDecoder.decode(Data(hex: "f8ff")!), .simple(255))
        XCTAssertThrowsError(try CborDecoder.decode(Data(hex: "f818")!), "1바이트 확장의 32 미만은 well-formed 가 아니다")
        XCTAssertThrowsError(try CborDecoder.decode(Data(hex: "ff")!), "짝 없는 break")
    }

    /// undefined 는 null 이 아니다 — 앱에는 `.unsupported` 로 간다. float·simple 도 같다.
    func testUndefinedIsNotNull() throws {
        XCTAssertEqual(try CborDecoder.decode(Data([0xf7])), .undefined)
        XCTAssertEqual(MdocValue(.undefined), .unsupported)
        XCTAssertEqual(MdocValue(.float(1.5)), .unsupported)
        XCTAssertEqual(MdocValue(.simple(16)), .unsupported)
        XCTAssertEqual(MdocValue(.null), .null)
        XCTAssertEqual(CborEncoder.encode(.undefined).hex, "f7")
        XCTAssertEqual(try CborDecoder.decode(CborEncoder.encode(.float(1.1))), .float(1.1))
    }
}
