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

public struct EngagementPayload {
    public let qrString: String?
    public let technology: EngagementTechnology
    public let transmissions: [TransmissionTechnology]

    @_spi(MdocInternal) public let deviceEngagement: DeviceEngagement
    @_spi(MdocInternal) public let handover: EngagementArtifacts?

    var engagementBytes: OpaqueCBOR {
        OpaqueCBOR(preserving: CborEncoder.tag24(deviceEngagement.raw.raw))
    }

    init(deviceEngagement: DeviceEngagement, technology: EngagementTechnology,
         qrString: String?, handover: EngagementArtifacts? = nil) {
        self.deviceEngagement = deviceEngagement
        self.technology = technology
        self.qrString = qrString
        self.handover = handover
        if let carriers = handover?.carriers, !carriers.isEmpty { self.transmissions = carriers }
        else { self.transmissions = Self.transmissions(of: deviceEngagement) }
    }

    @_spi(MdocInternal) public var nfcMaxCommandDataLength: UInt64? {
        handover?.nfcMaxCommandDataLength ?? nfcOptions?.maxCommandDataLength
    }
    @_spi(MdocInternal) public var nfcMaxResponseDataLength: UInt64? {
        handover?.nfcMaxResponseDataLength ?? nfcOptions?.maxResponseDataLength
    }

    @_spi(MdocInternal) public func sessionTranscript(eReaderKeyBytes: OpaqueCBOR) -> SessionTranscriptBytes {
        if let handover, let select = handover.handoverSelectBytes {
            return SessionTranscriptBuilder.nfc(deviceEngagementBytes: engagementBytes,
                                                eReaderKeyBytes: eReaderKeyBytes,
                                                handoverSelect: select,
                                                handoverRequest: handover.handoverRequestBytes)
        }
        return SessionTranscriptBuilder.qr(deviceEngagementBytes: engagementBytes,
                                           eReaderKeyBytes: eReaderKeyBytes)
    }

    public static func parse(qrString: String) throws -> EngagementPayload {
        guard qrString.hasPrefix("mdoc:") else {
            throw MdocProximityError.malformedEngagement(detail: "missing \"mdoc:\" scheme")
        }
        guard let data = base64urlDecode(String(qrString.dropFirst("mdoc:".count))) else {
            throw MdocProximityError.malformedEngagement(detail: "base64url")
        }
        return EngagementPayload(deviceEngagement: try EngagementCodec.decode(data),
                                 technology: .qr, qrString: qrString)
    }

    @_spi(MdocInternal) public static func make(_ engagement: Data,
                            technology: EngagementTechnology = .qr,
                            handover: EngagementArtifacts? = nil) throws -> EngagementPayload {
        EngagementPayload(deviceEngagement: try EngagementCodec.decode(engagement),
                          technology: technology,
                          qrString: technology == .qr ? "mdoc:" + base64urlEncode(engagement) : nil,
                          handover: handover)
    }

    @_spi(MdocInternal) public var bleOptions: BleOptions? {
        deviceEngagement.retrievalMethods.first { $0.type == 2 }.flatMap { BleOptions($0.options) }
    }

    @_spi(MdocInternal) public var wifiOptions: WifiOptions? {
        deviceEngagement.retrievalMethods.first { $0.type == 3 }.flatMap { WifiOptions($0.options) }
    }

    @_spi(MdocInternal) public var nfcOptions: NfcOptions? {
        deviceEngagement.retrievalMethods.first { $0.type == 1 }.flatMap { NfcOptions($0.options) }
    }

    private static func transmissions(of de: DeviceEngagement) -> [TransmissionTechnology] {
        var out: [TransmissionTechnology] = []
        for m in de.retrievalMethods {
            switch m.type {
            case 1: out.append(.nfc)
            case 2:
                guard let o = BleOptions(m.options) else { continue }
                if o.centralClientMode { out.append(.ble(.centralClient)) }
                if o.peripheralServerMode { out.append(.ble(.peripheralServer)) }
            case 3: out.append(.wifiAware)
            default: continue
            }
        }
        return out
    }

    private static func base64urlEncode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
