# DarkSight first-time setup (Windows / PowerShell).
# Generates the android/ and ios/ runner projects, adds the permissions the
# three tiers need, and fetches packages. Safe to run more than once.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

flutter create --platforms=android,ios,web --org com.darksight --project-name darksight .
if ($LASTEXITCODE -ne 0) { throw "flutter create failed" }

# flutter create adds a counter-app widget test that does not apply here.
if (Test-Path "test/widget_test.dart") { Remove-Item "test/widget_test.dart" }

$manifest = Join-Path $PSScriptRoot "android/app/src/main/AndroidManifest.xml"
$xml = [System.IO.File]::ReadAllText($manifest)
if ($xml -notmatch "BLUETOOTH_SCAN") {
    $perms = @'
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
    <application
'@
    $xml = ([regex]'[ \t]*<application').Replace($xml, $perms, 1)
    [System.IO.File]::WriteAllText($manifest, $xml)
    Write-Host "Patched AndroidManifest.xml"
}

$plist = Join-Path $PSScriptRoot "ios/Runner/Info.plist"
if (Test-Path $plist) {
    $p = [System.IO.File]::ReadAllText($plist)
    if ($p -notmatch "NSBluetoothAlwaysUsageDescription") {
        $keys = @'
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>DarkSight uses Bluetooth to pair with external radar modules.</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>DarkSight receives radar frames from a bridge on your network.</string>
</dict>
</plist>
'@
        $p = ([regex]'</dict>\s*</plist>\s*$').Replace($p, $keys, 1)
        [System.IO.File]::WriteAllText($plist, $p)
        Write-Host "Patched Info.plist"
    }
}

flutter pub get
Write-Host ""
Write-Host "Done. Start an emulator or plug in a phone, then:  flutter run"
