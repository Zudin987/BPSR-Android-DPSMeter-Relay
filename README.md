# BPSR Android DPSMeter Relay

A small Windows helper for routing **Blue Protocol: Star Resonance Android traffic** through a PC so a compatible DPS meter such as ZDPS can observe the `StarSEA` relay process.

The goal is to make the setup as close to **open manager -> setup -> import profile -> start** as possible.

> [!IMPORTANT]
> In the DPS meter, capture **`StarSEA` only**. Do **not** capture `BPSRMobileFront` as well, or the same traffic can be observed twice and DPS may be doubled.

## What you need

- Windows 10/11 PC
- Android phone running BPSR
- SFA / sing-box-compatible Android client
- Your DPS meter / ZDPS on the PC
- Phone and PC on the same local network

You do **not** need to manually download or rename `sing-box.exe`.

## Quick start

### 1. Open the manager

Download/extract the repository and double-click:

```text
BPSR Relay Manager.bat
```

The manager tries to select the most likely Wi-Fi/Ethernet IPv4 address automatically. If it chooses the wrong one, select or type the PC address that your phone can reach, usually something like `192.168.x.x`.

### 2. Click `Setup / Repair`

This automatically:

- detects Windows x64/ARM64
- checks the latest official SagerNet/sing-box GitHub release
- downloads the matching Windows ZIP
- verifies SHA256 when a matching checksum is published
- creates `BPSRMobileFront.exe`
- creates `StarSEA.exe`
- generates the two PC relay configurations
- generates `output/android-bpsr-relay.json` using your selected PC LAN IP

### 3. Click `Allow Phone Through Firewall`

Windows will request Administrator permission once.

The manager creates an inbound **TCP 10902** rule for the **Private** Windows network profile only.

### 4. Import the Android profile

Click `Open Android Profile Folder` and import:

```text
output/android-bpsr-relay.json
```

into SFA on the Android phone.

Enable that profile before starting BPSR.

### 5. Configure ZDPS / your DPS meter

Use:

```text
Capture Process: StarSEA
Listen IP:       127.0.0.1
Listen Port:     10903
```

The manager also has a **Copy ZDPS Settings** button.

> [!WARNING]
> Capture **`StarSEA` only**. Do not add `BPSRMobileFront` to capture rules.

### 6. Click `START RELAY`

Both relay processes run hidden in the background.

You can close the manager window without stopping them. Open the manager again and use **STOP RELAY** when you actually want to stop the relay.

## Traffic flow

```text
Android BPSR
    |
    | selected BPSR TCP ports via SFA
    v
PC :10902
BPSRMobileFront.exe
    |
    | local SOCKS
    v
127.0.0.1:10903
StarSEA.exe   <--- DPS meter captures this process only
    |
    v
BPSR game server
```

Only these BPSR TCP ports are routed through the PC relay by the generated Android profile:

```text
15000, 16000, 17000, 18000, 20000, 20001, 21000
```

Other Android traffic uses the normal direct route.

## Files created at runtime

The manager keeps generated/downloaded files out of the Git repository:

```text
.runtime/
  sing-box.exe
  BPSRMobileFront.exe
  StarSEA.exe
  config/
  pids.json

output/
  android-bpsr-relay.json
  README-IMPORT.txt
```

`.runtime/` and `output/` are ignored by Git.

## Updating

Normally just open the manager and press **Setup / Repair** again.

It checks the latest official sing-box release and refreshes the generated relay/profile files. You no longer need a separate v4/v5 folder just to update the relay runtime.

If your PC LAN IP changes, select the new IP and run **Setup / Repair** again, then re-import the newly generated Android profile into SFA.

## Troubleshooting

### Phone cannot connect / BPSR has no network

Check that:

- phone and PC are on the same LAN/Wi-Fi
- the manager is using the correct PC LAN IPv4
- the Windows network is set to **Private**
- you clicked **Allow Phone Through Firewall**
- the generated SFA profile is enabled
- the relay status says **RUNNING**

If the PC address changed, run **Setup / Repair** again and re-import the Android JSON.

### DPS meter shows nothing

Confirm the DPS meter is configured for:

```text
Process: StarSEA
IP:      127.0.0.1
Port:    10903
```

Then confirm both relay processes are running.

### DPS appears exactly doubled

Make sure your capture configuration observes **`StarSEA` only**. Do not capture both relay processes.

### Setup / Repair says an untracked relay is already running

The manager intentionally refuses to kill a process it did not start/record. Close the old relay process manually, then run Setup / Repair again.

## Safety / transparency

- The repository does not bundle a modified `sing-box.exe`.
- The manager downloads sing-box from the official **SagerNet/sing-box GitHub release** at setup time.
- SHA256 is checked when the release exposes a matching checksum entry.
- The Windows inbound firewall rule is limited to TCP `10902` and the **Private** network profile.
- STOP RELAY only terminates the recorded relay PIDs when the process names match the expected relay names.

## Disclaimer

This is an unofficial community helper and is not affiliated with, endorsed by, or supported by the BPSR developers/publisher, ZDPS, SagerNet, or sing-box.
