# BPSR Android Relay

A simple Windows helper for using **Blue Protocol: Star Resonance on Android** with a compatible packet-based DPS meter on the PC.

Current test build: **v1.0.0-rc.15**

> RC.15 is a compatibility test build. It restores the network path from the original **Clean v4** ZIP because the newer RC.13/RC.14 Shadowsocks/port-routing path did not work in the real Android field test.

## Quick start

### First setup / upgrading from RC.14

1. Extract the RC.15 ZIP to a fresh folder.
2. Run **BPSR Relay Manager.exe**.
3. On **Home**, choose the PC Ethernet/Wi-Fi address connected to the same router as the phone.
4. Click **Prepare Relay**.
5. Click **Allow Firewall**. The manager requires a **Private** Windows network and keeps the relay restricted to your selected PC IP and local subnet.
6. On Android SFA, **delete or disable the old RC.13/RC.14 BPSR Relay profile**.
7. On the PC, click **Start Phone Setup**.
8. In SFA: **+ → Scan QR Code**, then import the newly generated RC.15 profile.
9. In SFA per-app/proxy-app settings, select **BPSR only**.
10. Start SFA.
11. On the PC DPS meter, use **StarSEA** as the game/capture process. Do **not** target `BPSRMobileFront`.
12. Click **Start Relay**, then open BPSR on Android.

### Daily use after setup

**PC Start Relay → Android Start SFA → Open BPSR**

You normally do not need to run Prepare Relay or re-import the profile again unless the PC LAN IP changes, the relay is upgraded, or the manager tells you to repair setup.

## RC.15 compatibility architecture

RC.15 intentionally matches the transport shape of the original Clean v4 setup:

```text
Android BPSR
    ↓ SFA TUN / selected app only
Authenticated SOCKS5 over trusted LAN
    ↓
BPSRMobileFront.exe   (PC LAN :10808)
    ↓ localhost authenticated SOCKS5
StarSEA.exe           (127.0.0.1 dynamic internal port)
    ↓ direct
BPSR game server
```

`BPSRMobileFront` is only the phone-facing proxy. **StarSEA is the only relay process that connects onward to the game server**, which keeps one clear capture path for compatible DPS meters.

This is deliberately different from RC.13/RC.14, which used Shadowsocks 2022 plus BPSR-port-specific Android routing. That design passed synthetic CI but failed the real Android/BPSR test, so RC.15 prioritizes the known field-tested Clean v4 shape instead.

## DPS meter setup

The relay is **DPS-meter agnostic**. Any DPS meter that can parse BPSR traffic from the `StarSEA` process/stream can be used.

- Universal process/executable target: **StarSEA**
- Do **not** target `BPSRMobileFront`
- Do **not** target `BPSRRelayIngress`
- If the meter asks for a physical network adapter, choose the PC Ethernet/Wi-Fi adapter carrying the Internet connection.
- ZDPS example only: **Game Capture Preference = Custom** and **Custom BPSR Executable Name = StarSEA**.

**Multiple DPS meters are allowed.** They may independently observe the same StarSEA stream. The duplicate/2× DPS protection is about preventing multiple relay paths, not limiting you to one meter app.

## Why two relay processes?

This is intentional in RC.15 and comes directly from the original Clean v4 topology:

- `BPSRMobileFront.exe` accepts the Android SOCKS5 connection on the LAN.
- It can only forward to the localhost StarSEA bridge.
- `StarSEA.exe` is the only stage with a direct game-server outbound.

That separation is what makes `StarSEA` a clean, stable capture target while keeping the phone-facing listener out of the DPS capture path.

## Android / SFA notes

The generated SFA profile uses:

- TUN stack: `system`
- `auto_route = true`
- the PC relay IP excluded from the TUN route to avoid a VPN loop
- local DNS with IPv4-only strategy
- DNS hijack for port 53
- one authenticated SOCKS5 outbound to the PC
- the selected SFA app's traffic routed through that PC relay
- protocol sniffing disabled
- multiplexing disabled

`strict_route` is intentionally absent because the SFA Android build does not implement that TUN option.

**Important:** RC.15 uses a different Android transport from RC.14. Do not reuse the old RC.14 SFA profile. Prepare Relay and import the new RC.15 QR/profile.

## Network safety

RC.15 prioritizes compatibility with the original working setup. The phone → PC hop is **authenticated SOCKS5 but not encrypted**.

Use it only on a **trusted home/private LAN**:

- Windows network profile must be **Private**.
- Firewall access is limited to the selected PC IP, TCP/UDP port 10808, and `LocalSubnet` only.
- Do **not** port-forward TCP/UDP 10808 on your router.
- Do **not** use it on an untrusted public Wi-Fi network.
- The localhost BPSRMobileFront → StarSEA bridge is not exposed to the LAN.

The relay credentials are randomly generated and are not included in diagnostics.

## The three pages

### Home

Normal setup and daily-use actions:

- **Prepare Relay**
- **Allow Firewall**
- **Start Phone Setup** / SFA QR import
- DPS target reminder
- **Start Relay** / **Stop Relay**

### Details

Troubleshooting tools, diagnostic report, logs, restore/recovery actions, and profile-folder access.

### Help

Short Android/SFA instructions and common fixes for non-technical users.

## Common problems

### BPSR stops connecting as soon as SFA starts

Make sure you are using the **new RC.15 profile**, not the old RC.13/RC.14 profile. In SFA, delete/disable the old BPSR Relay profile, then use **Start Phone Setup** on the PC and scan the new QR.

### Firewall says Network is Public

Click **Allow Firewall**. Only approve changing it to **Private** when this is your trusted home/private LAN. The relay remains blocked on a Public network.

### Phone cannot reach the PC

Confirm:

- phone and PC are on the same router/LAN
- the selected PC IP is still correct
- Windows network is Private
- Firewall shows Ready
- no guest-Wi-Fi/client-isolation feature is separating the phone from the PC

### DPS meter shows nothing

Use **StarSEA** as the capture/process target. Do not target BPSRMobileFront. If the meter also asks for a physical adapter, select the PC Ethernet/Wi-Fi adapter.

### DPS appears doubled

Stop the relay, close old relay processes, and run **Prepare Relay** again. RC.15 checks for foreign/duplicate `StarSEA`, `BPSRMobileFront`, and legacy `BPSRRelayIngress` processes before starting.

## Latency design

Latency remains a primary goal:

- no protocol sniffing
- no multiplexing
- no local AI or heavy background service
- direct StarSEA outbound to the game server
- localhost-only internal bridge
- gameplay UI status polling checks only the two tracked relay PIDs plus their immutable start times; it does not repeatedly hash files, enumerate adapters, read configs, or run CIM queries while the relay is healthy

The extra localhost SOCKS hop is retained because it is the known Clean v4 shape that provides the clean StarSEA capture target and previously worked in the real setup.

## Package safety

The release is **EXE-first**: users open `BPSR Relay Manager.exe`.

The package does not bundle:

- `sing-box.exe`
- `StarSEA.exe`
- `BPSRMobileFront.exe`
- relay credentials
- PID/runtime state

The manager downloads and verifies the pinned tested sing-box runtime when Prepare Relay is run, then creates its runtime copies locally.

The launcher is currently unsigned, so Windows SmartScreen may show a reputation warning until a real Authenticode code-signing certificate is used.

## Release status

RC.15 is an automated-test release candidate, **not** stable v1.0.0 yet.

Before stable release, complete a real Android + Windows + BPSR field test and confirm:

- the new RC.15 SFA profile imports and starts
- BPSR connects and plays normally through SFA
- gameplay latency is acceptable
- the compatible DPS meter reads `StarSEA`
- DPS is not doubled

Only after that real test passes should the source version be changed to `1.0.0`, the PR merged, exact-main CI validated, and stable release published.

## Disclaimer

This is an unofficial community helper. It is not affiliated with or endorsed by the BPSR developers/publisher, any DPS-meter project, SagerNet, or sing-box.
