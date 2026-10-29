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
import CryptoKit

@_spi(MdocInternal) public enum KeyDerivation {

    public static func salt(_ transcript: SessionTranscriptBytes) -> Data {
        Data(SHA256.hash(data: transcript.raw))
    }

    public static func sessionKeys(zab: Data,
                                   transcript: SessionTranscriptBytes) -> (skReader: Data, skDevice: Data) {
        let s = salt(transcript)
        return (hkdf(zab, s, "SKReader", 32), hkdf(zab, s, "SKDevice", 32))
    }

    public static func eMacKey(zabPrime: Data, transcript: SessionTranscriptBytes) -> Data {
        hkdf(zabPrime, salt(transcript), "EMacKey", 32)
    }

    public static func bleIdent(eDeviceKeyBytes: Data) -> Data {
        hkdf(eDeviceKeyBytes, Data(), "BLEIdent", 16)
    }

    public static func nanServiceName(eDeviceKeyBytes: Data) -> Data {
        hkdf(eDeviceKeyBytes, Data(), "NANService", 16)
    }

    public static func nanPassphrase(eDeviceKeyBytes: Data) -> Data {
        hkdf(eDeviceKeyBytes, Data(), "NANPassphrase", 32)
    }

    private static func hkdf(_ ikm: Data, _ salt: Data, _ info: String, _ length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt,
                                         info: Data(info.utf8),
                                         outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }
}
