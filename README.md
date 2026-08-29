# BPSR Android Relay

A simple Windows helper for using **Blue Protocol: Star Resonance on Android** with a compatible packet-based DPS meter.

Current test build: **v1.0.0-rc.11**

## Quick start

Download the release ZIP, extract it, then open:

```text
BPSR Relay Manager.exe
```

On the **Home** tab, follow these steps:

1. **Prepare Relay** — sets up this PC.
2. **Allow Firewall** — lets your phone connect to this PC.
3. **Send to Phone** — import the profile in SFA on Android. Select **BPSR only**.
4. **DPS Meter** — set your compatible meter to **StarSEA**.
5. **Start Relay** — then open BPSR and play.

Next time is much easier:

```text
Open BPSR Relay Manager.exe -> Start Relay -> Play
```

The app has only three pages:

- **Home** — normal setup and daily use.
- **Details** — logs, report, recovery tools.
- **Help** — short instructions and common fixes.

RC.11 was rebuilt from real Windows screenshots after RC.10 exposed text clipping and wasted space. The current Home, Details, and Help layouts were also rendered to Windows preview images during UI audit so visual problems could be caught in addition to control-bound checks.

## If something is red

Read **What to do next** on the Home page. The app uses short messages such as:

- **Needs setup** → click **Prepare Relay**.
- **Phone Profile: Missing** → click **Prepare Relay**, then **Send to Phone**.
- **Firewall: Not set** → click **Allow Firewall**.
- **Old relay found** → close old relay apps or restart the PC.

For technical details, open **Details**.

## DPS meter setup

The universal capture target is:

```text
StarSEA
```

The relay is intentionally **DPS-meter agnostic**. It does not depend on ZDPS or another specific meter. **Any DPS meter that can parse BPSR traffic** and capture/detect the `StarSEA` stream may use it.

If your meter asks for a network device, choose the physical Wi-Fi/Ethernet adapter used by this PC.

ZDPS is only an example:

```text
Game Capture Preference: Custom
Custom BPSR Executable Name: StarSEA
```

## Multiple DPS meters

**Multiple DPS meters** may run at the same time. Each compatible meter can independently observe the same `StarSEA` game-server stream.

The anti-double-count design prevents duplicate **relay/network paths**. It does not limit how many meter apps you open.

## Low-latency design

Gameplay uses this path:

```text
Android BPSR
  -> SFA routes only known BPSR TCP ports
  -> encrypted LAN tunnel
  -> StarSEA.exe on PC :10902
  -> BPSR game server
```

Latency and clean capture are the main priorities:

- one Windows gameplay relay process (`StarSEA.exe`)
- one phone-to-PC proxy hop
- direct outbound from StarSEA
- no proxy multiplexing
- no protocol sniff action
- TCP only for the known BPSR ports
- Android `system` TUN stack
- sing-box data-path logging disabled
- non-BPSR phone traffic stays direct
- phone-to-PC BPSR traffic is encrypted, so the PC does not expose a second clear BPSR copy to packet parsers
- while StarSEA is running, the manager status timer uses the tracked PID/start time only; it does not repeatedly hash binaries, scan adapters, read PID JSON, resolve the executable path, or query firewall/network state

The user-facing `BPSR Relay Manager.exe` is only a small launcher. It is **not** part of the gameplay/network path and exits after starting the manager UI.

## SFA / Android notes

For the v1.0 line, use an SFA/sing-box **1.13.x** compatible Android client. The project-tested reference core is **sing-box v1.13.19**.

The generated Android profile does not use `strict_route`. SFA's Android app **does not implement that TUN option**, so the relay uses the supported PC relay-IP exclusion instead.

Only these BPSR TCP destination ports are routed through the PC relay:

```text
15000, 16000, 17000, 18000, 20000, 20001, 21000
```

## Common problems

### Phone cannot connect

- Phone and PC should be on the same reachable Wi-Fi/LAN.
- Click **Allow Firewall** again.
- Make sure the current profile is imported in SFA.
- In SFA per-app mode, select BPSR.

### DPS meter shows nothing

- Set the meter to `StarSEA`.
- If it asks for Network Device, choose your physical Wi-Fi/Ethernet adapter.
- The meter itself must support the current BPSR protocol/data format.

### DPS is exactly doubled

The current design exposes only one clear BPSR game-server path. Close any old `BPSRMobileFront`, `BPSRRelayIngress`, or foreign `StarSEA` relay process. **Run Check** will detect these conditions.

### Old relay found

Close the old relay app/process. If unsure, restart the PC and open the new manager again.

## Safety and package contents

The release is **EXE-first**: normal users open `BPSR Relay Manager.exe`.

The release ZIP contains the small launcher plus the manager scripts. It does **not** bundle `sing-box.exe`, `StarSEA.exe`, relay credentials, PID state, or generated phone profiles.

**Prepare Relay** downloads only the pinned official SagerNet sing-box release and requires its official SHA256 digest to match before use.

Runtime files stay local under `.runtime/`. Generated phone files stay under `output/`.

## Release status

RC.11 is an automated-test and visually audited release candidate, not the stable v1.0.0 release yet.

Before stable release, a real Android + Windows test still needs to confirm:

- `BPSR Relay Manager.exe` opens normally
- SFA imports and starts the generated profile
- BPSR connects and plays normally
- gameplay latency is acceptable
- at least one compatible DPS meter reads/parses `StarSEA` correctly
- DPS is not doubled

After that live test passes, the source version can be changed to `1.0.0`, final CI must pass on the exact commit, PR #1 can be merged, and the guarded stable Release workflow can publish the ZIP + SHA256.

## Disclaimer

This is an unofficial community helper. It is not affiliated with or endorsed by the BPSR developers/publisher, any DPS-meter project, SagerNet, sing-box, or QuickChart.
