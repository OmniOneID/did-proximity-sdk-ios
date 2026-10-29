# 📁 Documentation Structure Guide

All documents in this folder describe the public API of the SDK — the surface an mdoc app or an mdoc reader app uses.

- `public/` — for features accessible to users or intended for external use

---

## 📂 Folder Overview

### `public/`

| Document | Description |
|----------|-------------|
| [MdocDeviceAPI](public/MdocDeviceAPI.md) ([ko](public/MdocDeviceAPI_ko.md)) | mdoc (holder) session — engagement, request handling, response |
| [MdocReaderAPI](public/MdocReaderAPI.md) ([ko](public/MdocReaderAPI_ko.md)) | mdoc reader (verifier) session — engagement intake, request, response |
| [MdocTrust](public/MdocTrust.md) ([ko](public/MdocTrust_ko.md)) | Trust configuration for issuer data authentication |
| [DataModel](public/DataModel.md) ([ko](public/DataModel_ko.md)) | Shared types — identifiers, values, transports, verification results, capabilities |
| [MdocProximityError](public/MdocProximityError.md) | Errors thrown by the SDK |

Internal modules (CBOR/COSE, codecs, transports) are not part of the public API and are not documented here.
