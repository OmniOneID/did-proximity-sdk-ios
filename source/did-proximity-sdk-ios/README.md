# iOS mdoc Proximity SDK Guide
This document is a guide for using the mdoc Proximity SDK. The SDK provides ISO/IEC 18013-5 device retrieval on iOS: presenting an mdoc from a holder app (mdoc), and requesting and verifying it from a verifier app (mdoc reader). Engagement runs over QR or NFC, and data retrieval runs over BLE or NFC.


## S/W Specification
| Category         | Details                     |
|------------------|-----------------------------|
| OS               | iOS                         |
| Language         | Swift 5                     |
| IDE              | Xcode 27.0                  |
| Compatibility    | iOS 17.0 and higher         |
| Standard         | ISO/IEC 18013-5:2021 — device retrieval |
| Test Environment | iPhone 14 (device)          |


## Build Method
: Open a terminal in this folder (`source/did-proximity-sdk-ios`) and run the script `build_xcframework.sh` to build XCFramework.
1. Launch the Terminal app and type the following:
    ```bash
    $ ./build_xcframework.sh
    ```
2. Once the archive is complete, a `MdocProximitySDK.xcframework` file will be created in the `source/release/did-proximity-sdk-ios-<version>/` folder.

### Verification
Two scripts check that the distributed artifacts can be consumed by apps.

| Script                   | Checks                                                                 |
|--------------------------|------------------------------------------------------------------------|
| `verify_xcframework.sh`  | The XCFramework exposes only the public API (run after the build; takes the version as an optional argument, default `1.0.0`) |
| `verify_spm_products.sh` | Each SPM product brings the shared modules along with a single `import` |

```bash
$ ./verify_xcframework.sh
$ ./verify_spm_products.sh
```
<br>

## SDK Application Method
1. Copy the `MdocProximitySDK.xcframework` file to the framework directory of the app project.
2. Add the framework to your app project dependencies.
    ```text
    MdocProximitySDK.xcframework
    ```
3. Set the framework to `Embed & Sign`.

The XCFramework is a single module that holds both roles:

```swift
import MdocProximitySDK
```
<br>

## Swift Package Integration
The package provides one product per role. An app adds only the product for its role — shared modules come along as dependencies, and a single `import` line is enough.

| Product      | App                          | Import              |
|--------------|------------------------------|---------------------|
| `MdocDevice` | mdoc app (holder)            | `import MdocDevice` |
| `MdocReader` | mdoc reader app (verifier)   | `import MdocReader` |

### How to Apply
1. Open **Xcode → Project → Package Dependencies**.
2. Click the **“+”** button.
3. Enter the SDK's Swift Package URL:
    ```text
    https://github.com/OmniOneID/did-proximity-sdk-ios.git
    ```
4. Select **Version ≥ 1.0.0**.
5. Add the product for your app's role to your target.

### Notes
- When using SPM, manual XCFramework embedding is not required.
<br>

## App Configuration
| Key | Role | Required |
|-----|------|----------|
| `NSBluetoothAlwaysUsageDescription` (Info.plist) | mdoc, mdoc reader | BLE |
| `NSCameraUsageDescription` (Info.plist) | mdoc reader | QR scanning (done by the app) |
| `NFCReaderUsageDescription` (Info.plist) | mdoc reader | NFC |
| `com.apple.developer.nfc.readersession.iso7816.select-identifiers` (Info.plist) | mdoc reader | NFC — `D2760000850101` first, then `A0000002480400` |
| `com.apple.developer.nfc.readersession.formats = [TAG]` (Entitlements) | mdoc reader | NFC |

The order of `select-identifiers` matters: if `A0000002480400` comes first, the reader skips engagement. `MdocCapabilities.current()` reports a missing or reversed entry as `configurationRequired(.addEntitlement(...))`.

NFC engagement on the mdoc side (iOS card emulation) needs an entitlement this SDK cannot hold, so the app injects it. See [MdocDevice API](../../docs/api/public/MdocDeviceAPI.md).

<br>

## Logging
The SDK log is **off by default**. Turn it on in the app to capture what led up to a problem — once a session has failed, the moment is gone.

```swift
MdocLog.level = .debug                         // .off (default) / .error / .warning / .info / .debug
MdocLog.handler = { entry in
    logFile.append(entry.formatted)            // 2026-11-06T09:12:03.120Z [INFO] [session] reader state connecting -> connected
}
MdocLog.systemLogEnabled = true                // also write to Console.app (default true)
```

| Level | What is logged |
|-------|----------------|
| `.error` | Failures that end a session |
| `.warning` | Recoverable problems — L2CAP falling back to GATT, a candidate transport lost, a Handover Request refused |
| `.info` | Session lifecycle — state changes, engagement, the transport chosen, messages sent and received, verification results |
| `.debug` | Link-level detail — candidate transport events, BLE parts and MTU, NFC APDU status words |

- In Console.app, filter by subsystem `com.omnione.mdocproximity`. Categories are `session`, `engagement`, `transport`, `ble`, `nfc`, `verify`.
- `handler` runs on an SDK-internal serial queue, in the order the entries were made. It may call back into the SDK.
- Keys, the SessionTranscript, message contents and data element values are **never logged** at any level — only states, kinds, lengths and status codes.
- `MdocLog` is available from `import MdocProximitySDK`, `import MdocDevice` and `import MdocReader`.

<br>

## API Specification
| Category           | API Document Link                                             |
|--------------------|---------------------------------------------------------------|
| MdocDevice         | [mdoc API](../../docs/api/public/MdocDeviceAPI.md)            |
| MdocReader         | [mdoc reader API](../../docs/api/public/MdocReaderAPI.md)     |
| MdocTrust          | [Trust API](../../docs/api/public/MdocTrust.md)               |
| DataModel          | [Data Model](../../docs/api/public/DataModel.md)              |
| MdocProximityError | [Error](../../docs/api/public/MdocProximityError.md)          |
