# Changelog

## v1.0.0 (2026-10-27)

### 🚀 New Features
- MdocDevice (mdoc — holder app)
    - Device engagement over QR and NFC (static and negotiated handover)
    - BLE data retrieval in mdoc peripheral server and mdoc central client modes, with L2CAP upgrade and GATT fallback
    - NFC data retrieval through card emulation provided by the app (`NfcCardEmulationProtocol`)
    - Delivers the decrypted `DeviceRequest` with the `SessionTranscript`, so the wallet builds and signs the `DeviceResponse`
    - Response, rejection and termination (`respond`, `reject`, `terminate`)
    - Engagement and response timeouts
- MdocReader (mdoc reader — verifier app)
    - Connection from a scanned QR engagement or an NFC tap (`connect`, `connectViaNFC`), with transport selection by priority
    - BLE data retrieval in both modes (L2CAP upgrade, GATT fallback) and NFC data retrieval, including extended-length APDUs
    - `DeviceRequest` construction — `ItemsRequestSpec`, JSON request profiles, presets (age over N, identity, driving privileges) and several documents in one request
    - Response verification — issuer signature (ES256 / P-256), value digests (SHA-256 / SHA-384 / SHA-512), MSO validity and docType, deviceSignature and deviceMac, `keyAuthorizations` for device-signed elements
    - Per-document results — verdict, warnings for unrequested or unauthorized elements, elements not returned, intent to retain
- MdocTrust
    - Issuer key resolution through DID against a trusted-issuer list (`DIDIssuerKeyResolver`)
    - Replaceable trust evaluation (`TrustEvaluatorProtocol`) and trust resolution after the session (`resolveTrust`)
- Common
    - Session encryption — ephemeral ECDH key agreement, HKDF-SHA256 session keys, AES-GCM
    - Session termination with status codes (ISO/IEC 18013-5 Table 20)
    - Capability check before a session — permissions, entitlements and hardware (`MdocCapabilities.current()`)
    - Session state and delegate callbacks on a configurable queue; session methods may be called from any thread
    - One active session per process
    - Errors as `MdocProximityError`

### 📦 Distribution
- Swift Package with one product per role — `MdocDevice`, `MdocReader`
- `MdocProximitySDK.xcframework` for iOS devices and the iOS Simulator
- iOS 17.0 or later, Swift 5
