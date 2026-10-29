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

iOS MdocTrust API
==

- Subject: MdocTrust
- Writer: JooHyun Park
- Date: 2026-10-12
- Version: v1.0.0

| Version          | Date       | History                 |
| ---------------- | ---------- | ------------------------|
| v1.0.0           | 2026-10-12 | Initial                 |


<div style="page-break-after: always;"></div>


# Table of Contents
- [Overview](#overview)
- [APIs](#api-list)
    - [1. TrustEvaluatorProtocol](#1-trustevaluatorprotocol)
        - [1.1. evaluate](#11-evaluate)
    - [2. DIDIssuerKeyResolver](#2-didissuerkeyresolver)
        - [2.1. init](#21-init)
        - [2.2. evaluate](#22-evaluate)
- [Data Models](#data-models)
    - [1. COSEHeaderSummary](#1-coseheadersummary)
    - [2. IssuerKeyResolution](#2-issuerkeyresolution)
- [Enumerators](#enumerators)
    - [1. TrustVerdict](#1-trustverdict)
    - [2. TrustPurpose](#2-trustpurpose)
    - [3. TrustSource](#3-trustsource)
- [Trust Rules](#trust-rules)
    - [1. Trust Anchors Are Required](#1-trust-anchors-are-required)
    - [2. The Resolver Returns a Public Key, Not a Document](#2-the-resolver-returns-a-public-key-not-a-document)
    - [3. Resolving Trust After the Session](#3-resolving-trust-after-the-session)

<br>

# Overview

The reader app verifies the issuer of each received document (issuer data authentication, ISO/IEC 18013-5 9.1.2). The verification key is not carried in the response; `issuerAuth` carries only a `kid` that points to the key. The trust path is DID based: the `kid` is a DID URL, and the reader app supplies the issuer public key.

| Item | Description |
|------|-------------|
| Import | `import MdocReader` (SPM) or `import MdocProximitySDK` (XCFramework) |
| Injection | A `TrustEvaluatorProtocol` instance is passed to `MdocReaderSession` (see [MdocReaderAPI](MdocReaderAPI.md)) |
| Default implementation | [DIDIssuerKeyResolver](#2-didissuerkeyresolver) |
| Result | Reflected in `VerifiedDocument.issuerDataAuth` and `verdict` (see [DataModel](DataModel.md#3-issuerdataauthresult)) |

Issuer signature verification is controlled by the reader configuration's `skipIssuerAuth` (see [MdocReaderAPI](MdocReaderAPI.md)). When it is skipped, the trust evaluator is not called.

<br>

# API List

## 1. TrustEvaluatorProtocol

### Description

`Issuer trust evaluation injected into the reader session.`

The SDK extracts the needed COSE_Sign1 header values into a [COSEHeaderSummary](#1-coseheadersummary) and passes it to the evaluator. The app never handles the raw COSE or CBOR bytes. The app may implement this protocol itself, or use the default implementation [DIDIssuerKeyResolver](#2-didissuerkeyresolver).

### Declaration

```swift
// Declaration in Swift
public protocol TrustEvaluatorProtocol: AnyObject {
    func evaluate(header: COSEHeaderSummary,
                  purpose: TrustPurpose,
                  at date: Date) async -> IssuerKeyResolution
}
```

<br>

## 1.1. evaluate

### Description

`Resolves the issuer public key and the trust decision for an issuerAuth header.`

### Declaration

```swift
func evaluate(header: COSEHeaderSummary,
              purpose: TrustPurpose,
              at date: Date) async -> IssuerKeyResolution
```

### Parameters

| Name    | Type              | Description                                 | **M/O** | **Note** |
|---------|-------------------|---------------------------------------------|---------|----------|
| header  | COSEHeaderSummary | Header values of `issuerAuth`               | M       | [COSEHeaderSummary](#1-coseheadersummary) |
| purpose | TrustPurpose      | Purpose of the evaluation                   | M       | [TrustPurpose](#2-trustpurpose). The session passes `.issuerDataAuthentication` |
| date    | Date              | Evaluation time                             | M       | The `at:` value the app passed to the session |

### Returns

| Type                | Description                                       | **M/O** | **Note** |
|---------------------|---------------------------------------------------|---------|----------|
| IssuerKeyResolution | Issuer public key, trust decision and its source  | M       | [IssuerKeyResolution](#2-issuerkeyresolution) |

The method does not throw. Failure to resolve is expressed in the returned value (for example `trust: .unknown`). The issuer signature is verified only when `publicKey` is returned; without a key the signature cannot be checked, so `signatureValid` is `false` and the document's `verdict` is at most `.unverified`, not `.invalid`. `.invalid` means the signature was checked and did not match.

### Usage

```swift
final class MyTrustEvaluator: TrustEvaluatorProtocol {
    func evaluate(header: COSEHeaderSummary,
                  purpose: TrustPurpose,
                  at date: Date) async -> IssuerKeyResolution {
        guard let kid = header.kid, let key = keyStore.publicKey(forKid: kid) else {
            return .notResolved
        }
        return IssuerKeyResolution(publicKey: key, trust: .trusted, source: .did(method: "omn"))
    }
}
```

<br>

## 2. DIDIssuerKeyResolver

### Description

`Default TrustEvaluatorProtocol implementation. Maps the issuerAuth kid (a DID URL) to a verification key.`

The trust anchor list `trustedIssuers` is required. A DID that is not in the list is not resolved and is reported as `.untrusted`. The resolver does not store the list; it keeps the injected array in memory and offers no way to change it. To change the list, create a new resolver. See [Trust Rules](#trust-rules).

### Declaration

```swift
// Declaration in Swift
public final class DIDIssuerKeyResolver: TrustEvaluatorProtocol {
    public init(trustedIssuers: [String],
                resolve: @escaping (_ did: String, _ versionId: String?) async throws -> Data)

    public func evaluate(header: COSEHeaderSummary,
                         purpose: TrustPurpose,
                         at date: Date) async -> IssuerKeyResolution
}
```

<br>

## 2.1. init

### Description

`Creates a resolver with the trust anchor list and the key resolution closure.`

### Declaration

```swift
public init(trustedIssuers: [String],
            resolve: @escaping (_ did: String, _ versionId: String?) async throws -> Data)
```

### Parameters

| Name           | Type                                                   | Description                         | **M/O** | **Note** |
|----------------|--------------------------------------------------------|-------------------------------------|---------|----------|
| trustedIssuers | [String]                                               | Trusted issuer DIDs (DID without query or fragment) | M       | An empty list rejects every issuer |
| resolve        | (_ did: String, _ versionId: String?) async throws -> Data | Returns the issuer **public key** for the DID and version | M       | SEC1 uncompressed point (P-256). Not a DID Document. See [2. The Resolver Returns a Public Key](#2-the-resolver-returns-a-public-key-not-a-document) |

`resolve` is called only for an issuer in `trustedIssuers`. `did` is the DID with query and fragment removed, and `versionId` is the `versionId` query parameter of the `kid`, or `nil` if absent.

### Returns

| Type                 | Description            | **M/O** | **Note** |
|----------------------|------------------------|---------|----------|
| DIDIssuerKeyResolver | Resolver instance      | M       |          |

### Usage

```swift
let resolver = DIDIssuerKeyResolver(
    trustedIssuers: verifiedIssuerList.dids,          // DIDs from a list the app has verified
    resolve: { did, versionId in
        // Look up the stored DID Document, select the verification method that matches
        // the kid fragment, and decode it to an uncompressed P-256 point.
        try await didKeyStore.assertionKey(did: did, versionId: versionId)
    })
```

<br>

## 2.2. evaluate

### Description

`Evaluates the issuerAuth kid against the trust anchor list and resolves the public key.`

### Declaration

```swift
public func evaluate(header: COSEHeaderSummary,
                     purpose: TrustPurpose,
                     at date: Date) async -> IssuerKeyResolution
```

### Parameters

| Name    | Type              | Description                       | **M/O** | **Note** |
|---------|-------------------|-----------------------------------|---------|----------|
| header  | COSEHeaderSummary | Header values of `issuerAuth`     | M       | Only `kid` is used |
| purpose | TrustPurpose      | Purpose of the evaluation         | M       | Not used by this implementation |
| date    | Date              | Evaluation time                   | M       | Not used by this implementation |

### Returns

| Condition | publicKey | trust | source |
|-----------|-----------|-------|--------|
| `kid` is absent or does not start with `did:` | `nil` | `.untrusted(reason: "kid is not a DID URL")` | `.none` |
| DID is not in `trustedIssuers` (including an empty list) | `nil` | `.untrusted(reason: "issuer not in trustedIssuers")` | `.did(method:)` |
| `resolve` returned a key | the key | `.trusted` | `.did(method:)` |
| `resolve` threw an error | `nil` | `.unknown` | `.did(method:)` |

`method` is the DID method, for example `"omn"` for `did:omn:issuer`. An `issuerAuth` that carries only `x5chain` has no DID URL `kid` and is reported as `.untrusted`. This is a decision, not a failure; the element values are still delivered to the app.

The order of evaluation is: parse `kid`, extract the DID, compare with `trustedIssuers`, and only if it matches, call `resolve`. No request is made for an issuer that will not be trusted.

### Usage

```swift
var configuration = MdocReaderConfiguration()
configuration.skipIssuerAuth = false              // the default skips issuer authentication
let session = MdocReaderSession(configuration: configuration, trust: resolver)
```

See [MdocReaderAPI](MdocReaderAPI.md) for the session and its configuration.

<br>

# Data Models

## 1. COSEHeaderSummary

### Description

`The issuerAuth COSE_Sign1 header values needed for trust evaluation. Created by the SDK.`

### Declaration

```swift
// Declaration in Swift
public struct COSEHeaderSummary: Equatable {
    public let kid: String?
    public let algorithm: Int
    public init(kid: String?, algorithm: Int)
}
```

### Property

| Name      | Type   | Description                                  | **M/O** | **Note** |
|-----------|--------|----------------------------------------------|---------|----------|
| kid       | String | Header label 4 (`kid`) read as UTF-8 text    |    O    | Read from the protected header first, then the unprotected header. In this ecosystem it is a DID URL, e.g. `did:omn:issuer?versionId=1#assert`. `nil` if absent |
| algorithm | Int    | Protected header label 1 (`alg`), a COSE algorithm identifier |    M    | ES256 = `-7`. `-7` if absent |

The initializer is provided for tests and custom evaluator implementations. The session creates this value; the app rarely needs to.

<br>

## 2. IssuerKeyResolution

### Description

`Result of trust evaluation: the issuer public key, the trust decision and its source.`

### Declaration

```swift
// Declaration in Swift
public struct IssuerKeyResolution {
    public let publicKey: Data?
    public let trust: TrustVerdict
    public let source: TrustSource

    public init(publicKey: Data?, trust: TrustVerdict, source: TrustSource)

    public static let notResolved: IssuerKeyResolution
}
```

### Property

| Name        | Type                | Description                                  | **M/O** | **Note** |
|-------------|---------------------|----------------------------------------------|---------|----------|
| publicKey   | Data                | Issuer public key used to verify `issuerAuth` |    O    | SEC1 uncompressed point (P-256). `nil` if not resolved |
| trust       | TrustVerdict        | Trust decision                               |    M    | [TrustVerdict](#1-trustverdict) |
| source      | TrustSource         | Source of the decision                       |    M    | [TrustSource](#3-trustsource) |
| notResolved | IssuerKeyResolution | No resolution was performed: `publicKey: nil`, `trust: .unknown`, `source: .none` |    M    | Used when issuer authentication is skipped. A custom evaluator can also return it for "not known yet" |

<br>

# Enumerators

## 1. TrustVerdict

### Description

`Trust decision for an issuer.`

### Declaration

```swift
// Declaration in Swift
public enum TrustVerdict: Equatable {
    case trusted
    case untrusted(reason: String)
    case unknown
}
```

### Property

| Name      | Type   | Description                                    | **M/O** | **Note** |
|-----------|--------|------------------------------------------------|---------|----------|
| trusted   |        | The issuer is trusted                          |    -    |          |
| untrusted | String | The issuer is not trusted, with a reason       |    -    | A decision, not a failure. Not the same as `unknown` |
| unknown   |        | Not resolved yet (lookup needed or failed, or evaluation skipped) |    -    |          |

<br>

## 2. TrustPurpose

### Description

`Purpose of the trust evaluation.`

### Declaration

```swift
// Declaration in Swift
public enum TrustPurpose {
    case issuerDataAuthentication
    case mdocReaderAuthentication
}
```

### Property

| Name                     | Type | Description                                         | **M/O** | **Note** |
|--------------------------|------|-----------------------------------------------------|---------|----------|
| issuerDataAuthentication |      | Issuer data authentication (ISO/IEC 18013-5 9.1.2)  |    -    | The only purpose the SDK passes |
| mdocReaderAuthentication |      | mdoc reader authentication (ISO/IEC 18013-5 9.1.4)  |    -    | Not used by this version of the SDK |

<br>

## 3. TrustSource

### Description

`Where a trust decision came from. The trust path is DID based; there is no X.509 source.`

### Declaration

```swift
// Declaration in Swift
public enum TrustSource: Equatable {
    case did(method: String)
    case none
}
```

### Property

| Name | Type   | Description                         | **M/O** | **Note** |
|------|--------|-------------------------------------|---------|----------|
| did  | String | Decided from a DID, with its method |    -    | e.g. `"omn"` |
| none |        | No source                           |    -    | `kid` was not a DID URL, or no evaluation was performed |

<br>

# Trust Rules

## 1. Trust Anchors Are Required

`DIDIssuerKeyResolver` requires trust anchors. If any DID were accepted, anyone able to publish a DID Document would become a trusted issuer.

| Item | DIDIssuerKeyResolver |
|------|----------------------|
| Anchor | `trustedIssuers: [String]` (issuer DIDs) |
| Update | Create a new resolver. There is no API to change the list |
| Scope of one anchor | That DID only (no delegation) |
| Growth | One entry per issuer |

**Decision rules**

1. **An issuer not in the list is `.untrusted(reason:)`**, not `.unknown`. It is not unknown; it was decided not to be trusted.
2. **An empty list rejects everything** (fail-closed). A reader app that did not fill the list must not end up trusting every issuer.
3. **Comparison uses the DID itself.** The `kid` is a DID URL such as `did:omn:issuer?versionId=1#assert`; the query (`?versionId=`) and fragment (`#assert`) are removed and `did:omn:issuer` is compared with `trustedIssuers`. Key rotation therefore does not break matching.
4. **The list check comes before any lookup.** The order is: parse `kid`, extract the DID, compare with the list, and only then call `resolve`. No external request is made for an issuer that will not be trusted.

`trustedIssuers` is a list of DIDs, not keys. Key rotation is handled inside the DID Document (`versionId`), so the list does not change when an issuer rotates its key. There is no delegation, so the list grows with the number of issuers.

The list format, signature, expiry and distribution are the reader app's responsibility. The SDK boundary is the DID array itself. The app should inject only DIDs obtained from a list whose signature and validity it has verified; the SDK cannot enforce this. If the list cannot be verified or has expired, pass an empty array, and rule 2 rejects every issuer.

To change the list, create a new resolver and inject it into the next session, or pass it to `MdocReaderSession.resolveTrust(for:using:at:)`. The resolver holds only an array and a closure, so recreating it costs nothing.

<br>

## 2. The Resolver Returns a Public Key, Not a Document

The `kid` is a pointer to the verification key.

```text
did:omn:issuer     <- which issuer          compared with trustedIssuers (rule 3)
?versionId=1       <- which version of its DID Document
#assert            <- which key in that version   <- the only key used to verify issuerAuth
```

The verification key is not carried in the response, so it must be obtained separately; without it the issuer signature cannot be verified. Because proximity transactions are expected to work offline, the reader app should distribute the latest DID Document of each issuer in advance.

The `resolve` closure maps `(did, versionId)` to a **public key**. The SDK is not involved in what the closure does.

| The app does | The SDK does |
|--------------|--------------|
| Decides where to get the DID Document: network lookup, or a stored copy | Nothing |
| Selects the `verificationMethod` matching the `kid` fragment | Nothing |
| Checks that it is an `assertionMethod` key | Nothing |
| Decodes multibase into a SEC1 uncompressed point | Nothing |
| Nothing | Verifies the `issuerAuth` COSE_Sign1 with that key |

DID Document parsing does not enter the SDK, so that the code already present in the DID SDKs is not duplicated.

**Offline use**: store the documents in advance. The closure does not need network access. The recommended form is to keep **only the latest DID Document per issuer**. Accumulating versions would let the reader keep a key that the issuer has removed from its document after a compromise, so the revocation would never take effect offline.

<br>

## 3. Resolving Trust After the Session

If the closure performs network lookups, they may not finish within the session timeout. `MdocReaderSession.resolveTrust(for:using:at:)` (see [MdocReaderAPI](MdocReaderAPI.md#41-resolvetrust)) evaluates trust for a `VerifiedDocument` and can be called after the session has ended.

Behavior of `resolveTrust(for:using:at:)`:

- If `issuerDataAuth.trust` is not `.unknown`, the document is returned unchanged.
- Otherwise the evaluator is called with the `kid` and algorithm read from the document's `issuerAuth`, and a copy is returned with `issuerDataAuth.trust` and `issuerDataAuth.source` replaced.
- The issuer signature **is** checked again with the returned key, so `signatureValid` and `verdict` can change: a document that was `.unverified` because no key was available during the request can become `.valid` or `.invalid`. Without a key, or with an algorithm other than ES256 or a key not on P-256, it stays at most `.unverified`.
- A document whose issuer authentication was skipped is returned unchanged; the evaluator is not called.

A document therefore reaches `.valid` within the session only if the public key is available during `request(_:at:)`. For an offline reader, make the issuer DID Documents available locally so that `resolve` succeeds within the session.

```swift
let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
for doc in response.documents {
    var current = doc
    if case .unknown = doc.issuerDataAuth.trust {
        current = await MdocReaderSession.resolveTrust(for: doc, using: resolver, at: Date())
    }
    render(current)
}
```
