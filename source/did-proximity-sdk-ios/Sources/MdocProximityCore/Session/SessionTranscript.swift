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

@_spi(MdocInternal) public struct SessionTranscriptBytes: Equatable {
    public let raw: Data
    init(raw: Data) { self.raw = raw }
}

@_spi(MdocInternal) public enum SessionTranscriptBuilder {

    public static func qr(deviceEngagementBytes: OpaqueCBOR,
                          eReaderKeyBytes: OpaqueCBOR) -> SessionTranscriptBytes {
        build(deviceEngagementBytes, eReaderKeyBytes, CborEncoder.encode(.null))
    }

    public static func nfc(deviceEngagementBytes: OpaqueCBOR,
                           eReaderKeyBytes: OpaqueCBOR,
                           handoverSelect: Data,
                           handoverRequest: Data?) -> SessionTranscriptBytes {
        let handover = CborEncoder.encode(.array([
            .bytes(handoverSelect),
            handoverRequest.map { CborValue.bytes($0) } ?? .null
        ]))
        return build(deviceEngagementBytes, eReaderKeyBytes, handover)
    }

    private static func build(_ de: OpaqueCBOR, _ er: OpaqueCBOR, _ handover: Data) -> SessionTranscriptBytes {
        var arr = Data([0x83])
        arr.append(de.raw)
        arr.append(er.raw)
        arr.append(handover)
        return SessionTranscriptBytes(raw: CborEncoder.tag24(arr))
    }

    public static func transcriptArray(_ bytes: SessionTranscriptBytes) throws -> Data {
        let node = try CborDecoder.decodeNode(bytes.raw)
        guard case .tagged(24, .bytes(let inner)) = node.value else {
            throw MdocProximityError.validationFailed(detail: "SessionTranscriptBytes is not #6.24(bstr)")
        }
        return inner
    }
}
