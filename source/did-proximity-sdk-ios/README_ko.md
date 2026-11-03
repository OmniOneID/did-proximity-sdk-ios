# iOS mdoc Proximity SDK Guide
본 문서는 mdoc Proximity SDK 사용을 위한 가이드로,
iOS 에서 ISO/IEC 18013-5 device retrieval 을 수행하는 기능을 제공한다. 소지자 앱(mdoc)은 mdoc 을 제시하고, 검증자 앱(mdoc reader)은 이를 요청·검증한다. engagement 는 QR 또는 NFC, 데이터 전송은 BLE 또는 NFC 로 수행한다.


## S/W 사양
| 구분              | 내용                          |
|-------------------|-----------------------------|
| OS                | iOS                         |
| Language          | Swift 5                     |
| IDE               | Xcode 27.0                  |
| Compatibility     | iOS 17.0 이상                |
| Standard          | ISO/IEC 18013-5:2021 — device retrieval |
| Test Environment  | iPhone 14 (실기기)            |


## 빌드 방법
: 이 폴더(`source/did-proximity-sdk-ios`)에서 터미널을 열고 XCFramework를 생성하기 위해 스크립트 `build_xcframework.sh`을 실행합니다.
1. 터미널 앱을 실행하고 다음 명령을 입력합니다.
    ```bash
    $ ./build_xcframework.sh
    ```
2. 아카이브가 완료되면 `source/release/did-proximity-sdk-ios-<버전>/` 폴더에 `MdocProximitySDK.xcframework` 파일이 생성됩니다.

### 검증
배포 산출물을 앱이 실제로 쓸 수 있는지 두 스크립트로 확인합니다.

| 스크립트                  | 확인 내용                                                              |
|--------------------------|------------------------------------------------------------------------|
| `verify_xcframework.sh`  | XCFramework 가 공개 API 만 노출하는지 확인 (빌드 후 실행, 버전을 인자로 받으며 기본값 `1.0.0`) |
| `verify_spm_products.sh` | SPM product 마다 `import` 한 줄로 공용 모듈까지 쓸 수 있는지 확인          |

```bash
$ ./verify_xcframework.sh
$ ./verify_spm_products.sh
```
<br>

## SDK 적용 방법
1. 앱 프로젝트의 프레임워크 디렉토리에 `MdocProximitySDK.xcframework` 파일을 복사합니다.
2. 앱 프로젝트 의존성에 프레임워크를 추가합니다.
    ```text
    MdocProximitySDK.xcframework
    ```
3. 프레임워크를 `Embed & Sign`으로 설정합니다.

XCFramework 는 두 역할을 모두 담은 모듈 하나입니다:

```swift
import MdocProximitySDK
```
<br>

## Swift Package 적용 방법
패키지는 역할마다 product 를 하나씩 제공합니다. 앱은 자기 역할의 product 하나만 추가하면 됩니다. 공용 모듈은 의존성으로 함께 들어오고, `import` 도 한 줄이면 됩니다.

| Product      | 앱                            | Import              |
|--------------|------------------------------|---------------------|
| `MdocDevice` | mdoc 앱 (소지자)               | `import MdocDevice` |
| `MdocReader` | mdoc reader 앱 (검증자)        | `import MdocReader` |

### 적용 절차
1. **Xcode → 프로젝트 → Package Dependencies**로 이동합니다.
2. **“+”** 버튼을 클릭합니다.
3. 다음 Swift Package URL을 입력합니다.
    ```text
    https://github.com/OmniOneID/did-proximity-sdk-ios.git
    ```
4. **Version ≥ 1.0.0**을 선택합니다.
5. 앱 역할에 맞는 product 를 타깃에 추가합니다.

### 참고사항
- SPM을 사용할 경우 XCFramework를 수동으로 추가할 필요가 없습니다.
<br>

## 앱 설정
| 키 | 역할 | 필요한 경우 |
|-----|------|----------|
| `NSBluetoothAlwaysUsageDescription` (Info.plist) | mdoc, mdoc reader | BLE |
| `NSCameraUsageDescription` (Info.plist) | mdoc reader | QR 스캔 (앱이 수행) |
| `NFCReaderUsageDescription` (Info.plist) | mdoc reader | NFC |
| `com.apple.developer.nfc.readersession.iso7816.select-identifiers` (Info.plist) | mdoc reader | NFC — `D2760000850101` 먼저, 그다음 `A0000002480400` |
| `com.apple.developer.nfc.readersession.formats = [TAG]` (Entitlements) | mdoc reader | NFC |

`select-identifiers` 는 순서가 중요합니다. `A0000002480400` 이 앞에 오면 리더가 engagement 를 건너뜁니다. 항목이 없거나 순서가 뒤집혀 있으면 `MdocCapabilities.current()` 가 `configurationRequired(.addEntitlement(...))` 로 알려 줍니다.

mdoc 측 NFC engagement(iOS 카드 에뮬레이션)에 필요한 엔타이틀먼트는 이 SDK 가 가질 수 없으므로 앱이 주입합니다. [MdocDevice API](../../docs/api/public/MdocDeviceAPI_ko.md) 를 참조하세요.

<br>

## API 규격서
| 구분                | API 문서 링크                                                  |
|--------------------|---------------------------------------------------------------|
| MdocDevice         | [mdoc API](../../docs/api/public/MdocDeviceAPI_ko.md)         |
| MdocReader         | [mdoc reader API](../../docs/api/public/MdocReaderAPI_ko.md)  |
| MdocTrust          | [신뢰 API](../../docs/api/public/MdocTrust_ko.md)              |
| DataModel          | [데이터 모델](../../docs/api/public/DataModel_ko.md)            |
| MdocProximityError | [오류](../../docs/api/public/MdocProximityError.md)            |
