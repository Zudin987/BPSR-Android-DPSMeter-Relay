# BPSR Android DPSMeter Relay

Windows helper for using a **PC BPSR DPS meter with BPSR running on Android**.

**Website:** https://zudin987.github.io/projects/android-relay/

## Use

1. Download the latest ZIP from [Releases](https://github.com/Zudin987/BPSR-Android-DPSMeter-Relay/releases/latest).
2. Extract the whole ZIP and run `BPSR Relay Manager.exe`.
3. Select the PC Ethernet/Wi-Fi address connected to the same router as the phone.
4. Click **Prepare Relay** → **Allow Firewall** → **Start Phone Setup**.
5. In Android SFA, scan/import the QR profile and route **BPSR only** through it.
6. Click **Start Relay** on the PC, start SFA on the phone, then open BPSR.
7. In your compatible DPS meter, use **StarSEA** as the BPSR capture/process target.

Daily use is normally just:

**PC Start Relay → Android Start SFA → Open BPSR**

## Important

- Use only on a **trusted home/private LAN**.
- Do **not** port-forward relay port `10808` on your router.
- The phone → PC SOCKS5 hop is authenticated but not encrypted.
- Do **not** target `BPSRMobileFront` in the DPS meter; use **StarSEA**.
- Re-run phone setup if your PC LAN IP changes or the manager tells you to repair the profile.

The relay does not modify BPSR game files and is DPS-meter agnostic as long as the meter can read the StarSEA traffic stream.

**Unofficial community tool.** Not affiliated with BPSR, SFA, sing-box, or any DPS-meter project.

[Latest release](https://github.com/Zudin987/BPSR-Android-DPSMeter-Relay/releases/latest) · [Source](https://github.com/Zudin987/BPSR-Android-DPSMeter-Relay)
