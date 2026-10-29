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

iOS MdocDevice API
==

- Subject: MdocDeviceAPI
- Writer: JooHyun Park
- Date: 2026-10-12
- Version: v1.0.0

| Version | Date       | History |
| ------- | ---------- | ------- |
| v1.0.0  | 2026-10-12 | Initial |

<div style="page-break-after: always;"></div>

# Table of Contents
- [APIs](#api-list)
    - [1. MdocDeviceSession](#1-mdocdevicesession)
        - [1.1. init](#11-init)
        - [1.2. delegate](#12-delegate)
        - [1.3. state](#13-state)
        - [1.4. configuration](#14-configuration)
        - [1.5. start](#15-start)
        - [1.6. respond](#16-respond)
        - [1.7. reject](#17-reject)
        - [1.8. terminate](#18-terminate)
    - [2. MdocDeviceSessionDelegate](#2-mdocdevicesessiondelegate)
        - [2.1. didChangeState](#21-didchangestate)
        - [2.2. didReceiveRequest](#22-didreceiverequest)
        - [2.3. didProgress](#23-didprogress)
        - [2.4. mdocSessionDidFinish](#24-mdocsessiondidfinish)
        - [2.5. didFailWith](#25-didfailwith)
    - [3. NfcCardEmulationProtocol](#3-nfccardemulationprotocol)
        - [3.1. start](#31-start)
        - [3.2. onDeactivated](#32-ondeactivated)
        - [3.3. stop](#33-stop)
    - [4. Capability](#4-capability)
        - [4.1. MdocCapabilities.current](#41-mdoccapabilitiescurrent)

- [Enumerators](#enumerators)
    - [1. MdocDeviceState](#1-mdocdevicestate)
    - [2. BleAdvertiseMode](#2-bleadvertisemode)

- [Value Object](#value-object)
    - [1. MdocDeviceConfiguration](#1-mdocdeviceconfiguration)


# API List

The APIs in this document are used by the **mdoc app** (the holder's app) to present an mdoc to a
reader in proximity, as specified by ISO/IEC 18013-5. With Swift Package Manager they come from the
`MdocDevice` product (`import MdocDevice`); with the XCFramework, from the `MdocProximitySDK`
module (`import MdocProximitySDK`). Either import also exposes the common types described in
[DataModel](DataModel.md) and the error type [MdocProximityError](MdocProximityError.md).

This SDK runs the device engagement and the encrypted session; it **carries bytes**. It does not
read or store documents, does not parse the `DeviceRequest`, does not show a consent screen and
does not build or sign the `DeviceResponse`. The app hands the request bytes to the wallet SDK and
passes the wallet SDK's plaintext `DeviceResponse` back to the session.

| Direction    | Value               | Produced by | Rule |
| ------------ | ------------------- | ----------- | ---- |
| SDK → app    | `deviceRequest`     | mdoc reader | The decrypted `DeviceRequest` CBOR. The SDK does not parse it |
| SDK → app    | `sessionTranscript` | this SDK    | `SessionTranscriptBytes` (`#6.24(bstr .cbor SessionTranscript)`). Pass it to the wallet SDK **as is** — decoding and re-encoding it breaks the reader's `DeviceAuth` verification |
| app → SDK    | `deviceResponse`    | wallet SDK  | **Plaintext** `DeviceResponse`. The SDK encrypts it and sends it as `SessionData` |

Threading and lifetime rules that apply to every API below:

- Delegate methods are called on `MdocDeviceConfiguration.callbackQueue` (main by default).
- A session's methods and `terminate()` may be called from any thread; state changes are serialized
  inside the session.
- **Only one session is active per process**, across both `MdocDeviceSession` and
  `MdocReaderSession`, because BLE advertising/scanning and NFC card emulation are process-wide
  resources. A second `start` fails with `invalidState`.
- **One session = one transaction.** A session cannot be restarted; retry with a new session.
- Call `terminate()` when leaving the screen, **even after the session reached a terminal state**.
  Until it is called, the radio and the process-wide session slot stay held.

## 1. MdocDeviceSession

The entry point of the mdoc app.

```swift
public final class MdocDeviceSession
```

## 1.1. init

### Description
`Creates a session.`

The configuration is copied into the session and cannot be changed afterwards. The transport is
not injectable: the SDK decides which transmission technologies to advertise and sets them up
itself.

`nfcCardEmulation` is for apps that hold Apple's HCE entitlement (`com.apple.developer.nfc.hce`).
The SDK does not implement card emulation; an app that has the entitlement wraps CoreNFC
`CardSession` in [NfcCardEmulationProtocol](#3-nfccardemulationprotocol) and passes it here. With
it, `start(technology: .nfcStaticHandover)` and `.nfcNegotiatedHandover` become available, and a QR
engagement also advertises NFC. Without it, the session presents over QR + BLE only.

### Declaration

```swift
public convenience init(configuration: MdocDeviceConfiguration = MdocDeviceConfiguration(),
                        nfcCardEmulation: NfcCardEmulationProtocol? = nil)
```

### Parameters

| Name             | Type                      | Description                         | **M/O** | **Note** |
|------------------|---------------------------|-------------------------------------|---------|----------|
| configuration    | MdocDeviceConfiguration   | Timeouts, BLE mode policy, L2CAP, callback queue | O | Default `MdocDeviceConfiguration()`. [MdocDeviceConfiguration](#1-mdocdeviceconfiguration) |
| nfcCardEmulation | NfcCardEmulationProtocol? | Card emulation supplied by the app  | O       | Default `nil`. [NfcCardEmulationProtocol](#3-nfccardemulationprotocol) |

### Returns

| Type              | Description                 | **M/O** | **Note** |
|-------------------|-----------------------------|---------|----------|
| MdocDeviceSession | A new session in `idle`     | M       |          |

### Usage

```swift
let session = MdocDeviceSession(configuration: MdocDeviceConfiguration())
session.delegate = self
```

<br>

## 1.2. delegate

### Description
`The object that receives the session's callbacks.`

Held weakly. Set it before calling `start`.

### Declaration

```swift
public weak var delegate: MdocDeviceSessionDelegate?
```

### Parameters

N/A

### Returns

| Type                       | Description           | **M/O** | **Note** |
|----------------------------|-----------------------|---------|----------|
| MdocDeviceSessionDelegate? | The current delegate  | O       | [MdocDeviceSessionDelegate](#2-mdocdevicesessiondelegate) |

### Usage

```swift
session.delegate = self
```

<br>

## 1.3. state

### Description
`The current state of the session.`

Read-only. Every change is also reported through `mdocSession(_:didChangeState:)`.

### Declaration

```swift
public private(set) var state: MdocDeviceState
```

### Parameters

N/A

### Returns

| Type            | Description        | **M/O** | **Note** |
|-----------------|--------------------|---------|----------|
| MdocDeviceState | The current state  | M       | [MdocDeviceState](#1-mdocdevicestate) |

### Usage

```swift
if session.state == .awaitingResponse {
    try await session.reject()
}
```

<br>

## 1.4. configuration

### Description
`The configuration the session was created with.`

The value passed to `init`, unchanged for the life of the session.

### Declaration

```swift
public let configuration: MdocDeviceConfiguration
```

### Parameters

N/A

### Returns

| Type                    | Description                   | **M/O** | **Note** |
|-------------------------|-------------------------------|---------|----------|
| MdocDeviceConfiguration | The session's configuration   | M       | [MdocDeviceConfiguration](#1-mdocdeviceconfiguration) |

### Usage

```swift
let timeout = session.configuration.responseTimeout
```

<br>

## 1.5. start

### Description
`Creates the device engagement and starts waiting for the reader.`

Callable only in `idle`. On return the session is in `engaging`: the engagement is exposed and the
transports are open. If no reader establishes a session within `engagementTimeout`, the session
moves to `failed` and `mdocSession(_:didFailWith:)` reports `engagementTimeout`.

The app does not choose the transmission technologies; the SDK does. What is advertised is

- the transmission technologies this SDK implements,
- intersected with what the device can use right now (radio, permission),
- narrowed by `MdocDeviceConfiguration.bleAdvertiseMode` (BLE only; it can narrow, never widen).

NFC is part of the first term only when `nfcCardEmulation` was passed to `init`.

| technology               | Behavior |
|--------------------------|----------|
| `.qr`                    | Builds a `DeviceEngagement` carrying every advertised technology and opens all of them; the one the reader connects on is used. The BLE service UUID is new for each transaction. The app renders `payload.qrString` as a QR code. If NFC is advertised and the reader picks it, the holder has to tap the phone on the reader — telling the holder so is the app's job, since the QR channel cannot carry the reader's choice back. |
| `.nfcStaticHandover`     | Requires `nfcCardEmulation`. The mdoc appears as an NFC Type 4 Tag with a prepared Handover Select. The only carrier offered is NFC, so data retrieval continues over the same NFC link. `payload.qrString` is `nil`. |
| `.nfcNegotiatedHandover` | Requires `nfcCardEmulation`. The mdoc appears as a Type 4 Tag offering the TNEP handover service. When the reader writes its Handover Request, the mdoc answers with the **first carrier in the reader's order of preference** that it can provide — a BLE mode permitted by `bleAdvertiseMode` and supported by the device, or NFC. A chosen BLE transport is set up at that moment. If no offered carrier can be provided, the handover is declined. `payload.transmissions` is empty when `start` returns. |

When the reader's first message arrives, the session moves through `sessionEstablished` to
`awaitingResponse` and calls `mdocSession(_:didReceiveRequest:sessionTranscript:)`.

If `terminate()` is called before `start` returns, `start` throws `CancellationError` and the state
is `terminated`. If `start` fails for any other reason after the session slot was taken, the state
is `failed` and the session cannot be used again.

### Declaration

```swift
@discardableResult
public func start(technology: EngagementTechnology) async throws -> EngagementPayload
```

### Parameters

| Name       | Type                 | Description                              | **M/O** | **Note** |
|------------|----------------------|------------------------------------------|---------|----------|
| technology | EngagementTechnology | The device engagement channel to use     | M       | [EngagementTechnology](DataModel.md#2-engagementtechnology) |

### Returns

| Type              | Description                                | **M/O** | **Note** |
|-------------------|--------------------------------------------|---------|----------|
| EngagementPayload | The engagement that was exposed. `qrString` is set for `.qr` only; `transmissions` lists the advertised technologies | M | [EngagementPayload](DataModel.md#1-engagementpayload) |

### Throws

- `invalidState`: the session is not `idle`, or another session is already active in this process
- `nfcUnavailable(reason: .vendorPolicy)`: an NFC technology was requested without `nfcCardEmulation`. The state stays `idle`
- `configurationRequired(action:)` / `bleUnavailable(reason:)`: nothing can be advertised because of the device's BLE capability (Bluetooth off, permission denied, no radio). Same values as [MdocCapabilities.current](#41-mdoccapabilitiescurrent)
- `unsupportedTransmissionTechnology`: the device is capable, but nothing is left to advertise after `bleAdvertiseMode`
- Errors from opening the transport, or from `NfcCardEmulationProtocol.start(handler:)`
- `CancellationError`: `terminate()` was called before `start` returned

See [MdocProximityError](MdocProximityError.md).

### Usage

```swift
do {
    let payload = try await session.start(technology: .qr)
    qrImageView.image = renderQR(payload.qrString!)   // rendering is up to the app
} catch {
    present(error: error)
}
```

<br>

## 1.6. respond

### Description
`Sends the DeviceResponse built by the wallet SDK.`

Callable only in `awaitingResponse`, once per session. Pass the **plaintext** `DeviceResponse`;
the SDK encrypts it with the session key and sends it as `SessionData`. The SDK does not inspect its
content or compare it with the request.

The response timer stops when this is called. The state moves to `responding` while the message is
sent, then to `completed`, and `mdocSessionDidFinish(_:)` is called. Transfer progress of a large
response is reported through `mdocSession(_:didProgress:of:)`.

### Declaration

```swift
public func respond(deviceResponse: Data) async throws
```

### Parameters

| Name           | Type | Description                                 | **M/O** | **Note** |
|----------------|------|---------------------------------------------|---------|----------|
| deviceResponse | Data | The `DeviceResponse` CBOR, **plaintext**    | M       | As built by the wallet SDK |

### Returns

Void

### Throws

- `invalidState`: the session is not `awaitingResponse`, or a response was already sent
- Transport errors raised while sending (for example `peerDisconnected` when the reader has left).
  The state becomes `failed`; the error arrives only as this throw, and `mdocSession(_:didFailWith:)`
  is not called
- `CancellationError`: `terminate()` was called while the response was being sent. The state stays
  `terminated` and `mdocSessionDidFinish(_:)` is not called

### Usage

```swift
try await session.respond(deviceResponse: response)
```

<br>

## 1.7. reject

### Description
`Ends the session without a response.`

Use when no response can be produced — the document is not held, the holder declined, or the
holder cancelled; the SDK does not distinguish these. Callable only in `awaitingResponse`. Only a
session termination (status 20) is sent to the reader; an empty `DeviceResponse` is never sent.
The state moves to `terminated` and `mdocSessionDidFinish(_:)` is called.

### Declaration

```swift
public func reject() async throws
```

### Parameters

N/A

### Returns

Void

### Throws

- `invalidState`: the session is not `awaitingResponse`
- Transport errors raised while sending the termination. The state becomes `failed`; the error
  arrives only as this throw, and `mdocSession(_:didFailWith:)` is not called

### Usage

```swift
try await session.reject()
```

<br>

## 1.8. terminate

### Description
`Ends the session and releases its resources.`

Callable in any state and never throws.

- In a non-terminal state, sends a session termination (status 20) to the reader, closes the link
  after it has been sent, and moves to `terminated`.
- In a terminal state (`completed`, `terminated`, `failed`), only releases the remaining resources.
  **The state does not change**, so a `completed` session stays `completed`. In `completed` or
  `failed`, if no session termination has been exchanged with the reader yet, a session
  termination (status 20) is sent before the link is closed.

In either case it stops the session's timers and releases the process-wide session slot. Call it
whenever the presentation screen closes.

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
    session?.terminate()
}
```

<br>

## 2. MdocDeviceSessionDelegate

Callbacks of `MdocDeviceSession`, called on `MdocDeviceConfiguration.callbackQueue`. Every call is
dispatched asynchronously to that queue, in the order the events occurred — even when the event is
raised on the main thread and the queue is the main queue.

```swift
public protocol MdocDeviceSessionDelegate: AnyObject {
    func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState)
    func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                     sessionTranscript: Data)
    func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int)
    func mdocSessionDidFinish(_ s: MdocDeviceSession)
    func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError)
}

public extension MdocDeviceSessionDelegate {
    func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int) {}
}
```

## 2.1. didChangeState

### Description
`Called on every state change.`

Use it to drive the presentation UI, for example "reading over NFC" or "sending over Bluetooth".

### Declaration

```swift
func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState)
```

### Parameters

| Name  | Type              | Description      | **M/O** | **Note** |
|-------|-------------------|------------------|---------|----------|
| s     | MdocDeviceSession | The session      | M       |          |
| state | MdocDeviceState   | The new state    | M       | [MdocDeviceState](#1-mdocdevicestate) |

### Returns

Void

### Usage

```swift
func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) {
    statusLabel.text = "\(state)"
}
```

<br>

## 2.2. didReceiveRequest

### Description
`The reader's request arrived.`

The central callback of this SDK. The session is now `awaitingResponse` and the response timer
(`responseTimeout`) is running. Hand **both byte strings, unchanged,** to the wallet SDK to match the
request, show the consent screen and build the `DeviceResponse`; then call `respond(deviceResponse:)`,
or `reject()` if no response can be produced. Matching, consent and response building (including any
biometric prompt) must finish within `responseTimeout`.

Called at most once per session. If the reader sends a second request in the same session, the SDK
sends a session termination (status 20) and the request is not delivered. While waiting for the
app's answer the state moves to `terminated`; after `completed` the state stays `completed`. It is
the reader's violation, not an app error, so `mdocSession(_:didFailWith:)` is not called.

### Declaration

```swift
func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                 sessionTranscript: Data)
```

### Parameters

| Name              | Type              | Description                                    | **M/O** | **Note** |
|-------------------|-------------------|------------------------------------------------|---------|----------|
| s                 | MdocDeviceSession | The session                                    | M       |          |
| deviceRequest     | Data              | The decrypted `DeviceRequest` CBOR             | M       | Not parsed by this SDK |
| sessionTranscript | Data              | This session's `SessionTranscriptBytes`        | M       | `#6.24(bstr .cbor SessionTranscript)`. **Do not re-encode** |

### Returns

Void

### Usage

```swift
func mdocSession(_ s: MdocDeviceSession,
                 didReceiveRequest deviceRequest: Data,
                 sessionTranscript: Data) {
    Task {
        do {
            // Matching, consent and DeviceResponse building happen in the wallet SDK
            let response = try await walletFlow.present(deviceRequest: deviceRequest,
                                                        sessionTranscript: sessionTranscript)
            try await s.respond(deviceResponse: response)   // plaintext; the SDK encrypts it
        } catch {
            try? await s.reject()                           // not held, declined or cancelled
        }
    }
}
```

<br>

## 2.3. didProgress

### Description
`Transfer progress of an outgoing message.`

Reported while a message, typically the response, is being sent. A response with a large element
such as a portrait can take tens of seconds over BLE with a small MTU. Optional: a default empty
implementation is provided.

### Declaration

```swift
func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int)
```

### Parameters

| Name  | Type              | Description                         | **M/O** | **Note** |
|-------|-------------------|-------------------------------------|---------|----------|
| s     | MdocDeviceSession | The session                         | M       |          |
| sent  | Int               | Bytes of the message sent so far    | M       |          |
| total | Int               | Total bytes of the message          | M       |          |

### Returns

Void

### Usage

```swift
func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int) {
    progressView.progress = Float(sent) / Float(total)
}
```

<br>

## 2.4. mdocSessionDidFinish

### Description
`The session ended through the app's own answer.`

Called after `respond(deviceResponse:)` has sent the response (state `completed`) and after
`reject()` has sent the termination (state `terminated`). It is not called when the reader ends
the session or the link drops; those appear as a state change to `terminated`, or as
`mdocSession(_:didFailWith:)`.

### Declaration

```swift
func mdocSessionDidFinish(_ s: MdocDeviceSession)
```

### Parameters

| Name | Type              | Description  | **M/O** | **Note** |
|------|-------------------|--------------|---------|----------|
| s    | MdocDeviceSession | The session  | M       |          |

### Returns

Void

### Usage

```swift
func mdocSessionDidFinish(_ s: MdocDeviceSession) {
    statusLabel.text = "Done"
}
```

<br>

## 2.5. didFailWith

### Description
`The session failed.`

The state is `failed` when this is called, and it is called at most once. Typical errors:

- `engagementTimeout`: no reader established a session within `engagementTimeout`
- `responseTimeout`: neither `respond` nor `reject` was called within `responseTimeout`. A session
  termination (status 20) has been sent to the reader
- `terminatedByPeer(status:)`: the reader ended the session with a status other than 20 (for example 10 or 11). The SDK closes the link; the session slot is still released by `terminate()`
- Capability errors such as `configurationRequired(action: .enableBluetooth)` when every advertised
  transport failed for that reason
- Transport, session encryption and decoding errors

A normal termination by the reader (status 20) and the link closing are not failures: the state
becomes `terminated` (unless it is already terminal) and this method is not called.

### Declaration

```swift
func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError)
```

### Parameters

| Name  | Type               | Description     | **M/O** | **Note** |
|-------|--------------------|-----------------|---------|----------|
| s     | MdocDeviceSession  | The session     | M       |          |
| error | MdocProximityError | The cause       | M       | [MdocProximityError](MdocProximityError.md) |

### Returns

Void

### Usage

```swift
func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) {
    switch error {
    case .configurationRequired(.enableBluetooth): promptEnableBluetooth()
    case .engagementTimeout:                       statusLabel.text = "Timed out"
    case .terminatedByPeer:                        dismiss(animated: true)
    default:                                       present(error: error)
    }
}
```

<br>

## 3. NfcCardEmulationProtocol

Card emulation that makes the mdoc appear as an NFC tag, **supplied by the app**. iOS only.

The SDK does not implement HCE: CoreNFC `CardSession` (iOS 17.4+) requires the
`com.apple.developer.nfc.hce` entitlement, which is granted to an app, not to an SDK. The boundary is
therefore a single APDU. The app wraps `CardSession`, passes each command APDU to `handler` and
sends back the return value as the response APDU; the ISO 7816 state machine, the Type 4 Tag files,
ENVELOPE chaining and session encryption are all done by the SDK.

Inject an implementation through [init](#11-init). `MdocCapabilities.current().mdoc.nfc` stays
`.unsupported(reason: .vendorPolicy)` whether or not an implementation is injected: the static query
cannot see the injection, and the app that injects it already knows.

```swift
public protocol NfcCardEmulationProtocol: AnyObject {
    func start(handler: @escaping (Data) async -> Data) async throws
    var onDeactivated: (() -> Void)? { get set }
    func stop()
}
```

## 3.1. start

### Description
`Turns card emulation on.`

The SDK calls this when the NFC transport opens, during `MdocDeviceSession.start`. For each command
APDU from the reader, pass the APDU to `handler` and send its return value as the response APDU,
**unchanged, including the status word**. `handler` may suspend until the response exists: the
response to the last ENVELOPE is produced only after the app calls `respond(deviceResponse:)`.
Keeping the link alive meanwhile is up to the OS.

An error thrown here makes `MdocDeviceSession.start` throw it.

### Declaration

```swift
func start(handler: @escaping (Data) async -> Data) async throws
```

### Parameters

| Name    | Type                          | Description                                                    | **M/O** | **Note** |
|---------|-------------------------------|----------------------------------------------------------------|---------|----------|
| handler | (Data) async -> Data          | Takes a command APDU, returns the response APDU                | M       | Provided by the SDK |

### Returns

Void

### Usage

```swift
// Inside an app class that conforms to NfcCardEmulationProtocol and holds
// `session: CardSession?` and `pump: Task<Void, Never>?` (iOS 17.4+)
func start(handler: @escaping (Data) async -> Data) async throws {
    guard CardSession.isSupported else { throw MdocProximityError.nfcUnavailable(reason: .noHardware) }
    guard await CardSession.isEligible else { throw MdocProximityError.nfcUnavailable(reason: .vendorPolicy) }
    let session = try await CardSession()                // throws without the HCE entitlement
    self.session = session
    pump = Task { [weak self] in
        do {
            for try await event in session.eventStream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .sessionStarted:
                    try? await session.startEmulation()
                case .received(let apdu):
                    let response = await handler(apdu.payload)   // the SDK runs the protocol
                    try? await apdu.respond(response: response)
                case .readerDeselected, .sessionInvalidated:
                    onDeactivated?()
                default:
                    break
                }
            }
        } catch {
            self?.onDeactivated?()
        }
    }
}
```

<br>

## 3.2. onDeactivated

### Description
`Notifies the SDK that the reader left the field or the card session was invalidated.`

The SDK sets this closure before calling `start(handler:)`. Call it when the reader deselects or
leaves, or when the card session ends. The SDK treats it as the link closing and ends the session.

### Declaration

```swift
var onDeactivated: (() -> Void)? { get set }
```

### Parameters

N/A

### Returns

| Type             | Description                         | **M/O** | **Note** |
|------------------|-------------------------------------|---------|----------|
| (() -> Void)?    | The closure set by the SDK          | O       |          |

### Usage

```swift
var onDeactivated: (() -> Void)?

// in the CardSession event loop
case .readerDeselected, .sessionInvalidated:
    onDeactivated?()
```

<br>

## 3.3. stop

### Description
`Turns card emulation off.`

The SDK calls this when it closes the NFC link. It must be safe to call before `start(handler:)` and
more than once.

### Declaration

```swift
func stop()
```

### Parameters

N/A

### Returns

Void

### Usage

```swift
func stop() {
    pump?.cancel(); pump = nil
    guard let session else { return }
    self.session = nil
    Task {
        try? await session.stopEmulation(status: .success)
        session.invalidate()
    }
}
```

<br>

## 4. Capability

The SDK never requests permissions itself. It only reports state; when to ask is the app's
decision, so that a system prompt does not interrupt the consent flow. The types are described in
[DataModel](DataModel.md#1-mdoccapabilities).

## 4.1. MdocCapabilities.current

### Description
`Queries which transports this device can use right now.`

The mdoc app reads the `mdoc` member. Synchronous; it does not request any permission.

| Member           | Values on the mdoc side |
|------------------|-------------------------|
| `mdoc.ble`       | `.supported`; `.configurationRequired(action: .grantPermission("bluetooth"))` when Bluetooth permission is denied or restricted; `.configurationRequired(action: .enableBluetooth)` when Bluetooth is off; `.unsupported(reason: .noHardware)` when there is no BLE radio |
| `mdoc.nfc`       | Always `.unsupported(reason: .vendorPolicy)` — card emulation needs Apple's HCE entitlement. Not changed by injecting [NfcCardEmulationProtocol](#3-nfccardemulationprotocol) |
| `mdoc.wifiAware` | Always `.unsupported(reason: .vendorPolicy)` |

Two limits follow from being synchronous and not requesting permissions:

- While Bluetooth permission is **not determined**, `ble` is `.supported`. Determining it would make
  the OS show the permission prompt; that happens when the app first calls `start`.
- The Bluetooth power state arrives asynchronously. The first query after permission is granted may
  not know it yet and answers `.supported`; later queries reflect it. If the query already knew,
  `start` throws `configurationRequired(action: .enableBluetooth)`; if not, the same value arrives
  through `mdocSession(_:didFailWith:)` once every advertised transport fails for that reason.

The SDK does not show the system "Turn on Bluetooth" alert. Whether and how to guide the user to
Settings is the app's decision.

### Declaration

```swift
public static func current() -> MdocCapabilities
```

### Parameters

N/A

### Returns

| Type             | Description                                 | **M/O** | **Note** |
|------------------|---------------------------------------------|---------|----------|
| MdocCapabilities | Capabilities of the `mdoc` and `mdocReader` roles | M  | [MdocCapabilities](DataModel.md#1-mdoccapabilities) |

### Usage

```swift
switch MdocCapabilities.current().mdoc.ble {
case .supported:
    break
case .configurationRequired(action: .enableBluetooth):
    showEnableBluetoothGuide()
case .configurationRequired(action: .grantPermission):
    showPermissionGuide()
case .configurationRequired, .unsupported:
    showNotAvailable()
@unknown default:
    showNotAvailable()
}
```

<br>

# Enumerators
## 1. MdocDeviceState

### Description

`State of an MdocDeviceSession.`

### Declaration

```swift
public enum MdocDeviceState: String {
    case idle, engaging, sessionEstablished, awaitingResponse, responding, completed, terminated, failed
}
```

### Property

| Value              | Description                                                        | **Note** |
| ------------------ | ------------------------------------------------------------------ | -------- |
| idle               | Created, not started                                               | `start` is allowed |
| engaging           | Engagement exposed, waiting for the reader                         | Ends in `failed` after `engagementTimeout` |
| sessionEstablished | The reader's `SessionEstablishment` was received and decrypted     |          |
| awaitingResponse   | The request was delivered; waiting for the app's answer            | `respond` / `reject` are allowed. Ends in `failed` after `responseTimeout` |
| responding         | The response is being sent                                         |          |
| completed          | The response was sent                                              | Terminal |
| terminated         | Ended by `reject`, `terminate`, the reader's termination (status 20) or the link closing | Terminal |
| failed             | Ended by an error reported through `didFailWith`, or by a send failure thrown from `respond` / `reject` | Terminal |

| Current state | Allowed calls | Other calls |
| ------------- | ------------- | ----------- |
| `idle` | `start`, `terminate` | `invalidState` |
| `engaging` / `sessionEstablished` / `responding` | `terminate` | `invalidState` |
| `awaitingResponse` | `respond`, `reject`, `terminate` | `invalidState` |
| `completed` / `terminated` / `failed` | `terminate` (state unchanged) | `invalidState` |

In BLE mdoc central client mode, the mdoc checks the reader's Ident characteristic while
`engaging`. On a mismatch it drops that peripheral and scans again; the session stays `engaging`
and no failure is reported.
<br>

## 2. BleAdvertiseMode

### Description

`Which BLE modes the mdoc advertises.`

ISO/IEC 18013-5 lets an mdoc support either GATT mode, so advertising only one is conformant. A
reader must support both. `.both` means "no restriction", not "always advertise both": the result is
still intersected with what the device supports.

### Declaration

```swift
public enum BleAdvertiseMode: Equatable {
    case peripheralServer
    case centralClient
    case both

    public func allows(_ technology: TransmissionTechnology) -> Bool
}
```

### Property

| Value            | Description                                                   | **Note** |
| ---------------- | ------------------------------------------------------------- | -------- |
| peripheralServer | mdoc peripheral server mode only (the mdoc is the GATT server) |         |
| centralClient    | mdoc central client mode only (the mdoc is the GATT client)    |         |
| both             | No restriction                                                 | Default |

| Method     | Description | **Note** |
| ---------- | ----------- | -------- |
| allows(_:) | Whether this policy permits `technology`. Always `true` for a technology other than BLE | [TransmissionTechnology](DataModel.md#3-transmissiontechnology) |
<br>

# Value Object

## 1. MdocDeviceConfiguration

### Description

`Configuration of an MdocDeviceSession.`

There is no list of transmission technologies: the SDK decides what to advertise (see
[start](#15-start)). The only transport policy the app sets is `bleAdvertiseMode`, which can narrow
the set but not widen it.

### Declaration

```swift
public struct MdocDeviceConfiguration {
    public var engagementTimeout: TimeInterval = 90
    public var responseTimeout: TimeInterval = 60
    public var bleAdvertiseMode: BleAdvertiseMode = .both
    public var l2capUpgrade: Bool = false
    public var callbackQueue: DispatchQueue = .main

    public init()
}
```

### Property

| Name              | Type             | Description                                                    | **M/O** | **Note** |
| ----------------- | ---------------- | -------------------------------------------------------------- | ------- | -------- |
| engagementTimeout | TimeInterval     | Seconds to wait in `engaging` for the reader                   | M       | Default 90 |
| responseTimeout   | TimeInterval     | Seconds to wait in `awaitingResponse` for `respond` or `reject` | M      | Default 60. Covers the consent screen and the wallet SDK's response building, including biometric prompts. On expiry a termination is sent and the session fails with `responseTimeout` |
| bleAdvertiseMode  | BleAdvertiseMode | BLE modes to advertise                                         | M       | Default `.both`. Narrows only. If the chosen mode is not supported by the device and nothing else is left, `start` throws `unsupportedTransmissionTechnology`. [BleAdvertiseMode](#2-bleadvertisemode) |
| l2capUpgrade      | Bool             | Whether to offer the L2CAP upgrade                             | M       | Default `false` (GATT only). See below |
| callbackQueue     | DispatchQueue    | Queue the delegate is called on                                | M       | Default `.main` |

**`l2capUpgrade`** does not change what is advertised: the L2CAP PSM is exchanged through a GATT
characteristic, not through the engagement. When `true`, in mdoc peripheral server mode the mdoc
publishes its PSM characteristic (`0000000A`), and in mdoc central client mode it reads the reader's
PSM characteristic (`0000000B`) and opens the channel. If the peer offers no PSM or the channel
cannot be opened, the session falls back to GATT in the same mode. It is off by default because, in
measurements with a 21 KB response, the channel setup cost outweighed the transfer gain.
<br>
