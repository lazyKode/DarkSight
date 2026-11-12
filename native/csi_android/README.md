# Raw CSI on Android (not implemented)

Stock Android has no API for channel state information, and
`CHANGE_WIFI_STATE` does not unlock one. Getting per-subcarrier CSI on a
phone means:

1. A phone with a supported Broadcom chip (e.g. BCM4358 in the Nexus 6P,
   BCM4339 in the Nexus 5) or a Qualcomm device with a vendor CSI/RTT debug
   interface.
2. Root, plus patched Wi-Fi firmware such as **Nexmon CSI**
   (https://github.com/seemoo-lab/nexmon_csi).
3. A reader for the UDP packets the patched firmware emits on the monitor
   interface (port 5500 for Nexmon), which is what `csi_reader.cpp` is
   reserved for.

The chips named in the original spec (Intel AX200/AX210, MediaTek MT7921)
are laptop/M.2 cards; their CSI tools (PicoScenes, FeitCSI) run on Linux
PCs, not phones.

Integration point once a reader exists: push one amplitude vector per packet
into `MotionDetector.update(List<double>, dt)` from
`lib/core/csi_radar_source.dart` in place of the single RSSI value. The
detector already handles vectors.
