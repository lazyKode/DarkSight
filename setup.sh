#!/usr/bin/env bash
# DarkSight first-time setup (macOS / Linux). Safe to run more than once.
set -euo pipefail
cd "$(dirname "$0")"

flutter create --platforms=android,ios,web --org com.darksight --project-name darksight .
rm -f test/widget_test.dart

python3 - <<'PY'
import os, re
m = "android/app/src/main/AndroidManifest.xml"
xml = open(m, encoding="utf-8").read()
if "BLUETOOTH_SCAN" not in xml:
    perms = """    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
    <application"""
    xml = re.sub(r"[ \t]*<application", lambda _: perms, xml, count=1)
    open(m, "w", encoding="utf-8").write(xml)
    print("Patched AndroidManifest.xml")
p = "ios/Runner/Info.plist"
if os.path.exists(p):
    s = open(p, encoding="utf-8").read()
    if "NSBluetoothAlwaysUsageDescription" not in s:
        keys = """\t<key>NSBluetoothAlwaysUsageDescription</key>
\t<string>DarkSight uses Bluetooth to pair with external radar modules.</string>
\t<key>NSLocalNetworkUsageDescription</key>
\t<string>DarkSight receives radar frames from a bridge on your network.</string>
</dict>
</plist>
"""
        s = re.sub(r"</dict>\s*</plist>\s*$", lambda _: keys, s, count=1)
        open(p, "w", encoding="utf-8").write(s)
        print("Patched Info.plist")
PY

flutter pub get
echo
echo "Done. Start an emulator or plug in a phone, then:  flutter run"
