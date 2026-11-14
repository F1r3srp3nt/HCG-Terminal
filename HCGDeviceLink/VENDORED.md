# HCGDeviceLink (vendored)

This directory is an unmodified copy of `clients/swift/HCGDeviceLink` from
HCG-Server (client version 1.0.0, HCG-Server commit b163ddd): the HCG Device
Link client (`hcg.devicelink/1`) shared by HCG Sentinel, HCG Terminal and
HCG Nexus. The protocol is documented in HCG-Server `docs/DEVICE-LINK.md`.

Do not edit these files here. Change HCG-Server and run
`scripts/vendor-devicelink.sh <this directory>` again. CI checks the copy with
`shasum -a 256 -c VENDORED.sha256`.
