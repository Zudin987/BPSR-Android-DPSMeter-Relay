# BPSR Android DPSMeter Relay

A lightweight Windows helper for routing **Blue Protocol: Star Resonance Android traffic** through a PC so ZDPS or another compatible packet-based DPS meter can observe a clean `StarSEA` process stream.

The design priorities are intentionally strict:

1. **Lowest practical latency**
2. **Prevent the same clear BPSR payload from appearing twice on the PC network path**
3. Convenience/features only after those two goals

## Why the relay is now single-process

Older relay designs used two PC proxy processes:

```text
Android -> front proxy -> localhost bridge -> StarSEA -> game server
```

That separated process names, but it also added another proxy hop. A raw SOCKS phone-to-PC leg could still place a second clear copy of the BPSR payload on a network adapter.

The current design is simpler:

```text
Android BPSR
    |
    | selected BPSR TCP ports through SFA
    | encrypted Shadowsocks tunnel
    v
StarSEA.exe on PC :10902
    |
    | direct clear connection
    v
BPSR game server
```

The phone-to-PC copy is encrypted. The clear BPSR payload appears only on the `StarSEA <-> game server` side, which is the side a DPS meter should parse.

This removes the old `BPSRMobileFront.exe` / localhost bridge entirely while retaining a clean `StarSEA` capture target.

## Requirements

- Windows 10/11 PC
- Android phone running BPSR
- SFA / sing-box-compatible Android client
- ZDPS or another compatible DPS meter on the PC
- Phone and PC on the same reachable LAN/Wi-Fi
- Windows network normally set to **Private** for the manager-created firewall rule

You do **not** manually download, rename, or configure sing-box on Windows.

## Quick start

### 1. Open the manager

Download/extract the repository and double-click:

```text
BPSR Relay Manager.bat
```

The manager tries to select the most likely physical Wi-Fi/Ethernet IPv4 automatically. If needed, choose the PC LAN address the phone can reach.

A small launcher wrapper keeps the PowerShell console hidden during normal use but shows a visible error dialog if the manager fails before its UI can open.

### 2. `Setup / Repair`

The manager:

- detects Windows x64/ARM64
- installs the **project-tested** sing-box release instead of blindly taking a new upstream release
- verifies the official GitHub release SHA256 digest
- stores a local SHA256 for future integrity checks
- keeps the previous verified runtime as a rollback when a tested runtime changes
- creates `StarSEA.exe`
- creates persistent encrypted relay credentials
- generates the PC relay configuration
- generates `output/android-bpsr-relay.json`
- validates the generated topology
- runs `sing-box check` on both PC and Android configurations
- removes obsolete two-process runtime files after successful migration

The current tested runtime is:

```text
sing-box v1.13.19
```

Routine `Setup / Repair` runs reuse the same relay credential, so a runtime repair does not force a new Android import unless the profile itself changes.

### 3. `Allow Firewall`

Windows asks for Administrator permission once.

The rule is restricted to:

- TCP `10902`
- selected PC LAN IPv4
- `LocalSubnet` remote addresses
- Windows **Private** network profile
- edge traversal blocked

No router port forwarding is required or recommended. If the active Windows network is Public or DomainAuthenticated, preflight warns instead of claiming this Private-only rule is active.

### 4. Get the profile onto the phone

Preferred method: click **Share to Phone**.

The manager starts a temporary local setup page on the same relay port while the gameplay relay is stopped. The URL is copied to the clipboard automatically.

The temporary server:

- has a random 128-bit path token
- is LAN-bound
- runs for at most 5 minutes
- stops after the profile is downloaded
- never runs during gameplay

You can also use **Show QR (optional)**. The QR rendering button opens QuickChart in your browser; the QR contains only the temporary LAN URL. If you do not want an online QR renderer, use **Copy Phone URL** instead.

Fallback: **Open Profile Folder** and manually transfer:

```text
output/android-bpsr-relay.json
```

Import the JSON into SFA.

In SFA, use per-app / selected-app routing and leave only BPSR selected after testing.

### 5. Configure ZDPS

ZDPS uses a network device plus executable-name capture preference. There is no relay `127.0.0.1:10903` setting in ZDPS.

Use:

```text
Network Device:
  your physical PC Wi-Fi/Ethernet adapter

Game Capture Preference:
  Custom

Custom BPSR Executable Name:
  StarSEA
```

Use `StarSEA` without `.exe`.

The manager has **Copy ZDPS Settings** to copy these settings.

### 6. `PREFLIGHT CHECK`

Before starting, the manager checks:

- selected IP is currently assigned to this PC
- active sing-box runtime passes its stored SHA256 integrity check
- whether the runtime is the current project-tested version or a verified rollback
- `StarSEA.exe` matches the verified active runtime
- Android profile matches the selected PC IP
- generated configs pass sing-box validation
- relay topology remains single-process and encrypted
- protocol sniffing is absent
- BPSR port allow-list has not changed unexpectedly
- PC relay IP is excluded from the Android TUN route
- no legacy/duplicate relay process exists
- TCP `10902` is not owned by another process
- expected Private-profile firewall rule exists
- current Windows network category

A failed critical check blocks relay startup rather than starting a partial/broken topology.

The **Preflight Check** button is useful when diagnosing setup, but it is not mandatory every day: **START RELAY automatically runs the critical preflight checks before launching StarSEA.**

### 7. `START RELAY`

Normal daily flow after setup is simply:

```text
Open manager
    -> START RELAY
    -> play
```

The relay runs hidden in the background. Closing the manager window does not stop it; use **STOP RELAY** when you want it stopped.

## Latency choices

The generated path intentionally uses:

- one Windows relay process (`StarSEA.exe`)
- one phone-to-PC proxy hop
- TCP only for the known BPSR TCP ports
- Shadowsocks `2022-blake3-aes-128-gcm`
- no proxy multiplexing
- Android `system` TUN stack
- no protocol sniff action
- disabled sing-box runtime logging on the data path
- direct outbound from StarSEA to the game server
- direct routing for non-BPSR Android traffic
- no recurring runtime hashing or network-adapter enumeration by the manager while StarSEA is running

Encryption adds a very small amount of CPU work, but it lets the project remove the old second PC proxy/local bridge and ensures the LAN tunnel does not expose a second clear BPSR payload to packet parsers.

The manager UI can remain open while playing. Its live status path only checks the tracked StarSEA process state; heavier integrity/network checks are done during setup, preflight, diagnostics, or while the relay is stopped.

## Routed ports

Only these TCP destination ports are routed through the PC relay:

```text
15000, 16000, 17000, 18000, 20000, 20001, 21000
```

Other Android traffic remains direct.

## Multiple DPS meters

The relay does **not** limit you to one DPS meter application.

You can run multiple compatible meters at once. Each meter should observe the same `StarSEA` clear game-server stream independently.

The relay only prevents duplicate relay/network paths; it does not block multiple viewer applications.

## Stale IP detection

The manager records the PC IP used in the Android profile.

If DHCP changes the PC address, the UI reports the profile as **OUTDATED** instead of just saying the file exists.

Then:

1. choose the current PC IP
2. run `Setup / Repair`
3. refresh the firewall rule
4. re-import/share the updated profile

## Diagnostics

**Copy Diagnostics** produces a privacy-safe report containing items such as:

- manager/runtime versions
- runtime integrity state
- selected LAN IP and adapter
- profile IP match
- firewall state
- StarSEA process count
- legacy relay process count
- relay-port ownership
- topology validation
- routed BPSR ports

It intentionally excludes relay passwords/profile secrets.

## Runtime rollback

The manager does not automatically jump to every new sing-box release.

A specific release is promoted as the tested runtime in this repository after validation. When the project later changes that tested version, the previous verified runtime is retained locally and can be restored with **Restore Previous Runtime**.

A verified rollback remains startable after it passes config/topology validation; **Setup / Repair** returns the installation to the current project-tested release.

This avoids turning an upstream proxy update into an unexpected gameplay/network regression.

## Files created at runtime

```text
.runtime/
  sing-box.exe
  sing-box-version.txt
  sing-box-sha256.txt
  StarSEA.exe
  relay-credentials.json
  pids.json
  manager.log
  config/
    starsea-relay.json
  rollback/

output/
  android-bpsr-relay.json
  profile-meta.json
  README-IMPORT.txt
```

`.runtime/` and `output/` are ignored by Git.

## Troubleshooting

### BPSR has no network on the phone

Check:

- phone and PC are on the same reachable LAN
- manager uses the correct PC LAN IPv4
- Windows network is Private, or you have an equivalent custom firewall rule
- `Allow Firewall` was run for the current IP
- the current generated profile is imported/enabled in SFA
- BPSR is selected in SFA per-app mode
- relay status says RUNNING

### ZDPS shows no data

Check ZDPS:

```text
Network Device: physical Wi-Fi/Ethernet adapter
Game Capture Preference: Custom
Custom BPSR Executable Name: StarSEA
```

Then run **Copy Diagnostics** and **Preflight Check**.

### DPS is exactly doubled

The current relay should not expose two clear copies of the BPSR payload on the PC network path: the phone-to-PC leg is encrypted.

Still verify that you are using the current single-process build and there are no old `BPSRMobileFront`, `BPSRRelayIngress`, or foreign `StarSEA` processes running. Preflight blocks these conditions.

### Setup says a foreign/legacy relay exists

The manager deliberately refuses to kill an untracked process just because it has a familiar name. Close the old relay manually, then retry.

## Safety / transparency

- no sing-box executable is committed to this repository
- only the pinned tested official SagerNet release is downloaded by Setup
- the official GitHub asset SHA256 digest is mandatory
- extracted runtime integrity is recorded and checked later
- generated JSON is UTF-8 without BOM
- relay credentials remain local under `.runtime/`
- profile sharing is temporary and is not active during gameplay
- the manager refuses duplicate/legacy relay process states
- STOP RELAY verifies the expected executable path/start state before terminating the tracked process
- a failed runtime rollback attempts to restore the exact pre-rollback runtime files

## Disclaimer

This is an unofficial community helper and is not affiliated with, endorsed by, or supported by the BPSR developers/publisher, ZDPS, SagerNet, sing-box, or QuickChart.
