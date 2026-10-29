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

iOS MdocReader API
==

- Subject: MdocReaderAPI
- Writer: JooHyun Park
- Date: 2026-10-12
- Version: v1.0.0

| Version | Date       | History |
| -------- | ---------- | ------- |
| v1.0.0   | 2026-10-12 | Initial |

<div style="page-break-after: always;"></div>

# Table of Contents
- [APIs](#api-list)
    - [1. MdocReaderSession](#1-mdocreadersession)
        - [1.1. init](#11-init)
        - [1.2. delegate](#12-delegate)
        - [1.3. state](#13-state)
        - [1.4. configuration](#14-configuration)
    - [2. Engagement](#2-engagement)
        - [2.1. connect](#21-connect)
        - [2.2. connectViaNFC](#22-connectvianfc)
    - [3. Request](#3-request)
        - [3.1. request](#31-request)
        - [3.2. terminate](#32-terminate)
    - [4. Trust Resolution](#4-trust-resolution)
        - [4.1. resolveTrust](#41-resolvetrust)
    - [5. Request Construction](#5-request-construction)
        - [5.1. ItemsRequestSpec.init](#51-itemsrequestspecinit)
        - [5.2. jsonData](#52-jsondata)
        - [5.3. from](#53-from)
        - [5.4. ItemsRequestPresets.ageOver](#54-itemsrequestpresetsageover)
        - [5.5. ItemsRequestPresets.identity](#55-itemsrequestpresetsidentity)
        - [5.6. ItemsRequestPresets.drivingPrivileges](#56-itemsrequestpresetsdrivingprivileges)
    - [6. Callback](#6-callback)
        - [6.1. didChangeState](#61-didchangestate)
        - [6.2. readerSessionDidConnect](#62-readersessiondidconnect)
        - [6.3. didProgress](#63-didprogress)
        - [6.4. didFailWith](#64-didfailwith)
    - [7. Capability](#7-capability)
        - [7.1. MdocCapabilities.current](#71-mdoccapabilitiescurrent)

- [Enumerators](#enumerators)
    - [1. MdocReaderState](#1-mdocreaderstate)
    - [2. TransmissionKind](#2-transmissionkind)
    - [3. BleModePreference](#3-blemodepreference)

- [Value Object](#value-object)
    - [1. MdocReaderConfiguration](#1-mdocreaderconfiguration)
    - [2. ItemsRequestSpec](#2-itemsrequestspec)
        - [2.1. Request Profile Format](#21-request-profile-format)
    - [3. MdocDocTypes](#3-mdocdoctypes)

- [Usage](#usage)
    - [1. Verification Flow](#1-verification-flow)
    - [2. NFC Tap and BLE Handover](#2-nfc-tap-and-ble-handover)
    - [3. Integration Settings](#3-integration-settings)
    - [4. Usage Rules](#4-usage-rules)


# API List

The reader-side entry point is `MdocReaderSession`. Everything from building the request to
verifying the response runs inside the SDK; the app supplies the engagement (QR or NFC tap),
the request, the time used for validity checks, and a trust evaluator.

Add the `MdocReader` product (Swift Package Manager) and `import MdocReader`, or embed the
XCFramework and `import MdocProximitySDK`. The common types and the trust types are available
through the same import.

Types defined elsewhere:

- Common and verification result types (`EngagementPayload`, `VerifiedResponse`, `VerifiedDocument`, `MdocCapabilities`, ...): [DataModel.md](DataModel.md)
- Trust configuration (`TrustEvaluatorProtocol`, `DIDIssuerKeyResolver`, trust anchors): [MdocTrust.md](MdocTrust.md)
- Errors (`MdocProximityError`): [MdocProximityError.md](MdocProximityError.md)

## 1. MdocReaderSession

## 1.1. init

### Description
`Creates a reader session.`

One session is one transaction. A session cannot be reused once it has ended; a retry uses a new
session. Creating a session reserves nothing — the one-active-session-per-process slot is taken
by `connect(to:)` / `connectViaNFC()`.

The app does not choose or inject a transport. The transport is selected at connection time from
the configuration, what the mdoc advertised, and what this device can use
(see [connect](#21-connect)).

### Declaration

```swift
public convenience init(configuration: MdocReaderConfiguration = MdocReaderConfiguration(),
                        trust: TrustEvaluatorProtocol)
```

### Parameters

| Name          | Type                    | Description                                     | **M/O** | **Note** |
|---------------|-------------------------|-------------------------------------------------|---------|----------|
| configuration | MdocReaderConfiguration | Session configuration                           | O       | [MdocReaderConfiguration](#1-mdocreaderconfiguration). Defaults to `MdocReaderConfiguration()` |
| trust         | TrustEvaluatorProtocol  | Resolves the issuer public key and decides trust | M      | [MdocTrust.md](MdocTrust.md). Not called when `skipIssuerAuth` is `true` |

### Returns

| Type              | Description            | **M/O** | **Note** |
|-------------------|------------------------|---------|----------|
| MdocReaderSession | Session in state `idle` | M      |          |

### Usage

```swift
let trust = DIDIssuerKeyResolver(trustedIssuers: trustedIssuerDIDs) { did, versionId in
    try await issuerKeyStore.publicKey(did: did, versionId: versionId)
}
var config = MdocReaderConfiguration()
config.skipIssuerAuth = false

let session = MdocReaderSession(configuration: config, trust: trust)
```

<br>

## 1.2. delegate

### Description
`Receives state changes, connection, progress and idle-link failures.`

Held weakly. Every callback is delivered on `configuration.callbackQueue` (main by default).
Set it before calling `connect(to:)` / `connectViaNFC()` so that no state change is missed.

### Declaration

```swift
public weak var delegate: MdocReaderSessionDelegate?
```

### Parameters

N/A

### Returns

| Type                       | Description           | **M/O** | **Note** |
|----------------------------|-----------------------|---------|----------|
| MdocReaderSessionDelegate? | The current delegate  | O       | [6. Callback](#6-callback) |

### Usage

```swift
session.delegate = self
```

<br>

## 1.3. state

### Description
`The current session state.`

| Current state | Allowed calls | Any other call |
| --- | --- | --- |
| `idle` | `connect(to:)`, `connectViaNFC()` | `invalidState` |
| `connecting` | `terminate()` | `invalidState` |
| `connected` | `request(_:at:)`, `terminate()` | `invalidState` |
| `awaitingResponse` | `terminate()` | `invalidState` |
| `verifying` | `terminate()` | `invalidState` |
| `completed` / `terminated` / `failed` | `terminate()` (state does not change) | `invalidState` |

Transitions:

- `connecting` → `connected` when the link is up and the session keys are derived.
- `connecting` → `failed` when the link is not ready within `connectTimeout`, or on any other
  connection error. A cancellation (the user cancels the NFC sheet, the calling `Task` is
  cancelled, or `terminate()` is called) ends in `terminated` instead.
- `connected` → `awaitingResponse` when `request(_:at:)` sends the request.
- `awaitingResponse` → `verifying` when the response arrives. The session sends the
  session-termination message (status 20) and closes the link before verifying.
- `awaitingResponse` → `failed` after `responseTimeout`, or when the mdoc ends the session (sends
  only a status code: 10, 11 or 20). In the latter case the SDK closes the link.
- `verifying` → `completed` when verification finishes. A document that fails verification
  does not make the session fail; the result is reported inside the returned
  [VerifiedResponse](DataModel.md#1-verifiedresponse).
- `connected` → `failed` when the link drops while the session is idle between connection and
  request; this is reported through `readerSession(_:didFailWith:)`.
- Any non-terminal state → `terminated` on `terminate()`. Once `terminate()` has been called,
  later link errors or a finishing verification do not change the state.

### Declaration

```swift
public private(set) var state: MdocReaderState
```

### Parameters

N/A

### Returns

| Type            | Description         | **M/O** | **Note** |
|-----------------|---------------------|---------|----------|
| MdocReaderState | Current state       | M       | [MdocReaderState](#1-mdocreaderstate) |

### Usage

```swift
if session.state == .connected {
    // the request can be sent
}
```

<br>

## 1.4. configuration

### Description
`The configuration passed at creation.`

`MdocReaderConfiguration` is a value type; changing a copy after the session is created has no
effect on the session.

### Declaration

```swift
public let configuration: MdocReaderConfiguration
```

### Parameters

N/A

### Returns

| Type                    | Description               | **M/O** | **Note** |
|-------------------------|---------------------------|---------|----------|
| MdocReaderConfiguration | Configuration of this session | M   | [MdocReaderConfiguration](#1-mdocreaderconfiguration) |

### Usage

```swift
let timeout = session.configuration.responseTimeout
```

<br>

## 2. Engagement

## 2.1. connect

### Description
`Connects to the mdoc described by an engagement obtained from a QR code.`

The transport is chosen from the intersection of three sets, in `transmissionPriority` order:

```text
candidates = configuration.transmissionPriority   (app policy: order and allow-list)
           ∩ what the mdoc advertised in the engagement
           ∩ what this device can use now          (radio, permission, entitlement)
```

- When BLE is chosen, the GATT mode follows `blePreferredMode` among the modes the mdoc
  advertised. A mode advertised without a service UUID is skipped.
- L2CAP is used only when `l2capUpgrade` is `true`; if no channel can be set up, the session
  stays on GATT in the same mode.
- When NFC is chosen from a QR engagement, the system NFC sheet is shown here and the user taps
  the mdoc.

The reader's ephemeral key (`EReaderKey`) is generated by the SDK for each transaction and its
private key never leaves the session; the app has nothing to provide for key agreement.

On success the state becomes `connected` and `readerSessionDidConnect(_:)` is called.
If the call throws, the state becomes `failed` (or `terminated` for a cancellation) and the
process slot is released. An `invalidState` error leaves the session untouched.

### Declaration

```swift
public func connect(to engagement: EngagementPayload) async throws
```

### Parameters

| Name       | Type              | Description                     | **M/O** | **Note** |
|------------|-------------------|---------------------------------|---------|----------|
| engagement | EngagementPayload | The engagement scanned from the mdoc | M  | [EngagementPayload](DataModel.md#1-engagementpayload). Obtain with `EngagementPayload.parse(qrString:)` |

### Returns

Void

### Throws

- `invalidState(current:attempted:)`: the state is not `idle`, or another session is active in this process
- `configurationRequired(action:)` / `bleUnavailable(reason:)` / `nfcUnavailable(reason:)`: no candidate is left because this device cannot use a transport that the configuration allows and the mdoc advertised — the same values that [MdocCapabilities.current](#71-mdoccapabilitiescurrent) reports
- `unsupportedTransmissionTechnology`: no candidate is left for any other reason (the configuration and the advertisement do not overlap, or the only advertised BLE modes carry no service UUID)
- `connectionFailed(detail:)`: the link could not be set up, or was not ready within `connectTimeout`
- `CancellationError`: the calling `Task` was cancelled, or the user cancelled the NFC sheet; the state becomes `terminated`

See [MdocProximityError.md](MdocProximityError.md).

### Usage

```swift
let engagement = try EngagementPayload.parse(qrString: scannedString)
try await session.connect(to: engagement)
```

<br>

## 2.2. connectViaNFC

### Description
`Reads the engagement from an NFC tap and connects in the same call.`

Reading and connecting are one call because of link continuity: if the transport selection
picks NFC, the ISO-DEP link used to read the engagement is reused for data retrieval. Splitting
the read into a separate call would close that NFC session in between.

The SDK shows the system NFC sheet and waits for a tap. A tag that is not an mdoc is not an
error — it is ignored and the sheet keeps waiting for the next tap. Whether static or negotiated
handover is used is decided by the tag:

- Static handover: the engagement is read from the tag. `technology` is `.nfcStaticHandover`.
- Negotiated handover: the reader writes a Handover Request listing the carriers it supports in
  `transmissionPriority` order (BLE, with its role following `blePreferredMode`, and NFC), and
  the mdoc selects one. `technology` is `.nfcNegotiatedHandover`.

After the engagement is read, the transport is selected exactly as in [connect](#21-connect).
If NFC is selected the tapped link is kept; otherwise it is released and the session continues
over the selected transport (for example BLE).

A user cancelling the NFC sheet is not an error: the call throws `CancellationError` and the state
becomes `terminated`, the same result as `terminate()`. The app can return to its previous
screen without showing an error.

The NFC sheet has a time limit of about 60 seconds, set by iOS; the SDK cannot change it. Keep the
NFC exchange short — if it runs past the limit (for example, while waiting for the holder's
consent), the session ends with `connectionFailed(detail:)`.

### Declaration

```swift
@discardableResult
public func connectViaNFC() async throws -> EngagementPayload
```

### Parameters

N/A

### Returns

| Type              | Description                       | **M/O** | **Note** |
|-------------------|-----------------------------------|---------|----------|
| EngagementPayload | The engagement read from the tag  | M       | [EngagementPayload](DataModel.md#1-engagementpayload). `technology` is `.nfcStaticHandover` or `.nfcNegotiatedHandover` |

### Throws

- `invalidState(current:attempted:)`: the state is not `idle`, or another session is active in this process
- `nfcUnavailable(reason:)`: this device cannot read NFC tags (`.noHardware`)
- `CancellationError`: the user cancelled the NFC sheet, the calling `Task` was cancelled, or `terminate()` was called before the tap; the state becomes `terminated`
- `connectionFailed(detail:)`: the NFC sheet ended for another reason (the system time limit ran out — see the Description, missing entitlement, system resource unavailable), or the negotiated handover found no common carrier
- `peerDisconnected`: the tag left the field while it was being read
- Any error listed for [connect](#21-connect), raised while selecting and opening the transport

See [MdocProximityError.md](MdocProximityError.md).

### Usage

```swift
do {
    let engagement = try await session.connectViaNFC()
    showConnected(engagement.technology)
} catch is CancellationError {
    // the user closed the NFC sheet — not an error
} catch {
    present(error: error)
}
```

<br>

## 3. Request

## 3.1. request

### Description
`Sends the request and returns the locally verified response.`

Allowed **once per session**, in state `connected`. Each element of `specs` becomes one
`DocRequest` of the `DeviceRequest`, so several documents can be requested at once. The same
`docType` must not appear twice: the response could not be matched back to a request.

Request format errors (an empty array, a duplicated `docType`) are detected before anything is
sent: `validationFailed` is thrown, the state stays `connected` and the single request is not
consumed, so the app can correct the input and call again. `invalidState` behaves the same way.

Flow after the request is sent:

1. The state becomes `awaitingResponse`; the session waits up to `responseTimeout` (user
   consent and transfer time included).
2. When the response arrives, the session sends the session-termination message (status 20)
   and closes the link. Verification does not need the link.
3. The state becomes `verifying`. Each document is verified: issuer signature (unless
   `skipIssuerAuth`), `docType`, validity, value digests and device authentication. With
   `skipIssuerAuth == false` the trust evaluator is called here for each document; this
   happens after the link has been closed and no timeout applies to it.
4. The state becomes `completed` and the result is returned.

A document that fails verification is not an error; its outcome is reported in the result. A
response with no documents is also a normal completion: `documents` is empty and the requested
`docType`s appear in `documentErrors`.

Any error thrown after the request has been sent moves the state to `failed`, and is not
reported again through `readerSession(_:didFailWith:)`. If `terminate()` was called while
waiting, the state stays `terminated`.

### Declaration

```swift
public func request(_ specs: [ItemsRequestSpec], at now: Date) async throws -> VerifiedResponse
```

### Parameters

| Name  | Type               | Description                                  | **M/O** | **Note** |
|-------|--------------------|----------------------------------------------|---------|----------|
| specs | [ItemsRequestSpec] | The documents and elements to request        | M       | [ItemsRequestSpec](#2-itemsrequestspec). Not empty; no duplicate `docType` |
| at    | Date               | The time used to judge `validityInfo`        | M       | The SDK never reads the clock; whether this time can be trusted is the app's decision |

### Returns

| Type             | Description                                   | **M/O** | **Note** |
|------------------|-----------------------------------------------|---------|----------|
| VerifiedResponse | Documents with their local verification results | M     | [VerifiedResponse](DataModel.md#1-verifiedresponse) |

### Throws

State unchanged:

- `invalidState(current:attempted:)`: the state is not `connected`, or a request was already made in this session
- `validationFailed(detail:)`: `specs` is empty or contains the same `docType` twice

State becomes `failed`:

- `responseTimeout`: no response within `responseTimeout`
- `terminatedByPeer(status:)`: the mdoc ended the session instead of answering. Status 20 is a session termination — a holder's refusal and a missing document both arrive this way and cannot be told apart; 10 and 11 are session encryption and CBOR errors on the mdoc side. The SDK closes the link
- `peerDisconnected`: the link dropped or failed while waiting for the response
- `sessionEncryptionFailed`, `counterMismatch`: the response could not be decrypted
- `decodeFailed(detail:)`, `validationFailed(detail:)`: the response could not be decoded (for example, the same `elementIdentifier` twice in one namespace)
- A transport error such as `connectionFailed(detail:)` or `peerDisconnected`: the request could not be sent

See [MdocProximityError.md](MdocProximityError.md).

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
for document in response.documents {
    render(document)
}
```

<br>

## 3.2. terminate

### Description
`Ends the session and releases its resources.`

- In a non-terminal state: sends the session-termination message (status 20) if a link exists,
  closes the link, and moves the state to `terminated`. In `connecting`, the pending
  `connect(to:)` / `connectViaNFC()` throws `CancellationError` and the session does not move to
  `connected` even if the link comes up afterwards. Before the NFC tap, the NFC sheet is dismissed.
  In `awaitingResponse` or `verifying`, the pending `request(_:at:)` throws `CancellationError`;
  a response that was already being verified is discarded.
- In a terminal state (`completed`, `terminated`, `failed`): releases the link and the process
  slot; the state does not change. In `failed`, if the link is still up (for example after
  `responseTimeout`), the session-termination message (status 20) is sent before the link is
  closed.

Call it in every case, including after `completed` or `failed`: the process slot is released only
by `terminate()` (or by a failed `connect`). Without it, the next session's `connect(to:)` /
`connectViaNFC()` throws `invalidState`. Calling it more than once is harmless and never affects
another session.

### Declaration

```swift
public func terminate()
```

### Parameters

N/A

### Returns

Void

### Usage

```swift
override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    session.terminate()
}
```

<br>

## 4. Trust Resolution

## 4.1. resolveTrust

### Description
`Asks the trust evaluator again for a document whose issuer trust is still unknown.`

A static function: it does not depend on a session state, and can be called after the session
has ended or has been released. Use it when a document came back with
`issuerDataAuth.trust == .unknown` — for example when the evaluator could not reach the issuer's
key during `request(_:at:)` — to retry the resolution later, outside the session.

- If `issuerDataAuth.trust` is not `.unknown`, the document is returned unchanged and the
  evaluator is not called.
- Otherwise the evaluator is called with the `kid` and algorithm read from the document's
  `issuerAuth` header (purpose `.issuerDataAuthentication`), and a copy is returned with
  `issuerDataAuth.trust` and `issuerDataAuth.source` replaced.
- The issuer signature **is** checked again with the key the evaluator returned, so
  `signatureValid` and `verdict` can change together: a document that came back `.unverified`
  can become `.valid` or `.invalid`. Without a key, or with an algorithm or curve the SDK does not
  support, the signature cannot be checked and the document stays at most `.unverified`.
  `verificationSkipped`, `validity`, `digests` and `mdocAuth` keep the values computed by
  `request(_:at:)`.
- A document whose issuer check was skipped (`skipIssuerAuth == true`) is returned unchanged and
  the evaluator is not called: a document whose signature was never checked must not become
  `.trusted`.

### Declaration

```swift
public static func resolveTrust(for document: VerifiedDocument,
                                using trust: TrustEvaluatorProtocol,
                                at now: Date) async -> VerifiedDocument
```

### Parameters

| Name     | Type                   | Description                         | **M/O** | **Note** |
|----------|------------------------|-------------------------------------|---------|----------|
| document | VerifiedDocument       | A document from `request(_:at:)`    | M       | [VerifiedDocument](DataModel.md#2-verifieddocument) |
| trust    | TrustEvaluatorProtocol | The evaluator to ask                | M       | [MdocTrust.md](MdocTrust.md) |
| at       | Date                   | The time passed to the evaluator    | M       |          |

### Returns

| Type             | Description                                       | **M/O** | **Note** |
|------------------|---------------------------------------------------|---------|----------|
| VerifiedDocument | The document with `trust`, `source`, `signatureValid` and `verdict` updated, or unchanged | M | [VerifiedDocument](DataModel.md#2-verifieddocument) |

### Usage

```swift
render(document)                                    // draw first
if case .unknown = document.issuerDataAuth.trust {
    let resolved = await MdocReaderSession.resolveTrust(for: document, using: trust, at: Date())
    updateTrustBadge(resolved.issuerDataAuth.trust)
}
```

<br>

## 5. Request Construction

## 5.1. ItemsRequestSpec.init

### Description
`Describes one requested document: its docType, and the elements to request per namespace.`

`items` maps namespace → element identifier → `intentToRetain`. Set `intentToRetain` to `true`
only for the elements the reader will keep beyond the transaction; the holder sees the
declaration. The SDK does not judge what is requested — which elements a verifier may ask for is
the deployment's policy.

### Declaration

```swift
public init(docType: DocType, items: [NameSpace: [DataElementIdentifier: Bool]])
```

### Parameters

| Name    | Type                                       | Description                                          | **M/O** | **Note** |
|---------|--------------------------------------------|------------------------------------------------------|---------|----------|
| docType | DocType                                    | The requested document type                          | M       | `String`. e.g. [MdocDocTypes.mDL](#3-mdocdoctypes) |
| items   | [NameSpace: [DataElementIdentifier: Bool]] | namespace → (element identifier → `intentToRetain`) | M       | `NameSpace` and `DataElementIdentifier` are `String` |

### Returns

| Type             | Description          | **M/O** | **Note** |
|------------------|----------------------|---------|----------|
| ItemsRequestSpec | The request entry    | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Usage

```swift
let spec = ItemsRequestSpec(docType: MdocDocTypes.mDL, items: [
    MdocDocTypes.mDLNameSpace: [
        "family_name": false,
        "given_name": false,
        "document_number": true      // the reader keeps this one
    ]
])
```

<br>

## 5.2. jsonData

### Description
`Serializes the request entry as a request profile.`

The SDK does not store request profiles; it only defines their format. Where profiles are kept
(file, settings, server distribution), and who approves them, is up to the reader app. The output
is compact JSON with keys sorted, so the same profile always produces the same bytes and can be
compared by hash or signed for distribution. See
[Request Profile Format](#21-request-profile-format).

### Declaration

```swift
func jsonData() throws -> Data
```

### Parameters

N/A

### Returns

| Type | Description                     | **M/O** | **Note** |
|------|---------------------------------|---------|----------|
| Data | UTF-8 JSON of the request profile | M     | [Request Profile Format](#21-request-profile-format) |

### Usage

```swift
let profile = try ItemsRequestPresets.identity.jsonData()
try profile.write(to: profileURL)
```

<br>

## 5.3. from

### Description
`Restores a request entry from a request profile.`

Unknown top-level keys are ignored. An unknown `version`, or a structure that does not match the
format, is rejected.

### Declaration

```swift
static func from(jsonData: Data) throws -> ItemsRequestSpec
```

### Parameters

| Name     | Type | Description                     | **M/O** | **Note** |
|----------|------|---------------------------------|---------|----------|
| jsonData | Data | A request profile               | M       | [Request Profile Format](#21-request-profile-format) |

### Returns

| Type             | Description          | **M/O** | **Note** |
|------------------|----------------------|---------|----------|
| ItemsRequestSpec | The request entry    | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Throws

- `decodeFailed(detail:)`: the JSON does not have the expected structure, or `version` is not `1`

### Usage

```swift
let saved = try ItemsRequestSpec.from(jsonData: Data(contentsOf: profileURL))
let response = try await session.request([saved], at: Date())
```

<br>

## 5.4. ItemsRequestPresets.ageOver

### Description
`Preset for age verification: age_over_NN of the mDL.`

Requests `age_over_<age>` in the `org.iso.18013.5.1` namespace of `org.iso.18013.5.1.mDL`, with
`intentToRetain` set to `false`. `portrait` is not requested by default: it is the largest
element of the mDL and biometric data. Request it explicitly when the verifier compares the
holder's face.

### Declaration

```swift
public static func ageOver(_ age: Int, includePortrait: Bool = false) -> ItemsRequestSpec
```

### Parameters

| Name            | Type | Description                          | **M/O** | **Note** |
|-----------------|------|--------------------------------------|---------|----------|
| age             | Int  | The age threshold                    | M       | Inserted as is into `age_over_<age>`; pass a two-digit value (e.g. `18`, `21`) |
| includePortrait | Bool | Also request `portrait`              | O       | Defaults to `false` |

### Returns

| Type             | Description          | **M/O** | **Note** |
|------------------|----------------------|---------|----------|
| ItemsRequestSpec | The request entry    | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
let withFace = ItemsRequestPresets.ageOver(19, includePortrait: true)
```

<br>

## 5.5. ItemsRequestPresets.identity

### Description
`Preset for identity checks: name, birth date and portrait of the mDL.`

Requests `family_name`, `given_name`, `birth_date` and `portrait`, all with `intentToRetain`
set to `false`.

### Declaration

```swift
public static var identity: ItemsRequestSpec { get }
```

### Parameters

N/A

### Returns

| Type             | Description          | **M/O** | **Note** |
|------------------|----------------------|---------|----------|
| ItemsRequestSpec | The request entry    | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.identity], at: Date())
```

<br>

## 5.6. ItemsRequestPresets.drivingPrivileges

### Description
`Preset for driving-privilege checks: document number, expiry date and driving privileges of the mDL.`

Requests `document_number`, `expiry_date` and `driving_privileges`, all with `intentToRetain`
set to `false`.

### Declaration

```swift
public static var drivingPrivileges: ItemsRequestSpec { get }
```

### Parameters

N/A

### Returns

| Type             | Description          | **M/O** | **Note** |
|------------------|----------------------|---------|----------|
| ItemsRequestSpec | The request entry    | M       | [ItemsRequestSpec](#2-itemsrequestspec) |

### Usage

```swift
let response = try await session.request([ItemsRequestPresets.drivingPrivileges], at: Date())
```

<br>

## 6. Callback

The app implements `MdocReaderSessionDelegate` and sets it on [delegate](#12-delegate). All
methods are called on `configuration.callbackQueue`, dispatched asynchronously in the order the events
occurred — never in place, even from the main thread. Session methods and `terminate()` may be called
from any thread.

`request(_:at:)` returns its result directly, so there is no response callback. Errors reach the
app by exactly one route per event:

| When | Where | Example |
| --- | --- | --- |
| Inside `connect(to:)` · `connectViaNFC()` · `request(_:at:)` | The call **throws** | Connection timeout, `terminatedByPeer(status: 20)`, link lost during the response (`peerDisconnected`) |
| While **idle in `connected`** (after connecting, before requesting) | **`readerSession(_:didFailWith:)`** | The holder walks away or closes the app → `peerDisconnected`, transport error |

The app can route both the `catch` and `didFailWith` to the same screen state; one event is never
reported twice.

```swift
public protocol MdocReaderSessionDelegate: AnyObject {
    func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState)
    func readerSessionDidConnect(_ s: MdocReaderSession)
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int)
    func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError)
}

public extension MdocReaderSessionDelegate {
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int) {}
}
```

## 6.1. didChangeState

### Description
`Called on every state change.`

### Declaration

```swift
func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState)
```

### Parameters

| Name  | Type              | Description            | **M/O** | **Note** |
|-------|-------------------|------------------------|---------|----------|
| s     | MdocReaderSession | The session            | M       |          |
| state | MdocReaderState   | The new state          | M       | [MdocReaderState](#1-mdocreaderstate) |

### Returns

Void

### Usage

```swift
func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState) {
    statusLabel.text = state.rawValue
}
```

<br>

## 6.2. readerSessionDidConnect

### Description
`Called when connect(to:) or connectViaNFC() has established the session.`

### Declaration

```swift
func readerSessionDidConnect(_ s: MdocReaderSession)
```

### Parameters

| Name | Type              | Description  | **M/O** | **Note** |
|------|-------------------|--------------|---------|----------|
| s    | MdocReaderSession | The session  | M       |          |

### Returns

Void

### Usage

```swift
func readerSessionDidConnect(_ s: MdocReaderSession) {
    showWaitingForHolder()
}
```

<br>

## 6.3. didProgress

### Description
`Reports transfer progress of the response.`

Optional: a default empty implementation is provided.

### Declaration

```swift
func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int)
```

### Parameters

| Name     | Type              | Description                  | **M/O** | **Note** |
|----------|-------------------|------------------------------|---------|----------|
| s        | MdocReaderSession | The session                  | M       |          |
| received | Int               | Bytes received so far        | M       |          |
| total    | Int               | Total bytes expected         | M       |          |

### Returns

Void

### Usage

```swift
func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int) {
    progressView.progress = Float(received) / Float(max(total, 1))
}
```

<br>

## 6.4. didFailWith

### Description
`Called only when the link fails while the session is idle in connected.`

This is the case where no call is in progress to receive the error: after `connect` returned and
before `request` is called, the holder moves away or closes the app. The state becomes `failed`.
Failures inside `connect(to:)`, `connectViaNFC()` or `request(_:at:)` are thrown by that call
and do not arrive here.

A BLE link loss is reported by the system immediately. For NFC the SDK checks the tag's presence
periodically (every 0.25 seconds), so the report can be delayed by up to that interval.

### Declaration

```swift
func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError)
```

### Parameters

| Name  | Type               | Description      | **M/O** | **Note** |
|-------|--------------------|------------------|---------|----------|
| s     | MdocReaderSession  | The session      | M       |          |
| error | MdocProximityError | The failure      | M       | Usually `peerDisconnected`. [MdocProximityError.md](MdocProximityError.md) |

### Returns

Void

### Usage

```swift
func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError) {
    showDisconnected()
    s.terminate()
}
```

<br>

## 7. Capability

## 7.1. MdocCapabilities.current

### Description
`Reports which transports this device can use as a reader, without requesting any permission.`

The SDK never requests permissions and never shows the system "turn on Bluetooth" alert. It only
reports the current state; when to ask the user is the app's decision. Ask before starting the
flow: a permission prompt in the middle of a session can break the BLE connection. The reader
reads the `mdocReader` member.

| Member | Value | Meaning | What the app does |
| --- | --- | --- | --- |
| `ble` | `.supported` | Bluetooth usable, or not yet known | — |
| `ble` | `.configurationRequired(.grantPermission("bluetooth"))` | Bluetooth permission denied or restricted | Guide to Settings |
| `ble` | `.configurationRequired(.enableBluetooth)` | Bluetooth is turned off | Guide to Settings |
| `ble` | `.unsupported(.noHardware)` | No Bluetooth LE | Offer another transport |
| `nfc` | `.supported` | NFC reading available and the AIDs are registered | — |
| `nfc` | `.configurationRequired(.addEntitlement("com.apple.developer.nfc.readersession.iso7816.select-identifiers"))` | The `select-identifiers` registration is missing or in the wrong order | Fix the integration ([Integration Settings](#3-integration-settings)) |
| `nfc` | `.unsupported(.noHardware)` | This device cannot read NFC tags | Use QR + BLE |
| `wifiAware` | `.unsupported(.vendorPolicy)` | Always, on iOS | — |

Limits of the query, which is synchronous and does not prompt:

- While the Bluetooth permission has not been decided yet, `ble` is `.supported`. The system
  prompt appears when the app opens its first session.
- The Bluetooth power state arrives asynchronously. The first query after permission is granted
  may still report `.supported`; later queries reflect the actual state. If the query did not
  know yet, `connect(to:)` throws the same value.

The values match the errors that `connect(to:)` / `connectViaNFC()` throw when a transport is
blocked by the device (`configurationRequired(action:)`, `bleUnavailable(reason:)`,
`nfcUnavailable(reason:)`). The missing NFC entitlement is guidance, not a block: an app without
NFC reader capability still builds, passes review and runs over QR + BLE.

### Declaration

```swift
public static func current() -> MdocCapabilities
```

### Parameters

N/A

### Returns

| Type             | Description                     | **M/O** | **Note** |
|------------------|---------------------------------|---------|----------|
| MdocCapabilities | Capabilities of both roles      | M       | [MdocCapabilities](DataModel.md#1-mdoccapabilities). The reader uses `mdocReader` |

### Usage

```swift
let reader = MdocCapabilities.current().mdocReader
switch reader.ble {
case .supported:
    break
case .configurationRequired(let action):
    guideToSettings(action)
case .unsupported:
    hideBleOption()
@unknown default:
    hideBleOption()
}
nfcButton.isHidden = reader.nfc != .supported
```

<br>

# Enumerators
## 1. MdocReaderState

### Description

`State of a reader session.`

### Declaration

```swift
public enum MdocReaderState: String {
    case idle, connecting, connected, awaitingResponse, verifying, completed, terminated, failed
}
```

### Property

| Value            | Description                                                        | **Note** |
| ---------------- | ------------------------------------------------------------------ | -------- |
| idle             | Created; not connected yet                                         |          |
| connecting       | Selecting the transport and setting up the link (NFC sheet included) | Ends in `failed` after `connectTimeout` |
| connected        | Session keys derived; ready for `request(_:at:)`                   |          |
| awaitingResponse | Request sent; waiting for the response                             | Ends in `failed` after `responseTimeout` |
| verifying        | Response received and link closed; verifying documents             |          |
| completed        | Verification finished; result returned                             | Terminal |
| terminated       | Ended by `terminate()` or a cancellation                           | Terminal |
| failed           | Ended by an error                                                  | Terminal |
<br>

## 2. TransmissionKind

### Description

`Kind of transmission technology, used for the reader's transport policy.`

Only the kind is listed; the BLE mode is chosen by `blePreferredMode`, and L2CAP by
`l2capUpgrade`.

### Declaration

```swift
public enum TransmissionKind: Equatable {
    case ble
    case nfc
    case wifiAware
}
```

### Property

| Value     | Description                  | **Note** |
| --------- | ---------------------------- | -------- |
| ble       | Bluetooth Low Energy         |          |
| nfc       | NFC                          |          |
| wifiAware | Wi-Fi Aware                  | Not available on iOS; never selected |
<br>

## 3. BleModePreference

### Description

`Which GATT mode the reader selects when the mdoc advertises both.`

A preference, not an allow-list: when the mdoc advertises only one mode, that mode is used
regardless of this value. Either choice conforms to ISO/IEC 18013-5, which recommends
`central`.

### Declaration

```swift
public enum BleModePreference: Equatable {
    case central
    case peripheral
}
```

### Property

| Value      | Description                                                                | **Note** |
| ---------- | -------------------------------------------------------------------------- | -------- |
| central    | mdoc central client mode — the mdoc is the central, the reader is the GATT server |   |
| peripheral | mdoc peripheral server mode — the mdoc is the GATT server, the reader is the central | Default |
<br>

# Value Object

## 1. MdocReaderConfiguration

### Description

`Configuration of a reader session.`

A session is one transaction, so different entry points may use different configurations (for
example one for QR scans and one for NFC taps).

### Declaration

```swift
public struct MdocReaderConfiguration {
    public var transmissionPriority: [TransmissionKind] = [.ble, .nfc, .wifiAware]
    public var blePreferredMode: BleModePreference = .peripheral
    public var skipIssuerAuth: Bool = true
    public var l2capUpgrade: Bool = false
    public var connectTimeout: TimeInterval = 30
    public var responseTimeout: TimeInterval = 120
    public var callbackQueue: DispatchQueue = .main
    public init()
}
```

### Property

| Name                 | Type               | Description | **M/O** | **Note** |
| -------------------- | ------------------ | ----------- | ------- | -------- |
| transmissionPriority | [TransmissionKind] | Order **and** allow-list of transport kinds. A kind left out is never selected, even if the mdoc advertises it | M | Default `[.ble, .nfc, .wifiAware]`. [TransmissionKind](#2-transmissionkind). Independent of the engagement channel: to keep a tapped NFC link for data retrieval, use `[.nfc, .ble]` in that session |
| blePreferredMode     | BleModePreference  | GATT mode to select when the mdoc advertises both | M | Default `.peripheral`. [BleModePreference](#3-blemodepreference) |
| skipIssuerAuth       | Bool               | Skip issuer signature (`issuerAuth`) verification | M | Default **`true`** — see below |
| l2capUpgrade         | Bool               | Use a BLE L2CAP channel when available | M | Default `false` — GATT only. See below |
| connectTimeout       | TimeInterval       | Seconds allowed for the link to become ready in `connecting` | M | Default `30` |
| responseTimeout      | TimeInterval       | Seconds allowed in `awaitingResponse`, including user consent and transfer | M | Default `120` |
| callbackQueue        | DispatchQueue      | Queue on which delegate methods are called | M | Default `.main` |

**`skipIssuerAuth`** defaults to `true`: the SDK does **not** verify the issuer by default.
While it is `true`, the issuer public key is not resolved (the trust evaluator is not called, so
no lookup is made) and the issuer signature is not checked. MSO parsing, `docType`, validity,
digest comparison and device authentication are still performed. In this mode a document's
`verdict` is at most `.unverified`, never `.valid`: the device key arrives inside the response,
and without the issuer signature nothing says whose key it is. Set it to `false` in production.

**`l2capUpgrade`**: when `true`, in mdoc peripheral server mode the reader reads the mdoc's L2CAP
PSM characteristic and opens the channel; in mdoc central client mode it publishes its own PSM
characteristic for the mdoc to open. If the mdoc put its PSM in the engagement, the channel is
opened directly without the GATT round trip — also only when this value is `true`. If no PSM is
offered or the channel cannot be set up, the session continues over GATT in the same mode.
<br>

## 2. ItemsRequestSpec

### Description

`One requested document: docType and requested elements with their intentToRetain flags.`

Passed to `request(_:at:)` as an array; each element becomes one `DocRequest`. Several
documents may be requested at once, but not the same `docType` twice. The response may still
contain several documents of the same `docType` (the holder may present two); each is
verified and reported separately.

### Declaration

```swift
public struct ItemsRequestSpec: Equatable {
    public let docType: DocType
    public let items: [NameSpace: [DataElementIdentifier: Bool]]

    public init(docType: DocType, items: [NameSpace: [DataElementIdentifier: Bool]])
    func jsonData() throws -> Data
    static func from(jsonData: Data) throws -> ItemsRequestSpec
}
```

### Property

| Name    | Type                                       | Description                                          | **M/O** | **Note** |
| ------- | ------------------------------------------ | ---------------------------------------------------- | ------- | -------- |
| docType | DocType                                    | The requested document type                          | M       | `String` |
| items   | [NameSpace: [DataElementIdentifier: Bool]] | namespace → (element identifier → `intentToRetain`) | M       | `true` declares that the reader keeps that element |
<br>

## 2.1. Request Profile Format

### Description

`The JSON format produced by jsonData() and read by from(jsonData:).`

This JSON is the SDK's own storage format, not an ISO/IEC 18013-5 structure. What is sent to the
mdoc is the CBOR `ItemsRequest`, built by the SDK.

```json
{
  "version": 1,
  "docType": "org.iso.18013.5.1.mDL",
  "items": {
    "org.iso.18013.5.1": {
      "age_over_18": false,
      "portrait": false
    }
  }
}
```

### Property

| Name    | Type                              | Description                                 | **M/O** | **Note** |
| ------- | --------------------------------- | ------------------------------------------- | ------- | -------- |
| version | Int                               | Version of this JSON format                 | M       | Always `1`. Unrelated to `DeviceRequest.version` |
| docType | String                            | `ItemsRequestSpec.docType`                  | M       |          |
| items   | Object (String → String → Bool)   | `ItemsRequestSpec.items`                    | M       |          |

Serialization rules:

- Keys sorted lexicographically, no indentation, `/` not escaped. The same profile always yields
  the same bytes.
- On reading, unknown top-level keys are ignored; an unknown `version` is rejected with
  `decodeFailed`.
<br>

## 3. MdocDocTypes

### Description

`Constants for the mDL defined by ISO/IEC 18013-5.`

The protocol does not restrict `docType` or namespaces; these are conveniences for the mDL.

### Declaration

```swift
public enum MdocDocTypes {
    public static let mDL          = "org.iso.18013.5.1.mDL"
    public static let mDLNameSpace = "org.iso.18013.5.1"
}
```

### Property

| Name         | Type   | Description             | **M/O** | **Note** |
| ------------ | ------ | ----------------------- | ------- | -------- |
| mDL          | String | mDL `docType`           | M       | `org.iso.18013.5.1.mDL` |
| mDLNameSpace | String | mDL namespace           | M       | `org.iso.18013.5.1` |
<br>

# Usage

## 1. Verification Flow

| Step | Call | Notes |
| --- | --- | --- |
| 1 | Create the trust evaluator (`DIDIssuerKeyResolver(trustedIssuers:resolve:)`) | An empty `trustedIssuers` rejects every issuer. See [MdocTrust.md](MdocTrust.md) |
| 2 | QR: `EngagementPayload.parse(qrString:)` → `connect(to:)` · NFC: `connectViaNFC()` | With NFC, reading and connecting are one call (link continuity) |
| 3 | `request(_:at:)` | Once per session. No duplicate `docType`. `at` is the time the app trusts — the SDK never reads the clock |
| 4 | Read the result | `verdict` is the SDK's verification result; whether the response satisfies the business rule is the app's decision. Missing elements are in `notReturned`. Zero documents is a normal completion |
| 5 | If storing, use `retainableElements()` | Storing `allElements` breaks the retention rules ([DataModel.md](DataModel.md#2-verifieddocument)) |
| 6 | If `trust` is `.unknown`, `resolveTrust(for:using:at:)` | Can be called after the session has ended |
| 7 | `terminate()` | Always, including after `completed` or `failed` |

`terminatedByPeer(status: 20)` carries no reason: a refusal, a missing document and a plain
disconnection all arrive this way.

```swift
func verifyAge() async {
    let trust = DIDIssuerKeyResolver(trustedIssuers: trustedIssuerDIDs) { did, versionId in
        try await issuerKeyStore.publicKey(did: did, versionId: versionId)
    }
    var config = MdocReaderConfiguration()
    config.skipIssuerAuth = false

    let session = MdocReaderSession(configuration: config, trust: trust)
    session.delegate = self
    defer { session.terminate() }

    do {
        let engagement = try EngagementPayload.parse(qrString: scannedString)
        try await session.connect(to: engagement)

        let response = try await session.request([ItemsRequestPresets.ageOver(18)], at: Date())
        guard let doc = response.documents.first else { showNoDocument(); return }

        // Use only issuer-signed values whose digest matched
        let ns = MdocDocTypes.mDLNameSpace
        let ageOK = doc.digests?.matches[ns]?["age_over_18"] == true
                 && doc.issuerSignedElements[ns]?["age_over_18"]?.asBoolean == true

        render(ageOK: ageOK, verdict: doc.verdict, trust: doc.issuerDataAuth.trust)

        if case .unknown = doc.issuerDataAuth.trust {
            let resolved = await MdocReaderSession.resolveTrust(for: doc, using: trust, at: Date())
            updateTrustBadge(resolved.issuerDataAuth.trust)
        }
    } catch is CancellationError {
        return
    } catch {
        present(error: error)
    }
}
```

<br>

## 2. NFC Tap and BLE Handover

Transport selection is the same for both entry points; only where the engagement comes from
differs. With the default `transmissionPriority` (`[.ble, .nfc, .wifiAware]`), when the mdoc
advertises BLE after the tap, the session moves to BLE (better for large responses); when the
mdoc advertises only NFC, the tapped link is kept.

```swift
// NFC: reading and connecting are one call, to keep the link
let engagement = try await session.connectViaNFC()
let response = try await session.request([ItemsRequestPresets.identity], at: Date())
```

To always retrieve data over the tapped NFC link, give **that session** a configuration that puts
NFC first. Sessions created for QR scans can keep the default.

```swift
var nfcConfig = MdocReaderConfiguration()
nfcConfig.transmissionPriority = [.nfc, .ble]
let nfcSession = MdocReaderSession(configuration: nfcConfig, trust: trust)
let engagement = try await nfcSession.connectViaNFC()
```

<br>

## 3. Integration Settings

The SDK holds no entitlement; the integrating app declares them.

```text
Info.plist
  NSBluetoothAlwaysUsageDescription       (BLE)
  NSCameraUsageDescription                (QR scanning, done by the app)
  NFCReaderUsageDescription               (NFC)
  com.apple.developer.nfc.readersession.iso7816.select-identifiers   (array, order matters)
      [0] D2760000850101   (NFC Forum NDEF Tag Application — engagement)
      [1] A0000002480400   (mdoc data retrieval)
Entitlements
  com.apple.developer.nfc.readersession.formats = [TAG]
```

- Register **both** AIDs. With only `D2760000850101`, the engagement can be read but NFC data
  retrieval fails.
- `D2760000850101` must come **first**. The system tries the AIDs in order; if the data retrieval
  AID comes first, the engagement is skipped.
- `MdocCapabilities.current().mdocReader.nfc` checks both rules.

<br>

## 4. Usage Rules

1. **A session is single-use.** Retry with a new session; the session keys are bound to the
   engagement.
2. **Always call `terminate()`.** Call it when leaving the screen (`viewWillDisappear`), and after
   `completed` or `failed` as well; otherwise the next session cannot connect.
3. **The app requests permissions.** Check with `MdocCapabilities.current()` and obtain
   permissions before starting the flow.
4. **Decide on `issuerSignedElements`.** `allElements` is a display convenience;
   `deviceSignedElements` are not vouched for by the issuer.
5. **Store only through `retainableElements()`.** Storing `allElements` would retain values whose
   `intentToRetain` is `false`, which ISO/IEC 18013-5 does not allow.
6. **Derived values count as retained data.** Storing an age computed from `birth_date` is
   storing `birth_date`.
7. **Do not log element values, digests or signatures.** The SDK does not log them and offers no
   option to log raw responses.
8. **Do not keep response data in memory after the transaction.** Caching beyond the time needed
   for the transaction is retention.
9. **Treat a skipped issuer check as unverified.** With `skipIssuerAuth == true` (the default)
   no document reaches `.valid`.

