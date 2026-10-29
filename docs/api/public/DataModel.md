---
puppeteer:
    pdf:
        format: A4
        displayHeaderFooter: true
        landscape: false
        scale: 0.8
        margin:
            top: 1.2cm
            right: 1cm
            bottom: 1cm
            left: 1cm
    image:
        quality: 100
        fullPage: false
---

iOS MdocProximity DataModel
==

- Subject: DataModel
- Writer: JooHyun Park
- Date: 2026-10-12
- Version: v1.0.0

| Version          | Date       | History                 |
| ---------------- | ---------- | ------------------------|
| v1.0.0           | 2026-10-12 | Initial                 |


<div style="page-break-after: always;"></div>


# Table of Contents
- [Overview](#overview)
- [Identifiers](#identifiers)
    - [1. Type Aliases](#1-type-aliases)
    - [2. MdocDocTypes](#2-mdocdoctypes)
- [Data Element Values](#data-element-values)
    - [1. MdocValue](#1-mdocvalue)
- [Engagement and Transmission](#engagement-and-transmission)
    - [1. EngagementPayload](#1-engagementpayload)
    - [2. EngagementTechnology](#2-engagementtechnology)
    - [3. TransmissionTechnology](#3-transmissiontechnology)
    - [4. BleMode](#4-blemode)
- [Verification Results](#verification-results)
    - [1. VerifiedResponse](#1-verifiedresponse)
    - [2. VerifiedDocument](#2-verifieddocument)
    - [3. IssuerDataAuthResult](#3-issuerdataauthresult)
    - [4. ValidityCheck](#4-validitycheck)
    - [5. MdocAuthResult](#5-mdocauthresult)
    - [6. DigestCheckResult](#6-digestcheckresult)
    - [7. VerificationVerdict](#7-verificationverdict)
    - [8. ElementProvenance](#8-elementprovenance)
    - [9. DocumentWarning](#9-documentwarning)
    - [10. Interpreting Verification Results](#10-interpreting-verification-results)
        - [10.1. Element Provenance](#101-element-provenance)
        - [10.2. Namespace Scope](#102-namespace-scope)
        - [10.3. Unknown Elements](#103-unknown-elements)
        - [10.4. Retention and intentToRetain](#104-retention-and-intenttoretain)
        - [10.5. Partial Responses and notReturned](#105-partial-responses-and-notreturned)
- [Capabilities](#capabilities)
    - [1. MdocCapabilities](#1-mdoccapabilities)
    - [2. RoleCapabilities](#2-rolecapabilities)
    - [3. TransportCapability](#3-transportcapability)
    - [4. Interpreting Capabilities](#4-interpreting-capabilities)
        - [4.1. Unsupported vs Configuration Required](#41-unsupported-vs-configuration-required)
        - [4.2. NFC on iOS](#42-nfc-on-ios)
        - [4.3. Bluetooth Query Limits](#43-bluetooth-query-limits)

<br>

# Overview

This document describes the public value types shared by the ISO/IEC 18013-5 proximity presentation SDK.

| Distribution | Import | Note |
|--------------|--------|------|
| Swift Package product `MdocDevice` | `import MdocDevice` | mdoc (holder) app. Re-exports the types in this document |
| Swift Package product `MdocReader` | `import MdocReader` | mdoc reader app. Re-exports the types in this document and [MdocTrust](MdocTrust.md) |
| XCFramework | `import MdocProximitySDK` | Single module containing all public types |

Related documents

| Document | Content |
|----------|---------|
| [MdocDeviceAPI](MdocDeviceAPI.md) | `MdocDeviceSession`, its configuration, states and callbacks |
| [MdocReaderAPI](MdocReaderAPI.md) | `MdocReaderSession`, reader configuration, request building and callbacks |
| [MdocTrust](MdocTrust.md) | Issuer trust evaluation used by the reader app |
| [MdocProximityError](MdocProximityError.md) | `MdocProximityError`, `CapabilityReason`, `RequiredAction` |

**mdoc documents are not SDK types.** On the mdoc side, the choice of which document to present and which data elements to disclose does not appear in this SDK's API. Document storage, matching and holder consent belong to the wallet SDK and the app. This SDK hands the app the request bytes and receives the response bytes. For that reason there is no document reference type and no handle wrapping a storage identifier.

Values in this document are produced by the SDK. Types without a public initializer are not meant to be constructed by the app.

<br>

# Identifiers

## 1. Type Aliases

### Description

`Identifiers used throughout the API. All are String.`

### Declaration

```swift
// Declaration in Swift
public typealias DocType               = String   // "org.iso.18013.5.1.mDL"
public typealias NameSpace             = String   // "org.iso.18013.5.1"
public typealias DataElementIdentifier = String   // "family_name"
```

### Property

| Name                  | Type   | Description                     | **M/O** | **Note** |
|-----------------------|--------|---------------------------------|---------|----------|
| DocType               | String | Document type                   |    M    | No format is imposed |
| NameSpace             | String | Data element namespace          |    M    | No format is imposed |
| DataElementIdentifier | String | Data element identifier within a namespace |    M    |          |

<br>

## 2. MdocDocTypes

### Description

`Convenience constants for mDL.`

The protocol does not restrict document types or namespaces. These constants exist only for the mDL document type. For other document types, use the identifiers directly. See [10.2. Namespace Scope](#102-namespace-scope).

### Declaration

```swift
// Declaration in Swift
public enum MdocDocTypes {
    public static let mDL          = "org.iso.18013.5.1.mDL"
    public static let mDLNameSpace = "org.iso.18013.5.1"
}
```

### Property

| Name         | Type   | Description         | **M/O** | **Note** |
|--------------|--------|---------------------|---------|----------|
| mDL          | String | mDL document type   |    M    | `org.iso.18013.5.1.mDL` |
| mDLNameSpace | String | mDL namespace       |    M    | `org.iso.18013.5.1` |

<br>

# Data Element Values

## 1. MdocValue

### Description

`Value of a data element. Represents a CBOR value with its tag preserved as a case.`

Tagged values are delivered as distinct cases: a `full-date` (tag 1004) and a date-time (tag 0) arrive as `.fullDate` and `.dateTime` even when the text looks alike. Date values are delivered as the **original text**. The SDK does not parse dates; parsing and locale or time zone interpretation are left to the app.

Values are extracted by pattern matching (`if case .integer(let n) = value`). Only `asText` and `asBoolean` are provided as accessors. The SDK provides no display formatting API.

### Declaration

```swift
// Declaration in Swift
public enum MdocValue: Equatable {
    case text(String)
    case integer(Int64)
    case boolean(Bool)
    case bytes(Data)
    case fullDate(String)      // tag 1004
    case dateTime(String)      // tag 0
    case array([MdocValue])
    case map([String: MdocValue])
    case null
    case unsupported

    public var asBoolean: Bool? { get }
    public var asText: String? { get }
}
```

### Property

| Name        | Type                  | Description                                     | **M/O** | **Note** |
|-------------|-----------------------|-------------------------------------------------|---------|----------|
| text        | String                | Text string                                     |    -    |          |
| integer     | Int64                 | Integer                                         |    -    | Integers outside the `Int64` range are `.unsupported` |
| boolean     | Bool                  | Boolean                                         |    -    | e.g. `age_over_18` |
| bytes       | Data                  | Byte string                                     |    -    | e.g. `portrait` |
| fullDate    | String                | `full-date` (tag 1004), original text           |    -    | e.g. `"1990-01-02"` |
| dateTime    | String                | date-time (tag 0), original text                |    -    | e.g. `"2026-01-01T00:00:00Z"` |
| array       | [MdocValue]           | Array                                           |    -    | e.g. `driving_privileges` |
| map         | [String: MdocValue]   | Map with text keys                              |    -    |          |
| null        |                       | CBOR null                                       |    -    | CBOR undefined is not `.null`; it is `.unsupported` |
| unsupported |                       | A value this SDK cannot represent               |    -    | See the note below |
| asBoolean   | Bool                  | The value if the case is `.boolean`, otherwise `nil` |    O    |          |
| asText      | String                | The value if the case is `.text`, otherwise `nil`    |    O    |          |

**`unsupported`** exists so that the SDK never delivers a wrong value. The following are delivered as `.unsupported` rather than being converted:

| Received value | Reason |
|----------------|--------|
| A tag other than 0 and 1004 (or tag 0 / 1004 not wrapping text) | Removing the tag changes the meaning (e.g. a bignum would look like `.bytes`) |
| A map with a non-text key | Dropping the pair would make the value look absent |
| An integer outside the `Int64` range | Not representable |
| A floating-point number (16, 32 or 64 bit), `undefined`, or any other simple value | No case represents it. `undefined` is not turned into `.null`; it is a different value |

The original CBOR bytes of a value are not exposed.

### Usage

```swift
let ns = MdocDocTypes.mDLNameSpace
if case .fullDate(let text)? = doc.issuerSignedElements[ns]?["birth_date"] {
    showBirthDate(text)              // "1990-01-02", unparsed
}
let isAdult = doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true
```

<br>

# Engagement and Transmission

## 1. EngagementPayload

### Description

`Device engagement. The value the mdoc app shows as a QR code, or the value the reader app obtains by scanning it.`

The internal `DeviceEngagementBytes` and `Handover` bytes are not exposed. They are used only to build the `SessionTranscript`, and modifying them would break verification.

### Declaration

```swift
// Declaration in Swift
public struct EngagementPayload {
    public let qrString: String?
    public let technology: EngagementTechnology
    public let transmissions: [TransmissionTechnology]

    public static func parse(qrString: String) throws -> EngagementPayload
}
```

### Property

| Name          | Type                     | Description                                            | **M/O** | **Note** |
|---------------|--------------------------|--------------------------------------------------------|---------|----------|
| qrString      | String                   | `"mdoc:" + base64url(DeviceEngagement)`                |    O    | Non-nil only for QR engagement |
| technology    | EngagementTechnology     | How engagement took place                              |    M    | [EngagementTechnology](#2-engagementtechnology) |
| transmissions | [TransmissionTechnology] | Data retrieval technologies advertised by the peer     |    M    | [TransmissionTechnology](#3-transmissiontechnology). For NFC engagement, the carriers in Handover Select |

### Method

| Name             | Description                                        | **Note** |
|------------------|----------------------------------------------------|----------|
| parse(qrString:) | Parses a scanned QR string into an `EngagementPayload` | Throws `MdocProximityError.malformedEngagement` if the string does not start with `mdoc:` or is not valid base64url. Rendering and camera handling are up to the app |

`transmissions` lists only GATT modes for BLE. Whether the peer offered an L2CAP PSM is not part of this value; L2CAP is negotiated by the SDK on top of the selected mode. If the peer advertises one BLE method with both modes, both modes are listed. Wi-Fi Aware is listed when advertised, even though iOS cannot use it (see [4.1](#41-unsupported-vs-configuration-required)).

### Usage

```swift
let payload = try EngagementPayload.parse(qrString: scannedText)
```

<br>

## 2. EngagementTechnology

### Description

`Device engagement transmission technology (ISO/IEC 18013-5 8.2.2).`

This is a different axis from the data retrieval technology. The engagement channel determines the `Handover` element of the session transcript.

### Declaration

```swift
// Declaration in Swift
public enum EngagementTechnology: Equatable {
    case qr
    case nfcStaticHandover
    case nfcNegotiatedHandover

    public var isNFC: Bool { get }
}
```

### Property

| Name                  | Type | Description                                   | **M/O** | **Note** |
|-----------------------|------|-----------------------------------------------|---------|----------|
| qr                    |      | QR code engagement                            |    -    |          |
| nfcStaticHandover     |      | NFC static handover                           |    -    |          |
| nfcNegotiatedHandover |      | NFC negotiated handover (TNEP). The reader writes a Handover Request and the mdoc replies with one carrier in a Handover Select |    -    |          |
| isNFC                 | Bool | `true` for the two NFC cases                  |    M    |          |

<br>

## 3. TransmissionTechnology

### Description

`Data retrieval transmission technology (ISO/IEC 18013-5 8.3.3).`

### Declaration

```swift
// Declaration in Swift
public enum TransmissionTechnology: Equatable {
    case ble(BleMode)
    case nfc
    case wifiAware
}
```

### Property

| Name      | Type    | Description                        | **M/O** | **Note** |
|-----------|---------|------------------------------------|---------|----------|
| ble       | BleMode | BLE with the given GATT mode       |    -    | [BleMode](#4-blemode) |
| nfc       |         | NFC                                |    -    |          |
| wifiAware |         | Wi-Fi Aware                        |    -    | Not available on iOS. The capability query reports `.unsupported(reason: .vendorPolicy)`, and a peer that advertises only Wi-Fi Aware cannot be connected (`wifiAwareUnavailable(reason: .vendorPolicy)`) |

The case exists on iOS so that the reader can read a peer's advertisement and report why it cannot be used, using the same vocabulary as the capability query and the errors.

<br>

## 4. BleMode

### Description

`BLE GATT mode (ISO/IEC 18013-5 8.3.3.1.1).`

L2CAP is not a mode. It is an upgrade negotiated on top of a GATT mode when the peer exposes a PSM, using the same connection setup and service. It is enabled with the `l2capUpgrade` setting on each side (see [MdocDeviceAPI](MdocDeviceAPI.md) and [MdocReaderAPI](MdocReaderAPI.md)). If L2CAP cannot be established, the SDK falls back to GATT in the same mode.

### Declaration

```swift
// Declaration in Swift
public enum BleMode: Equatable {
    case peripheralServer, centralClient
}
```

### Property

| Name             | Type | Description                                         | **M/O** | **Note** |
|------------------|------|-----------------------------------------------------|---------|----------|
| peripheralServer |      | mdoc peripheral server mode. The mdoc is the GATT server |    -    |          |
| centralClient    |      | mdoc central client mode. The mdoc reader is the GATT server |    -    |          |

<br>

# Verification Results

The reader app receives these types from `MdocReaderSession.request(_:at:)` (see [MdocReaderAPI](MdocReaderAPI.md)). Verification is not reduced to a single boolean; each check is exposed separately, and [verdict](#7-verificationverdict) summarizes them.

## 1. VerifiedResponse

### Description

`Verified DeviceResponse.`

### Declaration

```swift
// Declaration in Swift
public struct VerifiedResponse {
    public let documents: [VerifiedDocument]
    public let documentErrors: [DocType: Int64]
    public let status: UInt64
}
```

### Property

| Name           | Type               | Description                                  | **M/O** | **Note** |
|----------------|--------------------|----------------------------------------------|---------|----------|
| documents      | [VerifiedDocument] | Returned documents                           |    M    | [VerifiedDocument](#2-verifieddocument). May be empty even when `status` is 0. See [10.5](#105-partial-responses-and-notreturned) |
| documentErrors | [DocType: Int64]   | Document-level errors, by document type      |    M    | `ErrorCode` is a signed integer |
| status         | UInt64             | `DeviceResponse.status`                      |    M    | If not 0, no documents are returned |

`documents` is never optional. A response with no documents arrives as an empty array.

<br>

## 2. VerifiedDocument

### Description

`One verified document, with each verification result exposed separately.`

### Declaration

```swift
// Declaration in Swift
public struct VerifiedDocument {
    public let docType: DocType

    public let issuerSignedElements: [NameSpace: [DataElementIdentifier: MdocValue]]
    public let deviceSignedElements: [NameSpace: [DataElementIdentifier: MdocValue]]
    public var allElements: [NameSpace: [DataElementIdentifier: MdocValue]] { get }

    public let issuerDataAuth: IssuerDataAuthResult
    public let mdocAuth: MdocAuthResult
    public let digests: DigestCheckResult?
    public let warnings: [DocumentWarning]

    public let notReturned: [NameSpace: [DataElementIdentifier]]
    public let elementErrors: [NameSpace: [DataElementIdentifier: Int64]]

    public var verdict: VerificationVerdict { get }
    public var retainable: [NameSpace: [DataElementIdentifier]] { get }

    public func provenance(_ nameSpace: NameSpace,
                           _ id: DataElementIdentifier) -> ElementProvenance?
    public func retainableElements(requiringValidDigest: Bool = true)
        -> [NameSpace: [DataElementIdentifier: MdocValue]]
}
```

### Property

| Name                 | Type                                              | Description                                         | **M/O** | **Note** |
|----------------------|---------------------------------------------------|-----------------------------------------------------|---------|----------|
| docType              | DocType                                           | Document type                                       |    M    |          |
| issuerSignedElements | [NameSpace: [DataElementIdentifier: MdocValue]]   | Elements returned in `IssuerSigned`. Covered by the issuer signature through the MSO digests |    M    | Use only these for identity and entitlement decisions. See [10.1](#101-element-provenance) |
| deviceSignedElements | [NameSpace: [DataElementIdentifier: MdocValue]]   | Elements returned in `DeviceSigned`. Covered only by mdoc authentication |    M    | **Not vouched for by the issuer** |
| allElements          | [NameSpace: [DataElementIdentifier: MdocValue]]   | Merged convenience view of the two above            |    M    | If the same identifier is in both, the issuer-signed value is kept |
| issuerDataAuth       | IssuerDataAuthResult                              | Issuer data authentication result                   |    M    | [IssuerDataAuthResult](#3-issuerdataauthresult) |
| mdocAuth             | MdocAuthResult                                    | mdoc authentication result                          |    M    | [MdocAuthResult](#5-mdocauthresult) |
| digests              | DigestCheckResult                                 | Digest comparison result                            |    O    | [DigestCheckResult](#6-digestcheckresult). `nil` if the MSO could not be obtained, i.e. no comparison was made |
| warnings             | [DocumentWarning]                                 | Observations about the response. Not errors         |    M    | [DocumentWarning](#9-documentwarning). Sorted by namespace, then identifier |
| notReturned          | [NameSpace: [DataElementIdentifier]]              | Requested but not returned elements                 |    M    | Computed as request minus response. See [10.5](#105-partial-responses-and-notreturned) |
| elementErrors        | [NameSpace: [DataElementIdentifier: Int64]]       | Element-level `ErrorCode` values sent by the mdoc   |    M    | Informational. No reason is carried |
| verdict              | VerificationVerdict                               | Summary of the verification results                 |    M    | [VerificationVerdict](#7-verificationverdict). Does not include whether the request was satisfied |
| retainable           | [NameSpace: [DataElementIdentifier]]              | Identifiers requested with `intentToRetain = true` in this request |    M    | Identifiers only, no values. See [10.4](#104-retention-and-intenttoretain) |

### Method

| Name                                     | Description                                         | **Note** |
|------------------------------------------|-----------------------------------------------------|----------|
| provenance(_:_:)                         | Returns whose signature covers the element          | [ElementProvenance](#8-elementprovenance). `.issuerSigned` if present in issuer-signed elements, `.deviceSigned` if present only in device-signed elements, otherwise `nil` |
| retainableElements(requiringValidDigest:) | Returns only the values the reader app may retain  | See [10.4](#104-retention-and-intenttoretain) |

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
for doc in response.documents {
    guard doc.verdict == .valid else { continue }
    let ns = MdocDocTypes.mDLNameSpace
    let ageOK = doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true
}
```

<br>

## 3. IssuerDataAuthResult

### Description

`Result of issuer data authentication (ISO/IEC 18013-5 9.1.2). Combines the cryptographic checks with the trust decision.`

### Declaration

```swift
// Declaration in Swift
public struct IssuerDataAuthResult {
    public let signatureValid: Bool
    public let verificationSkipped: Bool
    public let trust: TrustVerdict
    public let source: TrustSource
    public let docTypeChecked: Bool
    public let docTypeMatches: Bool
    public let validity: ValidityCheck?
}
```

### Property

| Name                | Type          | Description                                            | **M/O** | **Note** |
|---------------------|---------------|--------------------------------------------------------|---------|----------|
| signatureValid      | Bool          | Whether the `issuerAuth` signature was verified with the issuer public key |    M    | `false` when verification was skipped, when the signature could not be checked (no public key was obtained — `trust` is `.unknown` or `.untrusted` — or the algorithm is not ES256 or the key is not P-256), or when it was checked and did not match. Only the last makes `verdict` `.invalid`; the others leave it at most `.unverified` |
| verificationSkipped | Bool          | Whether issuer signature verification was skipped      |    M    | `true` when the reader configuration's `skipIssuerAuth` is `true`. "Not checked" and "checked and failed" are kept apart |
| trust               | TrustVerdict  | Trust decision for the issuer                          |    M    | [TrustVerdict](MdocTrust.md#1-trustverdict) |
| source              | TrustSource   | Where the trust decision came from                     |    M    | [TrustSource](MdocTrust.md#3-trustsource) |
| docTypeChecked      | Bool          | Whether the MSO was read and its `docType` compared    |    M    | If `false`, `docTypeMatches` is meaningless |
| docTypeMatches      | Bool          | Whether the MSO `docType` equals the document's `docType` |    M    | Always `false` when `docTypeChecked` is `false` |
| validity            | ValidityCheck | MSO validity information and its evaluation            |    O    | [ValidityCheck](#4-validitycheck). `nil` if the MSO could not be obtained |

When the MSO cannot be obtained (no payload in `issuerAuth`, or `MobileSecurityObjectBytes` cannot be parsed), `validity` and `digests` are `nil`, and `signatureValid` and `docTypeChecked` are `false`. The two causes are not distinguished.

When verification is skipped, the issuer key is not resolved and no lookup is made; `trust` is `.unknown` and `source` is `.none`. MSO parsing, the `docType` comparison, the validity check, the digest comparison and mdoc authentication are still performed.

<br>

## 4. ValidityCheck

### Description

`The MSO ValidityInfo (ISO/IEC 18013-5 9.1.2.4) and its evaluation.`

The evaluation time is the `at:` value the app passed to the request; it is not repeated here. `expectedUpdate` is not included.

### Declaration

```swift
// Declaration in Swift
public struct ValidityCheck: Equatable {
    public let signed: Date
    public let validFrom: Date
    public let validUntil: Date
    public let isCurrentlyValid: Bool
}
```

### Property

| Name             | Type | Description                                           | **M/O** | **Note** |
|------------------|------|-------------------------------------------------------|---------|----------|
| signed           | Date | Time the MSO was signed                               |    M    |          |
| validFrom        | Date | Start of validity                                     |    M    |          |
| validUntil       | Date | End of validity                                       |    M    |          |
| isCurrentlyValid | Bool | `signed <= at && validFrom <= at && at <= validUntil` |    M    | `at` is the time passed to the request. A `signed` time later than `at` also fails |

<br>

## 5. MdocAuthResult

### Description

`Result of mdoc authentication (ISO/IEC 18013-5 9.1.3).`

### Declaration

```swift
// Declaration in Swift
public struct MdocAuthResult: Equatable {
    public enum Method: Equatable { case ecdsa, mac }
    public let method: Method
    public let valid: Bool
    public let boundToIssuerDeviceKey: Bool
}
```

### Property

| Name                   | Type   | Description                                         | **M/O** | **Note** |
|------------------------|--------|-----------------------------------------------------|---------|----------|
| method                 | Method | `DeviceAuth` method used by the mdoc                |    M    | `.ecdsa` (deviceSignature) or `.mac` (deviceMac) |
| valid                  | Bool   | Whether mdoc authentication succeeded               |    M    |          |
| boundToIssuerDeviceKey | Bool   | Whether the check used the `deviceKey` from the MSO |    M    | `false` means the binding to the issuer-signed device key is broken |

<br>

## 6. DigestCheckResult

### Description

`Per-element digest comparison of IssuerSigned items against the MSO valueDigests.`

Every received `IssuerSignedItem` is compared, whether or not its meaning is known. Lookup is by the pair (namespace, digestID). The algorithm follows the MSO `digestAlgorithm` (`SHA-256`, `SHA-384`, `SHA-512`); any other algorithm makes every entry a mismatch. Device-signed elements have no digest and do not appear here.

### Declaration

```swift
// Declaration in Swift
public struct DigestCheckResult: Equatable {
    public let matches: [NameSpace: [DataElementIdentifier: Bool]]
    public var allMatch: Bool { get }
}
```

### Property

| Name     | Type                                        | Description                                  | **M/O** | **Note** |
|----------|---------------------------------------------|----------------------------------------------|---------|----------|
| matches  | [NameSpace: [DataElementIdentifier: Bool]]  | Whether each received issuer-signed element matched its digest |    M    | The value of an element marked `false` cannot be trusted |
| allMatch | Bool                                        | Whether every received element matched       |    M    | `true` when there are no elements to compare. When no comparison could be made, `VerifiedDocument.digests` itself is `nil` |

**Display rule**: do not display the value of an issuer-signed element unless `digests?.matches[ns]?[id] == true`. Both `false` (mismatch) and `nil` (not compared) mean the issuer has not vouched for the value. The SDK does not remove such values; it only reports the result.

<br>

## 7. VerificationVerdict

### Description

`Summary of the verification results of a document.`

### Declaration

```swift
// Declaration in Swift
public enum VerificationVerdict: Equatable {
    case valid
    case invalid
    case unverified
}
```

### Property

| Name       | Type | Description                                      | **M/O** | **Note** |
|------------|------|--------------------------------------------------|---------|----------|
| valid      |      | All checks passed and the issuer is trusted      |    -    |          |
| invalid    |      | A check failed                                   |    -    |          |
| unverified |      | No check failed, but the issuer signature could not be checked or the issuer could not be judged trusted |    -    |          |

`VerifiedDocument.verdict` is computed from the other fields as follows.

| Condition | verdict |
|-----------|---------|
| `issuerDataAuth.verificationSkipped == true`, and `docTypeMatches`, `digests?.allMatch == true`, `mdocAuth.valid` and `validity?.isCurrentlyValid == true` all hold | `.unverified` |
| `issuerDataAuth.verificationSkipped == true`, and any of the above fails | `.invalid` |
| Not skipped, and `signatureValid`, `docTypeMatches`, `digests?.allMatch == true`, `mdocAuth.valid` and `validity?.isCurrentlyValid == true` all hold, and `trust == .trusted` | `.valid` |
| Not skipped, all of the above checks hold, and `trust` is not `.trusted` | `.unverified` |
| Not skipped, the issuer signature could not be checked (no public key, an algorithm other than ES256, or a key not on P-256), and `docTypeMatches`, `digests?.allMatch == true`, `mdocAuth.valid` and `validity?.isCurrentlyValid == true` all hold | `.unverified` |
| Not skipped, and the issuer signature was checked and did not match, or any other check fails | `.invalid` |

- When issuer signature verification is skipped, `verdict` is never `.valid`. The `deviceKey` arrives inside the response, so without the issuer signature the SDK cannot tell whose key it is, and passing mdoc authentication does not establish identity.
- `signatureValid` requires an issuer public key from the trust evaluator during the request. With [DIDIssuerKeyResolver](MdocTrust.md#2-didissuerkeyresolver), a key is returned only for an issuer in the trust anchor list whose key was resolved. An issuer outside the list, or one whose key could not be resolved, therefore yields `.unverified`, not `.invalid`: the signature was not checked. `.invalid` means it was checked and did not match. A later `resolveTrust(for:using:at:)` that obtains the key checks the signature again ([MdocReaderAPI](MdocReaderAPI.md#41-resolvetrust)).
- `verdict` does not include whether the request was satisfied. See [10.5](#105-partial-responses-and-notreturned).

<br>

## 8. ElementProvenance

### Description

`Whose signature covers an element value.`

### Declaration

```swift
// Declaration in Swift
public enum ElementProvenance: Equatable {
    case issuerSigned
    case deviceSigned
}
```

### Property

| Name         | Type | Description                                      | **M/O** | **Note** |
|--------------|------|--------------------------------------------------|---------|----------|
| issuerSigned |      | Covered by the issuer signature and MSO digest   |    -    |          |
| deviceSigned |      | Covered only by mdoc authentication. Not vouched for by the issuer |    -    |          |

<br>

## 9. DocumentWarning

### Description

`An observation about the response. A warning, not an error. unrequestedElement is not a conformance violation; unauthorizedDeviceSignedElement reports an mdoc-side violation (18013-5 9.1.3.4) by removing only that element.`

### Declaration

```swift
// Declaration in Swift
public enum DocumentWarning: Equatable {
    case unrequestedElement(NameSpace, DataElementIdentifier)
    case unauthorizedDeviceSignedElement(NameSpace, DataElementIdentifier)
}
```

### Property

| Name               | Type                              | Description                                | **M/O** | **Note** |
|--------------------|-----------------------------------|--------------------------------------------|---------|----------|
| unrequestedElement | (NameSpace, DataElementIdentifier) | An element returned without being requested |    -    | The standard does not forbid this. The element has no `intentToRetain` flag, so it must not be retained and is never included in `retainable` or `retainableElements(requiringValidDigest:)` |
| unauthorizedDeviceSignedElement | (NameSpace, DataElementIdentifier) | A deviceSigned element that the MSO `keyAuthorizations` does not authorize for the `deviceKey` (ISO/IEC 18013-5 9.1.3.4) |    -    | The value is removed from `deviceSignedElements`, and if it was requested it also appears in `notReturned`. The rest of the document's verdict is unchanged |

Namespaces are not judged. Which namespaces arrived can be read from the keys of `issuerSignedElements` and `deviceSignedElements`.

<br>

## 10. Interpreting Verification Results

## 10.1. Element Provenance

ISO/IEC 18013-5 7.2 requires that any Table 5 element returned by an mDL be returned in `IssuerSignedItems`, while domestic data elements may be returned in either `IssuerSignedItems` or `DeviceSignedItems`. Not every element is vouched for by the issuer.

| Source | What it guarantees | By what |
|--------|--------------------|---------|
| `issuerSignedElements` | The issuer issued the value | MSO `valueDigests` and the `IssuerAuth` signature |
| `deviceSignedElements` | The device sent the value | mdoc authentication (`DeviceAuth`) only |

`deviceSignedElements` is not vouched for by the issuer and is not subject to digest comparison. Do not use it as a basis for identity decisions. The API therefore does not merge the two by default. `allElements` is provided for convenience, but code that makes trust decisions should read `issuerSignedElements` directly or check `provenance(_:_:)`. When `deviceSignedElements` is displayed, it should be shown as not vouched for by the issuer.

```swift
// Use only issuer-signed elements for identity and entitlement decisions
let ns = MdocDocTypes.mDLNameSpace
let ageOK = doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true

// For supplementary display, check the provenance first
if doc.provenance(ns, "domestic_note") == .deviceSigned { showAsUnverifiedNote() }
```

<br>

## 10.2. Namespace Scope

The protocol does not restrict namespaces or document types (ISO/IEC 18013-5 8.3.1). A document may contain elements from multiple namespaces, and the reverse-domain format is a recommendation, not a requirement. The restriction in 7.1 applies to what may appear inside the `org.iso.18013.5.1` namespace, not to which namespaces may be used. Domestic namespaces are defined by the issuing authority (7.2.8).

| Item | SDK behavior |
|------|--------------|
| Namespaces | Not restricted. Unknown namespaces are handled like any other, and no warning is raised |
| `MdocDocTypes` | mDL convenience constants only. Other document types use their identifiers directly |
| Values of unknown elements | Delivered as `MdocValue` when representable, otherwise `.unsupported`. Never silently changed |
| Unknown identifiers inside `org.iso.18013.5.1` | Not judged. Values are kept and verification is performed normally. No warning is raised |

The SDK is designed for mdoc documents in general, not only mDL.

<br>

## 10.3. Unknown Elements

ISO/IEC 18013-5 9.3.1 step 3 requires the digest of **every** returned `IssuerSignedItem` to be verified. The SDK therefore verifies all elements regardless of whether their meaning is known, and only then interprets the ones it can.

```text
Step 1, verification:   compare the digest of every IssuerSignedItem, known or not.
Step 2, interpretation: interpret known values; keep the rest as values (MdocValue / .unsupported).
```

Discarding unknown elements would make step 1 incomplete, and rejecting them would refuse a valid mDL that carries domestic elements. The retention rules in [10.4](#104-retention-and-intenttoretain) apply equally to unknown elements.

<br>

## 10.4. Retention and intentToRetain

ISO/IEC 18013-5 8.3.2.1.2.1 states that the mdoc verifier shall not retain any data, including digests and signatures, or derived data received from the mdoc, except for data elements for which `IntentToRetain` was set to `true` in the request. To retain means to store for longer than necessary to conduct the transaction in real time.

1. Not retaining is the rule; `true` is the exception. Unrequested elements are also covered by the prohibition.
2. `true` is an upper bound, not an obligation. The app may discard such values.
3. The prohibition covers more than values: raw `DeviceResponse` bytes, MSO digests, `IssuerAuth` and `DeviceAuth` signatures, values derived from the response (for example an age computed from `birth_date`), and in-memory caches kept beyond the transaction.
4. The protocol cannot enforce this, but a reader that retains other data does not conform to ISO/IEC 18013-5.

| Item | SDK behavior |
|------|--------------|
| Logging of raw responses | Not performed, and there is no option to enable it |
| Internal buffers | Released with the session |
| Path for retention | `retainableElements(requiringValidDigest:)` only. Storing `allElements` as is violates the rule |
| Derived values | Not produced. `age_over_NN` is delivered as received and is not computed from `birth_date` |

`retainableElements(requiringValidDigest:)` returns only elements requested with `intentToRetain = true`.

| requiringValidDigest | Result |
|----------------------|--------|
| `true` (default) | Only elements whose digest matched (`digests?.matches[ns]?[id] == true`). Device-signed elements have no digest and are excluded. If `digests` is `nil`, the result is empty |
| `false` | Also includes elements without a matching digest, including device-signed elements. The `retainable` scope is still enforced |

```swift
// The reader app stores only this result
let toStore = doc.retainableElements()
try repository.save(docType: doc.docType, elements: toStore)
```

<br>

## 10.5. Partial Responses and notReturned

A response that does not contain everything requested is not an error. The mdoc decides what to release, and the standard does not require it to report what was left out.

1. **`elementErrors` is informational.** The `errors` field is optional, and the only `ErrorCode` value (0, data not returned) carries no reason. `notReturned` is therefore computed from the request, not from the response.

    ```text
    Document level: requested docTypes minus returned docTypes  -> visible through documentErrors / missing documents
    Element level:  notReturned = elements requested for that document minus (issuer-signed ∪ device-signed)
    ```

    `notReturned` is the same whether or not `errors` was sent. An element whose value actually arrived counts as returned even if it is also listed in `errors`. If a document is missing entirely, there is no `VerifiedDocument` for it.

2. **`verdict` is not a satisfaction check.** `verdict` can be `.valid` while `notReturned` is not empty. Verification (signatures, digests) and satisfaction (whether the needed elements arrived) are separate; the reader app decides satisfaction.

    ```swift
    let ns = MdocDocTypes.mDLNameSpace
    guard doc.verdict == .valid else { return .reject }          // verification, decided by the SDK
    guard doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true else {
        return .insufficient                                     // satisfaction, decided by the app
    }
    // A portrait left in doc.notReturned does not matter for this use case
    ```

3. **`status` can be 0 with no documents.** If the mdoc does not hold the requested document type, it can respond with `status` 0 and only `documentErrors`. The session completed normally. An mdoc may instead end the session with status 20, which arrives as `MdocProximityError.terminatedByPeer(status: 20)`. The standard allows both, so the reader app should handle both.

    ```swift
    let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
    if response.documents.isEmpty {
        // status 0 + documentErrors: not held, or not released by the holder. No reason is given
        showNoDocument(Array(response.documentErrors.keys))
    }
    ```

    Status 10 (general error) also carries no reason. Do not infer the cause from an empty `documents` alone.

<br>

# Capabilities

The SDK does not request permissions. It only reports state, and the app decides when to request permissions.

## 1. MdocCapabilities

### Description

`Device capability for each role and transmission technology.`

### Declaration

```swift
// Declaration in Swift
public struct MdocCapabilities: Equatable {
    public let mdoc: RoleCapabilities
    public let mdocReader: RoleCapabilities

    public static func current() -> MdocCapabilities
}
```

### Property

| Name       | Type             | Description                       | **M/O** | **Note** |
|------------|------------------|-----------------------------------|---------|----------|
| mdoc       | RoleCapabilities | Capabilities for the mdoc (holder) role |    M    | [RoleCapabilities](#2-rolecapabilities) |
| mdocReader | RoleCapabilities | Capabilities for the mdoc reader role |    M    | [RoleCapabilities](#2-rolecapabilities) |

### Method

| Name      | Description                                    | **Note** |
|-----------|------------------------------------------------|----------|
| current() | Queries the current capabilities at run time   | Synchronous. Does not request any permission. See [4.3](#43-bluetooth-query-limits) |

### Usage

```swift
let caps = MdocCapabilities.current()
if case .configurationRequired(let action) = caps.mdocReader.ble {
    guideUser(action)
}
```

<br>

## 2. RoleCapabilities

### Description

`Capability of each transmission technology for one role.`

### Declaration

```swift
// Declaration in Swift
public struct RoleCapabilities: Equatable {
    public let ble: TransportCapability
    public let nfc: TransportCapability
    public let wifiAware: TransportCapability
}
```

### Property

| Name      | Type                | Description         | **M/O** | **Note** |
|-----------|---------------------|---------------------|---------|----------|
| ble       | TransportCapability | BLE                 |    M    | [TransportCapability](#3-transportcapability). Both roles share the same radio and permission |
| nfc       | TransportCapability | NFC                 |    M    | The two roles report different values. See [4.2](#42-nfc-on-ios) |
| wifiAware | TransportCapability | Wi-Fi Aware         |    M    | Always `.unsupported(reason: .vendorPolicy)` on iOS |

<br>

## 3. TransportCapability

### Description

`Capability of one transmission technology. Reports facts only; decisions are left to the app.`

### Declaration

```swift
// Declaration in Swift
public enum TransportCapability: Equatable {
    case supported
    case unsupported(reason: CapabilityReason)
    case configurationRequired(action: RequiredAction)
}
```

### Property

| Name                  | Type             | Description                                  | **M/O** | **Note** |
|-----------------------|------------------|----------------------------------------------|---------|----------|
| supported             |                  | Usable                                       |    -    |          |
| unsupported           | CapabilityReason | Not usable, and the app cannot fix it        |    -    | [CapabilityReason](MdocProximityError.md#capabilityreason) |
| configurationRequired | RequiredAction   | Not usable now, but the app or user can fix it |    -    | [RequiredAction](MdocProximityError.md#requiredaction) |

`CapabilityReason` and `RequiredAction` are the same values carried by `MdocProximityError.bleUnavailable` / `nfcUnavailable` / `wifiAwareUnavailable` and `configurationRequired`.

<br>

## 4. Interpreting Capabilities

## 4.1. Unsupported vs Configuration Required

The single criterion is whether the app can fix it. `unsupported` cannot be fixed by the app; `configurationRequired` can.

| Value | Case on iOS | What the app does |
|-------|-------------|-------------------|
| `unsupported(.noHardware)` | No NFC reader radio (for example iPad), or no Bluetooth support | Offer an alternative transmission |
| `unsupported(.vendorPolicy)` | mdoc NFC (card emulation), Wi-Fi Aware in both roles | Offer an alternative (QR + BLE) |
| `configurationRequired(.enableBluetooth)` | The user turned Bluetooth off | Guide the user to settings |
| `configurationRequired(.grantPermission("bluetooth"))` | Bluetooth permission denied or restricted | Guide the user to grant permission |
| `configurationRequired(.addEntitlement(...))` | mdoc reader NFC without the required `select-identifiers` registration | Inform the developer of the integration setting |

`.vendorPolicy` must not be confused with `.osVersion`. The former is a matter of policy or API surface that does not change with the OS version; the latter changes when the device or OS changes. `.vendorPolicy` does not mean "permanently impossible"; it states the current fact only.

<br>

## 4.2. NFC on iOS

`mdoc.nfc` and `mdocReader.nfc` report different values and must not be judged together.

```swift
let caps = MdocCapabilities.current()

caps.mdoc.nfc        // Always .unsupported(reason: .vendorPolicy)
                     // Even when an authorized app injects card emulation into an mdoc session,
                     // this static query does not know about it and the value does not change.

caps.mdocReader.nfc  // No NFC reader radio                       -> .unsupported(reason: .noHardware)
                     // select-identifiers registered correctly   -> .supported
                     // Missing, or in the wrong order            -> .configurationRequired(action:
                     //     .addEntitlement("com.apple.developer.nfc.readersession.iso7816.select-identifiers"))
```

The reader NFC check reads `com.apple.developer.nfc.readersession.iso7816.select-identifiers` from the app's `Info.plist`. The list must start with `D2760000850101` (NDEF Tag Application) and must contain `A0000002480400` (mdoc data retrieval). The order matters: the system tries the identifiers in order and stops at the first successful SELECT.

Entitlements belong to the integrating app, not to the SDK. An app that does not enable reader NFC still links, passes review and runs, and works with QR + BLE. `.addEntitlement` is guidance, not a block.

<br>

## 4.3. Bluetooth Query Limits

`current()` is synchronous and never requests permission, which leads to the following limits.

- If Bluetooth permission is **not yet determined**, the query answers `.supported`. Determining it requires creating a Bluetooth manager, which makes the OS show the permission prompt; that timing is left to the app (the first `start()` or `connect()`). Denied or restricted permission is readable without a manager and is reported immediately as `.configurationRequired(action: .grantPermission("bluetooth"))`.
- The Bluetooth **power state arrives asynchronously**. The first query after permission is granted may not know the state yet and answers `.supported`; later queries reflect a powered-off radio as `.configurationRequired(action: .enableBluetooth)`. Unknown state is not reported as unavailable. If the state was not known, the same value arrives later as a session error. In every case the app sees the same value.
- The SDK does not show the iOS system alert asking to turn Bluetooth on. A powered-off radio is reported only through the values above; whether and how to guide the user is up to the app. The permission prompt shown by the OS when Bluetooth is first used is separate and cannot be suppressed by the SDK.
