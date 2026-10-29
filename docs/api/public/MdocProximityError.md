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

iOS MdocProximityError
==

- Topic: MdocProximityError
- Author: JooHyun Park
- Date: 2026-10-12
- Version: v1.0.0

| Version | Date       | Changes                  |
| --------| ---------- | ------------------------ |
| v1.0.0  | 2026-10-12 | Initial version          |

<div style="page-break-after: always;"></div>

# Table of Contents

- [iOS MdocProximityError](#ios-mdocproximityerror)
- [Table of Contents](#table-of-contents)
  - [MdocProximityError](#mdocproximityerror)
    - [Description](#description)
    - [Declaration](#declaration)
    - [Associated Value](#associated-value)
  - [How Errors Are Delivered](#how-errors-are-delivered)
- [Error Cases](#error-cases)
  - [1. Capability](#1-capability)
  - [2. Engagement](#2-engagement)
  - [3. Transport](#3-transport)
  - [4. Session](#4-session)
  - [5. Codec](#5-codec)
  - [6. Policy / Usage](#6-policy--usage)
- [Supporting Types](#supporting-types)
  - [CapabilityReason](#capabilityreason)
  - [RequiredAction](#requiredaction)
- [CancellationError](#cancellationerror)
- [Not Errors: Verification Results](#not-errors-verification-results)
- [Logging](#logging)


## MdocProximityError

### Description
```
Error enum for the mdoc proximity SDK (ISO/IEC 18013-5 device retrieval).
Every SDK failure is reported as one of these cases. There are no numeric codes;
the case itself is the code, and associated values carry the detail.
Cases are grouped into six categories: capability, engagement, transport,
session, codec, and policy/usage.
```

### Declaration
```swift
public enum MdocProximityError: Error, Equatable {
    // capability
    case bleUnavailable(reason: CapabilityReason)
    case nfcUnavailable(reason: CapabilityReason)
    case wifiAwareUnavailable(reason: CapabilityReason)
    case configurationRequired(action: RequiredAction)
    // engagement
    case malformedEngagement(detail: String)
    case unsupportedTransmissionTechnology
    case engagementTimeout
    // transport
    case connectionFailed(detail: String)
    case peerDisconnected
    case transferTimeout
    // session
    case sessionEncryptionFailed
    case counterMismatch
    case terminatedByPeer(status: UInt64)
    // codec
    case decodeFailed(detail: String)
    case validationFailed(detail: String)
    // policy / usage
    case responseTimeout
    case invalidState(current: String, attempted: String)
}
```

### Associated Value

| Name      | Type               | Description                                                       | **Used by**                                               | **Note** |
|-----------|--------------------|-------------------------------------------------------------------|-----------------------------------------------------------|----------|
| reason    | `CapabilityReason` | Why the transport cannot be used. The app cannot fix it           | `bleUnavailable`, `nfcUnavailable`, `wifiAwareUnavailable` | See [CapabilityReason](#capabilityreason) |
| action    | `RequiredAction`   | What the app or user must do to make the transport usable          | `configurationRequired`                                   | See [RequiredAction](#requiredaction) |
| detail    | `String`           | Short structural description of the failure, for diagnostics only | `malformedEngagement`, `connectionFailed`, `decodeFailed`, `validationFailed` | Not intended for end users. Do not parse |
| status    | `UInt64`           | `SessionData.status` value received from the peer, as received    | `terminatedByPeer`                                        | `10`, `11`, or `20` |
| current   | `String`           | Session state (or active-session description) at the time of the call | `invalidState`                                        |          |
| attempted | `String`           | Name of the operation that was rejected                           | `invalidState`                                            | e.g. `start`, `connect`, `request` |

<br>

## How Errors Are Delivered

| Role        | Path | When |
|-------------|------|------|
| mdoc        | `throw` from `MdocDeviceSession.start(technology:)`, `respond(deviceResponse:)`, `reject()` | Failures inside the call itself. A send failure in `respond` / `reject` moves the state to `failed` and is **not** also delivered to `didFailWith` |
| mdoc        | `MdocDeviceSessionDelegate.mdocSession(_:didFailWith:)` | Failures after `start` returned (engagement/response timeout, link loss, session decryption, peer status). State becomes `failed` |
| mdoc reader | `throw` from `MdocReaderSession.connect(to:)`, `connectViaNFC()`, `request(_:at:)` | Failures inside the call itself. An error that is thrown is **not** also delivered to `didFailWith` |
| mdoc reader | `MdocReaderSessionDelegate.readerSession(_:didFailWith:)` | Only when the link fails while the session is idle in `connected` (outside any `connect`/`request` call). State becomes `failed` |
| either      | `EngagementPayload.parse(qrString:)`, `ItemsRequestSpec` JSON decoding | Synchronous `throw`; no session state is involved |

Notes for `MdocReaderSession.request(_:at:)`:

- If `request` throws, the session state is always `failed`, **except** for entry errors raised before anything is sent: `invalidState`, and `validationFailed` for an empty request array or a duplicated `docType`. Those leave the state at `connected` and do not consume the one-request-per-session allowance, so the app can fix the input and call again.
- A response that decrypts and decodes successfully is never an error, even if verification fails. See [Not Errors: Verification Results](#not-errors-verification-results).

<br>

# Error Cases

## 1. Capability

Capability errors use the same vocabulary as `MdocCapabilities.current()`. `unsupported(reason:)` in the capability query corresponds to `bleUnavailable` / `nfcUnavailable` / `wifiAwareUnavailable`, and `configurationRequired(action:)` corresponds to the error of the same name. When the set of candidate transports is empty because of the device's capability (Bluetooth off, permission denied, no radio), `start()` and `connect()` throw one of these cases rather than `unsupportedTransmissionTechnology`.

| Case | Associated Value | Description | Action |
|------|------------------|-------------|--------|
| bleUnavailable | `reason: CapabilityReason` | BLE cannot be used on this device. On iOS this is raised as `.noHardware` when Core Bluetooth reports the radio as unsupported, either at `start()`/`connect()` or when a BLE transport is opened | The app cannot fix this. Guide the user to another engagement or transport method |
| nfcUnavailable | `reason: CapabilityReason` | NFC cannot be used. `.vendorPolicy`: the mdoc side requested an NFC engagement or NFC data retrieval without an injected card emulation (`nfcCardEmulation:` in `MdocDeviceSession.init`); the SDK does not implement HCE. `.noHardware`: on the reader side, the device cannot start an NFC tag reader session (`connectViaNFC()`) | Guide the user to QR + BLE. For `.vendorPolicy` on the mdoc side, NFC is available only when an authorized app injects card emulation |
| wifiAwareUnavailable | `reason: CapabilityReason` | Wi-Fi Aware cannot be used. On iOS this is always `.vendorPolicy`, in both roles. Raised when Wi-Fi Aware is selected as the transport | Guide the user to another transport. On the reader side, keep Wi-Fi Aware out of the transmission priority or rely on the other transports the peer advertises |
| configurationRequired | `action: RequiredAction` | The transport is usable once the app or user changes something. On iOS: Bluetooth is powered off (`.enableBluetooth`), Bluetooth permission is denied (`.grantPermission("bluetooth")`), or the reader NFC `select-identifiers` entry is missing (`.addEntitlement(...)`) | Show a settings or permission prompt according to `action`. `.addEntitlement` is a developer integration issue, not an end-user issue |

<br>

## 2. Engagement

| Case | Associated Value | Description | Action |
|------|------------------|-------------|--------|
| malformedEngagement | `detail: String` | The device engagement could not be parsed. Raised by `EngagementPayload.parse(qrString:)` (missing `mdoc:` scheme, invalid base64url), while reading the NFC engagement (bad CC file, empty or truncated NDEF, no device engagement record, Handover Select without device engagement, NDEF read failure), or when the engagement advertises a BLE mode without its service UUID | Ask the user to rescan the QR code or tap again |
| unsupportedTransmissionTechnology | - | No common transport. This is a policy or advertisement mismatch, not a device-capability problem: the peer advertises only transports this SDK does not handle, the reader's transmission priority excludes what the peer advertises, or the only advertised BLE modes carry no UUID. On the mdoc side it is also raised when nothing can be advertised and the device capability is not the cause | Inform the user that the two devices cannot connect with the current settings. Review the reader's transmission priority or the mdoc's BLE advertise mode |
| engagementTimeout | - | mdoc side: no reader connected within `MdocDeviceConfiguration.engagementTimeout` after `start()`. Delivered through `didFailWith` | Restart the session with a new `start()` |

<br>

## 3. Transport

| Case | Associated Value | Description | Action |
|------|------------------|-------------|--------|
| connectionFailed | `detail: String` | The link could not be established or failed at the transport level. Examples: BLE connect failure, service not found, service registration failure, MTU too small, L2CAP stream error; reader `connecting` not completed within `connectTimeout` (`detail: "connect timeout"`); NFC negotiated handover failure (TNEP service select rejected, Handover Request rejected or too large, TNEP wait exhausted); NFC tag reader session invalidated for any reason other than user cancellation (the system time limit of about 60 seconds ran out, entitlement problems) | Retry. If it repeats, start a new session |
| peerDisconnected | - | The peer closed the link, or the link was lost, before the exchange finished. On the reader side, this is reported through `didFailWith` when the link drops while idle in `connected`, and thrown from `request` when the link closes while waiting for the response | Inform the user that the other device disconnected, then start a new session |
| transferTimeout | - | Reserved for a transport-level timeout while receiving the parts of a message. The current iOS SDK does not raise this case; a response that does not arrive in time is reported as `responseTimeout` | Restart the session. Handle it in exhaustive `switch` statements |

<br>

## 4. Session

| Case | Associated Value | Description | Action |
|------|------------------|-------------|--------|
| sessionEncryptionFailed | - | Session encryption failed on this device: AES-GCM decryption of a `SessionData` message failed, encryption failed, the peer's ephemeral key is not a valid P-256 point, or the message counter is exhausted. A decryption failure typically indicates a `SessionTranscript` mismatch between the two devices | Restart the session |
| counterMismatch | - | The received message counter is not the expected value | Terminate the session immediately. Do not retry within the same session |
| terminatedByPeer | `status: UInt64` | The peer sent a `SessionData.status` without data. The received value is preserved: `20` = the peer ended the session normally (on the reader side, a holder declining or not holding the document arrives this way), `10` / `11` = the peer reported its own session encryption or CBOR decoding failure. On the reader side any status ends `request` with this error, the state becomes `failed` and the SDK closes the link. On the mdoc side, status `20` is not an error (state becomes `terminated`); only `10` / `11` are reported through `didFailWith`, with the state `failed` and the link closed by the SDK | `20`: treat as normal termination (reader: "the holder did not share"). `10` / `11`: show an error and start a new session. Do not confuse with an empty response, which completes normally with a `VerifiedResponse` |

> `terminatedByPeer(status: 10/11)` is not mapped to `sessionEncryptionFailed` or `decodeFailed`. A failure on this device and a failure reported by the peer are different events, and the app may need to handle them differently.

<br>

## 5. Codec

| Case | Associated Value | Description | Action |
|------|------------------|-------------|--------|
| decodeFailed | `detail: String` | Bytes could not be decoded. Covers CBOR decoding errors, malformed BLE message parts or a message exceeding 512 KiB, malformed NFC APDU / TLV / ENVELOPE data, an empty `SessionData` envelope, and decoding of the SDK's own `ItemsRequestSpec` JSON format (bad structure, unknown `version`) | Restart the session. For `ItemsRequestSpec` JSON, check the stored request profile |
| validationFailed | `detail: String` | The data decoded but its structure is invalid. Examples: `DeviceEngagement` not a map or with a bad security/cipher suite, `SessionEstablishment` missing a field, `DeviceResponse` missing `version`/`status` or with a malformed `COSE_Sign1`/`COSE_Mac0`, invalid MSO structure, invalid `COSE_Key` (not EC2/P-256), a response with the same `elementIdentifier` twice in a namespace. Also raised as an entry error by `request(_:at:)` when the request array is empty or contains the same `docType` twice | For entry errors, fix the request and call `request` again (state stays `connected`). Otherwise restart the session |

<br>

## 6. Policy / Usage

| Case | Associated Value | Description | Action |
|------|------------------|-------------|--------|
| responseTimeout | - | The response was not completed within `responseTimeout`, in either role. mdoc: the app did not call `respond` / `reject` in time after a request arrived; delivered through `didFailWith`. Reader: no response arrived while `awaitingResponse`; thrown from `request` and the state becomes `failed` | Restart the session |
| invalidState | `current: String`, `attempted: String` | The call is not allowed in the current state. Examples: calling `start` / `connect` / `connectViaNFC` on a session that is not `idle`, calling `request` twice or after `completed`, `respond` / `reject` outside the response phase, reusing a terminated session, or opening a second session while another session in the process is still active (`current` is then `"active session: ..."`). On the mdoc side, a second `DeviceRequest` in the same session is answered with a session termination (status 20): while waiting for the app's answer the session ends as `terminated`, and after `completed` the state stays `completed` | This is an app bug. Call `terminate()` on the previous session and use a new session object |

<br>

# Supporting Types

## CapabilityReason

### Description
```
Why a transport cannot be used. The app cannot fix any of these reasons.
Used by bleUnavailable / nfcUnavailable / wifiAwareUnavailable and by
TransportCapability.unsupported(reason:) in the capability query.
```

### Declaration
```swift
public enum CapabilityReason: Equatable {
    case noHardware
    case osVersion
    case vendorPolicy
}
```

| Case | Description | Action |
|------|-------------|--------|
| noHardware | The device has no usable radio for this transport (Core Bluetooth reports `unsupported`, or an NFC tag reader session cannot be created) | Guide the user to another transport |
| osVersion | The transport requires a newer OS version. Not produced on iOS currently | Guide the user to another transport |
| vendorPolicy | The OS vendor's API surface or approval policy does not let the app use this transport. On iOS: mdoc NFC presentation without injected card emulation, and Wi-Fi Aware in both roles | Guide the user to QR + BLE |

<br>

## RequiredAction

### Description
```
What the app or user must do before the transport can be used.
Used by configurationRequired(action:) and by
TransportCapability.configurationRequired(action:) in the capability query.
```

### Declaration
```swift
public enum RequiredAction: Equatable {
    case enableBluetooth
    case enableNfc
    case enableWifi
    case enableLocationServices
    case grantPermission(String)
    case addEntitlement(String)
}
```

| Case | Associated Value | Description | Action |
|------|------------------|-------------|--------|
| enableBluetooth | - | Bluetooth is powered off. The SDK does not show the system "Turn on Bluetooth" alert | Show your own guidance screen asking the user to turn on Bluetooth |
| enableNfc | - | NFC is turned off. Not produced on iOS currently | Ask the user to enable NFC |
| enableWifi | - | Wi-Fi is off. Not produced on iOS currently | Ask the user to enable Wi-Fi |
| enableLocationServices | - | Location services are off. Not produced on iOS currently | Ask the user to enable location services |
| grantPermission | `String` | A permission is denied. On iOS the value is `"bluetooth"` (Core Bluetooth authorization denied or restricted) | Guide the user to grant Bluetooth access in Settings |
| addEntitlement | `String` | A required entitlement or `Info.plist` entry is missing. On iOS: `"com.apple.developer.nfc.readersession.iso7816.select-identifiers"` for the reader NFC path | Developer action: add the entitlement and the `select-identifiers` entries to the app. Not an end-user issue |

<br>

# CancellationError

In addition to `MdocProximityError`, some calls throw Swift's `CancellationError`. It means the operation was cancelled, not that it failed; the session state is `terminated`, the same as after `terminate()`. Handle it separately and return to the previous screen without showing an error.

| API | When `CancellationError` is thrown | Resulting state |
|-----|------------------------------------|-----------------|
| `MdocDeviceSession.start(technology:)` | `terminate()` was called before `start` returned | `terminated` |
| `MdocReaderSession.connectViaNFC()` | The user cancelled the system NFC sheet | `terminated` |
| `MdocReaderSession.connect(to:)` / `connectViaNFC()` | The calling `Task` was cancelled while `connecting` | `terminated` |

Other NFC sheet invalidations (the system time limit of about 60 seconds ran out, entitlement problems) are reported as `connectionFailed(detail:)` and the state becomes `failed`.

```swift
do {
    let payload = try await reader.connectViaNFC()
    // ...
} catch is CancellationError {
    // User or app cancelled. Return quietly.
} catch let error as MdocProximityError {
    // Map to a user message.
}
```

<br>

# Not Errors: Verification Results

Verification outcomes such as an untrusted issuer, invalid device authentication, digest mismatch, or expired validity are **not** `MdocProximityError` cases. When the response decrypts and decodes successfully, `request(_:at:)` returns a `VerifiedResponse`, the state becomes `completed`, and the verification outcome is carried as values inside `VerifiedResponse`.

<br>

# Logging

The `detail` strings contain structural information only (field names, lengths, counts, states). Element values, session keys, plaintext responses, digests, signatures, and values derived from the response are never included in errors or logs. Apps should follow the same rule when logging errors.
