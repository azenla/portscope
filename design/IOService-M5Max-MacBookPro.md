# IOService Registry — Apple 16″ MacBook Pro (M5 Max)

A categorized field guide to everything exposed in the **IOService plane** of this machine's I/O Registry — a companion to the M3 Max guide, in the same structure. Each node carries its *object class*, *entry name*, *registry ID*, retain count, busy state, and (for bus-attached nodes) a *location*. It's a structural snapshot of the live service tree: an inventory of hardware blocks, firmware coprocessors, and driver stacks, not a dump of their live register values.

## At a glance

| Metric | Value |
|---|---|
| Total registry nodes | **3,950** |
| Maximum tree depth | **25** levels |
| Distinct object classes | **472** |
| Distinct entry names | **1473** |
| Platform identifier | **J716cAP** — 16″ MacBook Pro |
| SoC | **Apple T6050 = M5 Max** (seen in `AppleT6050ANEHAL`, `AppleT6050PMGR`, `AppleT6050MemCacheController`) |
| CPU | **18 cores** — `AppleARMCPU` ×18 (`cpu0`–`cpu17`); this plane doesn't break out the P/E split |
| GPU | **`AGXAcceleratorG17X`** — Apple **G17** graphics (M5 generation) |
| Neural Engine | **`H11ANE`** via `AppleT6050ANEHAL`, now fronted by an **`ANEExclaveProxy`** |
| Internal SSD | **APPLE SSD AP2048Z Media** (≈2 TB) |
| Display pipelines | **5× DCP** — 1 internal + 4 external (`dcpext0–3`) |
| Thunderbolt | **3× `IOThunderboltControllerType7`** — the **Thunderbolt 5** generation (80 Gb/s `CIO80` PHY) |
| Wireless | **Apple first-party Wi-Fi** (`AppleWLANDriver`, `IOUserNetworkWLAN`) — *no Broadcom* |
| Audio codec | **Cirrus Logic CS42L84** (`AppleCS42L84Audio` + `…Mikey`) |

> **Scope & privacy:** no serial numbers, MAC addresses, or credentials live in this plane. APFS volume names and installed Xcode simulator runtimes do appear.

---

## What changed since the M3 Max (J514) ⟶ M5 Max (J716)

Because you exported both machines, the most interesting reading is the *delta*. Node count grew from 2,993 to **3,950**, and distinct classes from 419 to **472**. The substantive architectural changes:

| Area | M3 Max (T6031) | M5 Max (T6050) |
|---|---|---|
| GPU architecture | `AGXAcceleratorG15X` (G15) | **`AGXAcceleratorG17X` (G17)** |
| CPU cores | 14 | **18** |
| Wireless | **Broadcom** (`AppleBCMWLANCore`) | **Apple first-party Wi-Fi** (`AppleWLANDriver` / `IOUserNetworkWLAN`) |
| Thunderbolt | Type 5 controllers (TB4 / 40 Gb/s) | **Type 7 controllers (TB5 / 80 Gb/s `CIO80` PHY)** |
| Secure isolation | classic SEP/kernel split | **Exclaves** — `IOExclaveProxy`, `ExclaveSEPManagerProxy`, `ANEExclaveProxy`, AOP/ISP/DCP exclave domains |
| USB enumeration | minimal (NCM virtual only) | **full USB host stack** — `IOUSBHostInterface` ×23, hubs, mass-storage, billboard, CDC/ACM |
| CPU tracing | — | **`AppleProcessorTraceT6050`** hardware trace + user client |
| Networking | Skywalk + 802.11 | adds **TSN** (`TSNWiFiInterface`, time-sensitive networking) |
| SSD | `AP1024Z` (1 TB) | `AP2048Z` (2 TB) |

The headline is the move to **Apple's own wireless silicon** and **Thunderbolt 5**, plus the maturation of **Exclaves** — a hardware-enforced secure world that now isolates the SEP, ANE, AOP, ISP, and display coprocessors behind dedicated proxy objects and their own DART mappings. These get their own section below.

---

## Table of contents

- [1. System Identity & Platform Fabric](#1-system-identity--platform-fabric)
- [2. CPU Complex](#2-cpu-complex)
- [3. GPU](#3-gpu)
- [4. Neural Engine (ANE)](#4-neural-engine-ane)
- [5. Media Engines — Video & Image](#5-media-engines--video--image)
- [6. Memory Mapping — DART / IOMMU](#6-memory-mapping--dart--iommu)
- [7. Coprocessors & RTKit](#7-coprocessors--rtkit)
- [8. Secure Exclaves (new)](#8-secure-exclaves-new)
- [9. Display & Graphics Output](#9-display--graphics-output)
- [10. Thunderbolt 5 / USB4](#10-thunderbolt-5--usb4)
- [11. USB](#11-usb)
- [12. Networking (Apple Wi-Fi)](#12-networking-apple-wifi)
- [13. Bluetooth](#13-bluetooth)
- [14. Storage — NVMe, APFS & Disk Images](#14-storage--nvme-apfs--disk-images)
- [15. Audio Subsystem](#15-audio-subsystem)
- [16. Human Interface Devices](#16-human-interface-devices)
- [17. Power, Thermal & Sensors](#17-power-thermal--sensors)
- [18. Secure Enclave & Security](#18-secure-enclave--security)
- [19. Low-Level Buses & GPIO](#19-lowlevel-buses--gpio)
- [20. Telemetry, Logging & IOReporting](#20-telemetry-logging--ioreporting)
- [21. User Clients](#21-user-clients)
- [22. Other / Miscellaneous](#22-other--miscellaneous)
- [23. Appendix A — Full object-class frequency table](#23-appendix-a--full-objectclass-frequency-table)

---

## 1. System Identity & Platform Fabric

The root descends into a single **`IOPlatformExpertDevice`** named **`J716cAP`** — Apple's board code for the 16″ MacBook Pro. Beneath it sits the T6050 fabric: the power manager (`AppleT6050PMGR`), the system-level cache controller (`AppleT6050MemCacheController`), an `AppleT6050SOCTuner`, the PCIe roots (`AppleT6050PCIe` / `…PCIeC`), and the USB-C PHY (`AppleT6050TypeCPhy`). `7` nodes fall here.

**Most common classes**

| Count | Object class |
|---:|:---|
| 3 | `ApplePMGRNub` |
| 1 | `IODTNVRAMPlatformNotifier` |
| 1 | `AppleARMIODevice` |
| 1 | `AppleT6050PMGR` |
| 1 | `IOServiceCompatibility` |

- **T6050 fabric blocks:** `AppleT6050PMGR`
- **Power / PCIe:** `AppleT6050PMGR`, `pmgr`, `pmgrtools`, `ppm`, `soc-tuner`

---

## 2. CPU Complex

Eighteen **`AppleARMCPU`** objects (`cpu0`–`cpu17`) make this an **18-core** M5 Max — up from 14 on the M3 Max. The performance/efficiency split isn't directly encoded in this plane, so it isn't stated here. New this generation: **`AppleProcessorTraceT6050`** with its nub and user client — on-die instruction-trace hardware (CoreSight-style) that wasn't present on the M3 Max. The `AppleT6050MemCacheController` (system level cache) also lands here.

**Most common classes**

| Count | Object class |
|---:|:---|
| 18 | `AppleARMCPU` |
| 4 | `AppleCLPCUserClient` |
| 3 | `AppleARMIODevice` |
| 2 | `AppleProcessorTraceUserClient` |
| 1 | `AppleAuthCPUserClient` |
| 1 | `AppleT6050MemCacheController` |
| 1 | `AppleT6050SOCTuner` |
| 1 | `ApplePMGRNub` |
| 1 | `AppleCLPC` |
| 1 | `AppleProcessorTraceT6050` |
| 1 | `AppleProcessorTraceNub` |

- **Core objects:** `AppleARMCPU`
- **Processor trace (new):** `AppleProcessorTraceNub`, `AppleProcessorTraceT6050`, `AppleProcessorTraceUserClient`
- **Cache / cluster:** `AppleT6050MemCacheController`

---

## 3. GPU

The GPU steps up to the **`AGXAcceleratorG17X`** — Apple's **G17** graphics architecture (the M3 Max used G15). Its firmware coprocessor is `AGXFirmwareKextG17RTBuddy`. Around it sit the familiar AGX driver objects and the per-process Metal clients — **161× `AGXDeviceUserClient`** at the moment of capture. `165` nodes total.

**Most common classes**

| Count | Object class |
|---:|:---|
| 161 | `AGXDeviceUserClient` |
| 2 | `AGXFirmwareKextG17RTBuddy` |
| 1 | `AGXAcceleratorG17X` |
| 1 | `AGXArmFirmwareMapper` |

- **Accelerator (G17):** `AGXAcceleratorG17X`
- **GPU firmware:** `AGXArmFirmwareMapper`, `AGXFirmwareKextG17RTBuddy`
- **Metal device clients:** `AGXDeviceUserClient`

---

## 4. Neural Engine (ANE)

The Neural Engine is **`H11ANE`** fronted by **`AppleT6050ANEHAL`**, with the usual `H1xANELoadBalancer` distributing Core ML work. The notable change: an **`ANEExclaveProxy`** now sits in front of it, routing inference through the Exclaves secure world (see §8). The ANE keeps its own RTKit coprocessor, IOP nub (`iop-ane0-nub`), and DART (`dart-ane0`).

**Most common classes**

| Count | Object class |
|---:|:---|
| 9 | `IODARTMapperNub` |
| 5 | `H1xANELoadBalancerDirectPathClient` |
| 2 | `AppleARMIODevice` |
| 1 | `H11ANEIn` |
| 1 | `ANEClientHints` |
| 1 | `H1xANELoadBalancer` |
| 1 | `H1xANELoadBalancerClient` |
| 1 | `AppleT6050ANEHAL` |

- **Engine + HAL:** `AppleT6050ANEHAL`, `H11ANE`
- **Load balancer:** `ANEDriverRoot`, `H1xANELoadBalancerClient`, `H1xANELoadBalancerDirectPathClient`
- **Device nodes:** `ane0`, `dart-ane0`, `mapper-ane0`, `mapper-ane0-iso1`, `mapper-ane0-iso2`, `mapper-ane0-iso3`, `mapper-ane0-iso4`, `mapper-ane0-iso5`, `mapper-ane0-iso6`, `mapper-ane0-iso7`, `mapper-ane0-mpm`

---

## 5. Media Engines — Video & Image

Dedicated media silicon: the **`AppleAVD`** video decoder (`avd0`), the **`AppleJPEGDriver`** (`jpeg0`), and the **ISP** (image signal processor) — the latter now sits behind Exclaves (`isp-exclave-proxy`, `mapper-isp-*-exclave`), reflecting tighter isolation of the camera path. Each engine carries its own DART. `73` nodes here.

**Most common classes**

| Count | Object class |
|---:|:---|
| 17 | `AppleARMIODevice` |
| 17 | `IODARTMapperNub` |
| 15 | `AFKEPInterfaceKextV2` |
| 8 | `AppleAVDUserClient` |
| 4 | `AppleJPEGDriverUserClient` |
| 3 | `DCPAVDeviceProxy` |
| 2 | `AppleProResHW` |
| 2 | `AppleM2ScalerCSCDriver` |
| 2 | `AppleJPEGDriver` |
| 1 | `AppleAVD` |
| 1 | `AppleSecondaryAudio` |
| 1 | `AppleEmbeddedAudioDevice` |

- **Video decoder:** `AppleAVD`, `AppleAVDUserClient`, `DCPAVDeviceProxy`, `avd0`, `dart-avd0`, `mapper-avd0`, `mapper-avd0-adsbuf`, `mapper-avd0-piodma`
- **JPEG:** `AppleJPEGDriver`, `AppleJPEGDriverUserClient`, `dart-jpeg0`, `jpeg0`, `jpeg1`, `mapper-jpeg0`, `mapper-jpeg1`
- **ISP:** `admac-disp0`, `admac-disp0-ced-ssw`, `dart-disp0`, `dart-disp0-isoc`, `dart-isp0`, `disp0`, `disp0-service`, `disp0:dcpav-controller-epic:0`, `disp0:dcpav-device-epic:0`, `disp0:dcpav-power-epic:0`, `disp0:dcpav-sac-epic:0`, `disp0:dcpav-service-epic:0` _(+12 more)_
- **Clients:** `AppleAVDUserClient`, `AppleJPEGDriverUserClient`

---

## 6. Memory Mapping — DART / IOMMU

**DART** is Apple's IOMMU — every DMA-capable block gets an isolated, translated view of memory. Still one of the largest categories (`356` nodes): `AppleT8110DART` controllers, `IODARTMapper` objects, and per-attachment `IODARTMapperNub`s. New on M5: a set of **`mapper-*-exclave`** nubs that give the exclave-isolated engines (DCP, ISP, AOP, SEP) their own protected mappings.

**Most common classes**

| Count | Object class |
|---:|:---|
| 157 | `IODARTMapper` |
| 119 | `IODARTMapperNub` |
| 43 | `AppleT8110DART` |
| 35 | `AppleARMIODevice` |
| 1 | `IOCoastGuardSARTMapper` |
| 1 | `SharedDARTMapperProxy` |

- **DART controllers:** `AppleT8110DART`
- **DART devices:** `dart-acio0`, `dart-acio1`, `dart-acio2`, `dart-aop`, `dart-apcie0`, `dart-apcie1`, `dart-apciec0`, `dart-apciec1`, `dart-apciec2`, `dart-apr0`, `dart-apr1`, `dart-auss0` _(+21 more)_

---

## 7. Coprocessors & RTKit

The RTKit coprocessor fabric: **`RTBuddy`** cores with `RTBuddyEndpointService` / `DCPEndpointV2` mailboxes, `AppleA7IOPNub` I/O-processor nubs, and `AFKEPInterfaceKextV2` "Apple Firmware Kit" typed-message endpoints. The **AOP** (Always-On Processor) is here, now paired with a **`SecureRTBuddyProxy(AOP-EXCLAVE)`** secure variant. New audio/profiling firmware drivers (`AOPAudioService`, `AppleSPUProfileFirmwareDriver`) also appear. Biggest functional category at `301` nodes.

**Most common classes**

| Count | Object class |
|---:|:---|
| 71 | `AFKEPInterfaceServiceKextV2` |
| 34 | `IOPlatformDevice` |
| 27 | `RTBuddyEndpointService` |
| 25 | `AFKEPInterfaceKextV2` |
| 22 | `RTBuddyService` |
| 14 | `IOPCIDevice` |
| 14 | `AppleASCWrapV6` |
| 12 | `RTBuddyIOReportingEndpoint` |
| 10 | `AppleA7IOPNub` |
| 9 | `RTBuddy` |
| 8 | `AppleARMIODevice` |
| 6 | `AFKEPKextV2` |

- **RTKit cores:** `RTBuddyService`
- **IOP nubs:** `ans-pcie`, `auss-cpu0-nub`, `iop-ans-nub`, `iop-aop-nub`, `iop-aop2-nub`, `iop-gfx-nub`, `iop-gfx1-nub`, `iop-mtp-nub`, `iop-pmp0-nub`, `iop-sio-nub`, `iop-voicetrigger-controller`
- **Firmware kit endpoints:** `AFKAOP2Endpoint1`, `AFKAOP2Endpoint13`, `AFKAOP2Endpoint2`, `AFKAOP2Endpoint3`, `AFKAOP2Endpoint4`, `AFKAOP2Endpoint5`, `AFKEPInterfaceServiceKextV2`, `aop2.system-iopm-aop2.system-iopm.ap.client-rev`, `md-manager`, `powerlog-service`, `system`, `system-expert` _(+2 more)_

---

## 8. Secure Exclaves (new)

**Exclaves** are the headline architectural addition on this machine — a hardware-enforced "secure world" that sits beside the kernel and isolates the most sensitive coprocessors. Instead of the kernel talking to a block directly, it talks to a *proxy*, and the real engine runs in an exclave domain with its own protected memory mappings. This plane shows `22` exclave nodes spanning:

- **`IOExclaveProxy`** / **`ExclaveSEPManagerProxy`** — the generic bridge and the Secure Enclave's exclave manager.
- **`ANEExclaveProxy`** — Neural Engine inference routed through the secure world.
- **AOP exclave** — `SecureRTBuddyProxy(AOP-EXCLAVE)`, `aop-exclave-mailbox`, `aop-exclave-ioreporting`.
- **ISP exclave** — `isp-exclave-proxy` and camera-pipe mappers (`mapper-isp-epipe*-exclave`).
- **DCP exclave** — `mapper-dcp-exclave`, `mapper-dcpext0–3-exclave` for the display coprocessors.
- A signed **`UniversalMacExclaveOS`** cryptex graft backs the exclave OS image.

This is the main "what's new" story relative to the M3 Max, where none of these existed.

**Most common classes**

| Count | Object class |
|---:|:---|
| 11 | `IODARTMapperNub` |
| 4 | `AppleARMIODevice` |
| 1 | `IOExclaveProxy` |
| 1 | `SecureRTBuddyProxy` |
| 1 | `SecureRTBuddyIOReporting` |
| 1 | `ExclaveSEPManagerProxy` |
| 1 | `AppleAPFSGraft` |
| 1 | `ANEExclaveProxy` |
| 1 | `IOPlatformDevice` |

- **Proxies:** `ANEExclaveProxy`, `ExclaveSEPManagerProxy`, `IOExclaveProxy`, `SecureRTBuddyProxy(AOP-EXCLAVE)`, `isp-exclave-proxy`, `isp-exclave-s-proxy`
- **Exclave devices:** `aop-exclave-ioreporting`, `aop-exclave-mailbox`, `exclaves-test`, `isp-exclave-proxy`, `isp-exclave-s-proxy`
- **Exclave mappers:** `mapper-dcp-exclave`, `mapper-dcpext0-exclave`, `mapper-dcpext1-exclave`, `mapper-dcpext2-exclave`, `mapper-dcpext3-exclave`, `mapper-exclave-aop`, `mapper-isp-epipe0-exclave`, `mapper-isp-epipe1-exclave`, `mapper-isp-piodma0-exclave`, `mapper-isp-piodma1-exclave`, `mapper-sep-exclave`
- **Exclave OS:** `CheerF25F71.UniversalMacExclaveOS`

---

## 9. Display & Graphics Output

Display is driven by the **DCP — Display CoProcessor**. Five pipelines: one **`AppleDCPExpert`** for the internal display plus four **`dcpext0–3`** for external outputs, each with an `IOMobileFramebuffer`, a DisplayPort transmitter proxy, HDCP interfaces, and `DCPEndpointV2` mailboxes — and now an exclave-isolated DART mapping each. An **`AppleT6050DisplayCrossbar`** routes streams; an **`IODisplayWrangler`** manages display power; brightness runs through `AppleARMBacklight`. Note the `AppleT8142ATCDPXBAR` crossbars (`atc0–3`) bridging DisplayPort onto the Thunderbolt controllers.

**Most common classes**

| Count | Object class |
|---:|:---|
| 70 | `RTBuddyEndpointService` |
| 65 | `DCPEndpointV2` |
| 51 | `AFKEPInterfaceKextV2` |
| 26 | `AppleARMIODevice` |
| 17 | `IOMobileFramebufferUserClient` |
| 14 | `AppleHDCPInterface` |
| 9 | `DCPAVControllerProxy` |
| 9 | `DCPDPControllerProxy` |
| 9 | `AppleDCPDPTXRemoteHDCPInterfaceProxy` |
| 8 | `AppleDCPDPTXRemotePortProxy` |
| 8 | `AppleDCPDPTXRemotePortUFP` |
| 5 | `IOMobileFramebufferShim` |

- **DCP expert / external:** `AppleDCPExpert`, `dcpexpert-service`
- **Framebuffers:** `IOMobileFramebufferShim`, `IOMobileFramebufferUserClient`
- **Crossbar / wrangler:** `AppleDPTXCrossbarAUXOnlyUFP(dptx0-aux-ufp)`, `AppleDPTXCrossbarAUXOnlyUFP(dptx1-aux-ufp)`, `AppleT6050DisplayCrossbar(display-crossbar0)`, `IODisplayWrangler`, `display-crossbar0`
- **Backlight:** `AppleARMBacklight`, `backlight`, `backlight-override`, `kbd-backlight`

---

## 10. Thunderbolt 5 / USB4

Three **`IOThunderboltControllerType7`** stacks (with `AppleThunderboltHALType7` / `AppleThunderboltNHIType7` / `IOThunderboltSwitchType7`) mark the move to **Thunderbolt 5** — the 80 Gb/s generation, exposed here through the `AppleT8142ATC*` Apple Thunderbolt Controllers and the **`AppleTypeCPhyCIO80PhyMBI`** "Converged I/O 80" PHY. **52× `IOThunderboltPort`** and the new `AppleThunderboltUSBType2DownAdapter` / `…USBUpAdapter` tunnel USB and DisplayPort over the link. `215` nodes total.

**Most common classes**

| Count | Object class |
|---:|:---|
| 52 | `IOThunderboltPort` |
| 34 | `AppleARMIODevice` |
| 12 | `AppleThunderboltDPInAdapterOS2` |
| 12 | `AppleATCDPINAdapterPort` |
| 10 | `RTBuddyEndpointService` |
| 7 | `AppleA7IOPNub` |
| 7 | `RTBuddy` |
| 6 | `AppleThunderboltUSBDownAdapter` |
| 4 | `AppleT8142ATCDPXBAR` |
| 4 | `AppleT6050TypeCPhy` |
| 3 | `AppleARMIICDevice` |
| 3 | `AppleTypeCPhyCIO80PhyMBI` |

- **Controllers / HAL (Type 7):** `AppleThunderboltHALType7`, `AppleThunderboltNHIType7`, `IOThunderboltControllerType7`, `IOThunderboltSwitchType7`
- **Ports:** `IOThunderboltPort`
- **ATC / PHY (TB5):** `Apple Watch Magnetic Charging Cable`, `AppleARMWatchdogTimer`, `AppleATCDPAltModePort(atc0-dpphy)`, `AppleATCDPAltModePort(atc1-dpphy)`, `AppleATCDPAltModePort(atc2-dpphy)`, `AppleATCDPHDMIPort(atc3-dpphy)`, `AppleATCDPINAdapterPort(atc0-dpin0)`, `AppleATCDPINAdapterPort(atc0-dpin1)`, `AppleATCDPINAdapterPort(atc0-dpin2)`, `AppleATCDPINAdapterPort(atc0-dpin3)`, `AppleATCDPINAdapterPort(atc1-dpin0)`, `AppleATCDPINAdapterPort(atc1-dpin1)` _(+44 more)_
- **Adapters:** `AppleATCDPINAdapterPort(atc0-dpin0)`, `AppleATCDPINAdapterPort(atc0-dpin1)`, `AppleATCDPINAdapterPort(atc0-dpin2)`, `AppleATCDPINAdapterPort(atc0-dpin3)`, `AppleATCDPINAdapterPort(atc1-dpin0)`, `AppleATCDPINAdapterPort(atc1-dpin1)`, `AppleATCDPINAdapterPort(atc1-dpin2)`, `AppleATCDPINAdapterPort(atc1-dpin3)`, `AppleATCDPINAdapterPort(atc2-dpin0)`, `AppleATCDPINAdapterPort(atc2-dpin1)`, `AppleATCDPINAdapterPort(atc2-dpin2)`, `AppleATCDPINAdapterPort(atc2-dpin3)` _(+8 more)_

---

## 11. USB

Unlike the M3 Max export (which showed only virtual NCM links), this capture has a **full USB host stack** live: **22× `IOUSBHostInterface`** and **15× `IOUSBHostDevice`**, USB 2.0/3.0 hubs (`AppleUSB20Hub`, `AppleUSB30Hub`), composite and billboard devices, CDC/ACM serial, and an `IOUSBMassStorageDriver` — so a USB drive and/or hub was attached. The SoC host/device controllers are `AppleT8142USBXHCI` / `AppleT8142USBXDCI`, plus an `AppleT6050USBXHCIAUSS` (Apple USB SuperSpeed) block.

**Most common classes**

| Count | Object class |
|---:|:---|
| 22 | `IOUSBHostInterface` |
| 18 | `AppleUSB20HubPort` |
| 16 | `AppleUSB30HubPort` |
| 15 | `IOUSBHostDevice` |
| 15 | `AppleUSBXHCIAUSSPort` |
| 12 | `IOUSBDeviceInterface` |
| 7 | `AppleUSBHostCompositeDevice` |
| 6 | `AppleUSBDeviceNCMControl` |
| 6 | `AppleUSBDeviceNCMData` |
| 5 | `AppleUserHIDDevice` |
| 4 | `AppleARMIODevice` |
| 4 | `AppleUSB20Hub` |

- **Host interfaces/devices:** `AEEDJRW0F1920051`, `Anker Prime Docking Station`, `BillBoard`, `Billboard Interface`, `CDC Communications Control`, `G502 HERO Gaming Mouse`, `GSV-FWUPDATE`, `Gaming Keyboard G910`, `GenesysLogic`, `IOUSBHostInterface`, `USB 10/100/1G/2.5G LAN`, `USB BillBoard` _(+7 more)_
- **Hubs:** `AppleUSB20Hub`, `AppleUSB20HubPort`, `AppleUSB30Hub`, `AppleUSB30HubPort`, `USB2.0 Hub`, `USB2.1 Hub`, `USB3 HUB`, `USB3.1 Hub`
- **Mass storage:** `IOUSBMassStorageDriver`, `IOUSBMassStorageDriverNub`, `IOUSBMassStorageInterfaceNub`, `IOUSBMassStorageResource`
- **Controllers:** `AppleT6050USBXHCIAUSS`, `AppleT8142USBXDCI`, `AppleT8142USBXHCI`, `AppleUSBXHCIAUSSPort`, `usb-drd0-port-hs`, `usb-drd0-port-ss`, `usb-drd1-port-hs`, `usb-drd1-port-ss`, `usb-drd2-port-hs`, `usb-drd2-port-ss`
- **Serial / NCM:** `AppleUSBACMControl`, `AppleUSBACMData`, `AppleUSBCDCCompositeDevice`, `AppleUSBDeviceNCMControl`, `AppleUSBDeviceNCMData`, `AppleUSBNCMControl`, `AppleUSBNCMControlAux`, `AppleUSBNCMData`, `AppleUSBNCMDataAux`, `CDC Communications Control`, `anpi0`, `anpi1` _(+2 more)_

---

## 12. Networking (Apple Wi-Fi)

The biggest networking change: Wi-Fi is now **Apple's own first-party silicon**, not Broadcom. It appears as a DriverKit **`AppleWLANDriver`** (`IOUserService`) exposing several **`IOUserNetworkWLAN`** interfaces — station (`…STA`), AWDL (AirDrop/peer-to-peer), Personal Hotspot, and a low-latency interface — reached over `spmi-wifibt`. **`TSNWiFiInterface`** adds time-sensitive networking. Skywalk remains the underlying stack. The `en1` Ethernet interface and 802.11 management clients round it out.

**Most common classes**

| Count | Object class |
|---:|:---|
| 16 | `IOUserUserClient` |
| 12 | `IONetworkStack` |
| 12 | `IONetworkStackUserClient` |
| 7 | `IOEthernetInterface` |
| 4 | `IOUserNetworkWLAN` |
| 4 | `IOSkywalkNetworkBSDClient` |
| 2 | `IOUserService` |
| 2 | `TSNUserWiFiControlInterface` |
| 2 | `TSNWiFiInterface` |
| 1 | `IOSkywalkLegacyEthernet` |
| 1 | `IOSkywalkLegacyEthernetInterface` |
| 1 | `AppleARMSPMIDevice` |

- **Apple Wi-Fi (new):** `AppleWLANDriver`, `AppleWLANInterfaceAWDL`, `AppleWLANInterfaceHotspot`, `AppleWLANInterfaceSTA`, `AppleWLANLowLatencyInterface`, `AppleWLANWDUserClient`
- **WLAN interfaces:** `AppleWLANInterfaceAWDL`, `AppleWLANInterfaceHotspot`, `AppleWLANInterfaceSTA`, `AppleWLANLowLatencyInterface`
- **TSN (new):** `TSNUserWiFiControlInterface`, `TSNWiFiInterface`
- **Skywalk / stack:** `IONetworkStack`, `IONetworkStackUserClient`, `IOSkywalkLegacyEthernet`, `IOSkywalkNetworkBSDClient`, `en0`

---

## 13. Bluetooth

Bluetooth remains a discrete module on a `bluetooth` device with an **`IOBluetoothHCIController`**, and — like the M3 Max — a DriverKit **`IOUserBluetoothSerialDriver`** running in its own `IOUserServer`. It now shares the `spmi-wifibt` rail with the Apple Wi-Fi block.

**Most common classes**

| Count | Object class |
|---:|:---|
| 1 | `AppleARMIODevice` |
| 1 | `IOBluetoothHCIController` |
| 1 | `IOBluetoothACPIMethods` |
| 1 | `IOBluetoothHCIUserClient` |
| 1 | `IOBluetoothDevice` |
| 1 | `IOUserService` |
| 1 | `IOUserUserClient` |
| 1 | `IOUserServer` |

- **HCI controller:** `IOBluetoothHCIController`
- **DriverKit serial:** `IOUserBluetoothSerialClient`, `IOUserBluetoothSerialDriver`, `IOUserServer(com.apple.IOUserBluetoothSerialDriver-0x100001b8e)`

---

## 14. Storage — NVMe, APFS & Disk Images

The internal drive is **`APPLE SSD AP2048Z Media`** — an ≈2 TB Apple NVMe module (double the M3 Max sample's 1 TB). On top of it sits the standard **APFS** stack: an `AppleAPFSContainer`, named volumes each surfaced via `AppleAPFSVolumeBSDClient`, GUID partition schemes, block-storage drivers, and mounted disk images.

**Named macOS volumes:** `Data`, `Hardware`, `Macintosh HD`, `Managed Data (501)`, `Preboot`, `Recovery`, `Update`, `VM`, `iSCPreboot`, `xART`.

**Xcode simulator runtimes mounted as images:** `AppleTVOS 26.4 Simulator`, `AppleTVOS 26.5 Simulator`, `WatchOS 26.4 Simulator`, `WatchOS 26.5 Simulator`, `XROS 26.4.1 Simulator`, `XROS 26.5 Simulator`, `iOS 26.4.1 Simulator`, `iOS 26.5 Simulator`.

**Most common classes**

| Count | Object class |
|---:|:---|
| 39 | `AppleAPFSGraft` |
| 21 | `IOMediaBSDClient` |
| 21 | `AppleAPFSVolumeBSDClient` |
| 20 | `IOMedia` |
| 18 | `AppleAPFSVolume` |
| 12 | `IOBlockStorageDriver` |
| 11 | `AppleAPFSContainerScheme` |
| 11 | `AppleAPFSMedia` |
| 11 | `AppleAPFSMediaBSDClient` |
| 11 | `AppleAPFSContainer` |
| 9 | `IOGUIDPartitionScheme` |
| 8 | `AppleDiskImageDevice` |

- **Physical SSD:** `APPLE SSD AP2048Z Media`
- **APFS:** `AppleAPFSContainer`, `AppleAPFSMedia`, `AppleTVOS 26.4 Simulator`, `AppleTVOS 26.5 Simulator`, `Data`, `Hardware`, `Macintosh HD`, `Managed Data (501)`, `Preboot`, `Recovery`, `Update`, `VM` _(+5 more)_
- **Partition schemes:** `IOGUIDPartitionScheme`
- **Disk images:** `Apple Disk Image Media`

---

## 15. Audio Subsystem

Audio is again built on the **Cirrus Logic CS42L84** codec (`AppleCS42L84Audio`, plus `AppleCS42L84Mikey` for the mic path) feeding the SoC's MCA/I²S clusters and `AudioDMAChannel` engines. The internal high-fidelity speaker array enumerates as left/right tweeters and force-cancelling woofers (`audio-speaker-left-tweeter`, `…left-woofer-2`, `…right-woofer-1/2`, `…right-tweeter`), with a `SpeakerTap` feedback path. The mic side shows a `Digital Mic`, headphone mic, and a low-power `IOPAudioLPMicDevice` for always-on listening via the AOP.

**Most common classes**

| Count | Object class |
|---:|:---|
| 18 | `AudioDMAChannel` |
| 13 | `IOPAudioNode` |
| 10 | `IOAudio2DeviceUserClient` |
| 8 | `AppleARMIODevice` |
| 8 | `AudioDMAController` |
| 8 | `AppleIOPADMAStream` |
| 8 | `AppleARMIISDevice` |
| 7 | `AppleARMIICDevice` |
| 6 | `AudioDMACLLTEscalationDetector` |
| 5 | `DCPAVAudioDMADelegate` |
| 4 | `AppleExternalSecondaryAudio` |
| 2 | `IOPAudioController` |

- **Codec:** `AppleCS42L84Audio`
- **Speaker drivers:** `AppleIOPADMAStream@audio-speaker`, `AppleIOPADMAStream@audio-speaker-tap`, `Speaker`, `SpeakerTap`, `audio-speaker`, `audio-speaker-left-tweeter`, `audio-speaker-left-woofer-2`, `audio-speaker-right-tweeter`, `audio-speaker-right-woofer-1`, `audio-speaker-right-woofer-2`, `audio-speaker-tap`
- **Mics:** `AppleIOPADMAStream@audio-hp-mic`, `Digital Mic`, `IOPAudioLPMicDevice`, `IOPAudioLPMicDeviceUserClient`, `LPMicInjection`, `audio-hp-mic`, `audio-hp-mic-proxy`, `lp-mic-device`, `lp-mic-injection-device`, `lp-mic-io-buffer-device`
- **AOP / low-power audio:** `AOPAudioService`, `AOPVoiceTriggerService`, `IOPAudioLPMicDevice`, `IOPAudioLPMicDeviceUserClient`, `LPMicInjection`

---

## 16. Human Interface Devices

HID flows through Apple's HID transport (`AppleHIDTransportHIDDevice`) and the **SPU** sensor/HID processor, which also carries the ambient-light sensor. `AppleUserHIDEventDriver` (DriverKit) and large pools of `IOHIDEventServiceUserClient` / `IOHIDLibUserClient` / `IOHIDInterface` carry events to userspace — the 251× event-service clients are the single most numerous class in the whole export, reflecting how many processes were observing input at capture time.

**Most common classes**

| Count | Object class |
|---:|:---|
| 251 | `IOHIDEventServiceUserClient` |
| 60 | `IOHIDLibUserClient` |
| 35 | `IOHIDInterface` |
| 14 | `IOHIDResourceDeviceUserClient` |
| 14 | `IOHIDUserDevice` |
| 12 | `AppleUserHIDEventService` |
| 12 | `IOHIDParamUserClient` |
| 8 | `AppleSPUHIDInterface` |
| 8 | `AppleSPUHIDDevice` |
| 7 | `AppleSPUHIDDriver` |
| 6 | `AppleHIDTransportInterface` |
| 6 | `AppleHIDTransportHIDDevice` |

- **HID transport:** `AppleHIDTransportBootloaderCBOR`, `AppleHIDTransportBootloaderHIDDevice`, `AppleHIDTransportBootloaderRTBuddy`, `AppleHIDTransportDeviceFIFO`, `AppleHIDTransportHIDDevice`, `AppleHIDTransportHibernator`, `AppleHIDTransportProtocolSCMFIFO`, `actuator`, `comm`, `keyboard`, `mtp`, `multi-touch` _(+2 more)_
- **SPU HID:** `AppleSPUHIDDevice`, `AppleSPUHIDDeviceUserClient`, `AppleSPUHIDDriver`, `AppleSPUHIDDriverUserClient`, `accel`, `als`, `als-temp`, `cma`, `devmotion6`, `gyro`, `las`, `wakehint`
- **Event drivers:** `AppleActuatorHIDEventDriver`, `AppleDeviceManagementHIDEventService`, `AppleHIDKeyboardEventDriverV2`, `AppleMultitouchTrackpadHIDEventDriver`, `AppleUserHIDEventDriver`, `IOHIDEventServiceUserClient`
- **Interfaces:** `IOHIDInterface`

---

## 17. Power, Thermal & Sensors

Sensor-dense as ever: **150× `AppleARMPMUPowerSensor`** and **75× `AppleARMPMUTempSensor`** blanket the larger die. The **SMC** (`AppleSMC`, `AppleSMCPMU`) is the system management controller; PMICs reach over **SPMI** (`AppleSPMIController`, `spmi-wifibt`, `lcd-pmic`), and the battery shows via `AppleSmartBattery`. More power/temp sensors than the M3 Max — consistent with a bigger, higher-core-count chip.

**Most common classes**

| Count | Object class |
|---:|:---|
| 150 | `AppleARMPMUPowerSensor` |
| 75 | `AppleARMPMUTempSensor` |
| 13 | `AppleARMSPMIDevice` |
| 10 | `AppleARMIODevice` |
| 8 | `AppleSPMIController` |
| 7 | `AppleSMCClient` |
| 5 | `ApplePMUFirmwareDriver` |
| 5 | `AppleSMCInterface` |
| 4 | `AppleHPMARMSPMI` |
| 4 | `AppleHPMUserClient` |
| 4 | `AppleSMCChargerUtil` |
| 3 | `AppleDialogSPMIPMU` |

- **Power sensors:** `AppleARMPMUPowerSensor`
- **Temp sensors:** `AppleARMPMUTempSensor`, `smctempsensor0`
- **SMC:** `AppleRSMChannelController`, `AppleRSMChannelControllerClient`, `AppleSMCChargerUtil`, `AppleSMCClient`, `AppleSMCKeysEndpoint`, `AppleSMCPMU`, `RTBuddy(SMC)`, `SMCEndpoint1`, `iop-smc-nub`, `smc`, `smc-charger-util`, `smc-charger-util-0` _(+4 more)_
- **PMIC / SPMI:** `AppleDialogSPMIPMU`, `AppleDialogSPMIPMURTC`, `AppleHPMARMSPMI`, `AppleSPMIController`, `AppleStockholmSPMI`, `aop-spmi0`, `btm`, `hpm0`, `hpm1`, `hpm2`, `hpm5`, `nub-spmi-a0` _(+14 more)_
- **Battery:** `AppleSmartBattery`, `AppleSmartBatteryManager`

---

## 18. Secure Enclave & Security

The classic **Secure Enclave** stack is still here — `AppleSEPManager`, `AppleKeyStore` / `AppleFDEKeyStore` (FileVault; 133× per-process keybag clients), `AppleMesaSEPDriver` (Touch ID), `AppleCredentialManager` (passkeys), `BootPolicy` (Secure Boot), and the AES accelerator. On M5 it's joined by its exclave counterpart `ExclaveSEPManagerProxy` (§8), tightening the isolation boundary.

**Most common classes**

| Count | Object class |
|---:|:---|
| 133 | `AppleKeyStoreUserClient` |
| 15 | `AppleCredentialManagerUserClient` |
| 12 | `AppleSEPDeviceService` |
| 10 | `BootPolicyUserClient` |
| 2 | `AppleMesaSEPDriver` |
| 2 | `AppleARMIODevice` |
| 2 | `AppleSEPXARTService` |
| 1 | `AppleARMSPIDevice` |
| 1 | `AppleMesaShim` |
| 1 | `AppleS8000AESAccelerator` |
| 1 | `AppleASCWrapV6SEP` |
| 1 | `AppleA7IOPNub` |

- **SEP manager/clients:** `AppleSEPManager`, `AppleSEPUserClient`, `sep-endpoint,cntl`, `sep-endpoint,hdcp`, `sep-endpoint,hibe`, `sep-endpoint,pnon`, `sep-endpoint,sbio`, `sep-endpoint,scrd`, `sep-endpoint,skdl`, `sep-endpoint,sks`, `sep-endpoint,sse`, `sep-endpoint,stac` _(+2 more)_
- **KeyStore:** `AppleFDEKeyStore`, `AppleKeyStore`, `AppleKeyStoreTest`, `AppleKeyStoreUserClient`
- **Touch ID (Mesa):** `AppleMesaAccessory`, `AppleMesaResources`, `AppleMesaSEPDriver`, `AppleMesaShim`, `mesa`
- **Credentials:** `AppleCredentialManager`, `AppleCredentialManagerUserClient`
- **Boot policy:** `BootPolicy`, `BootPolicyUserClient`

---

## 19. Low-Level Buses & GPIO

The electrical plumbing: **I²C** controllers and `AppleARMIICDevice`s, **I²S** audio serial (`AppleARMIISDevice`), **SPMI** (`AppleSPMIController` / `AppleARMSPMIDevice`) for power ICs and the Wi-Fi/BT rail, **PWM** (keyboard backlight), plus GPIO/AON pin controllers including an `AppleT8101GPIOIC`. These hang the sensors, codecs, and PMICs off the SoC.

**Most common classes**

| Count | Object class |
|---:|:---|
| 20 | `AppleARMIODevice` |
| 9 | `AppleS5L8940XI2CController` |
| 5 | `AppleARMIICDevice` |
| 3 | `AppleT8101GPIOIC` |
| 3 | `IOSerialBSDClient` |
| 2 | `AppleSPIMCController` |
| 2 | `IOUserUserClient` |
| 1 | `MogulAuthI2CRelayInterface` |
| 1 | `AppleARMSPIDevice` |
| 1 | `AppleS5L8920XFPWM` |
| 1 | `AppleSamsungSerial` |
| 1 | `AppleSimpleUARTSync` |

- **I2C:** `AppleS5L8940XI2CController`, `MogulAuthI2CRelayInterface`, `i2c0`, `i2c1`, `i2c2`, `i2c3`, `i2c4`, `i2c5`, `i2c6`, `i2c7`, `i2c8`, `mogul-las` _(+4 more)_
- **I2S audio:** `lp-mic-injection-device`
- **PWM:** `AppleS5L8920XFPWM`, `AppleS5L8920XPWM`, `pwm0`, `pwm1`
- **GPIO:** `AppleT8101GPIOIC`, `aon-ptd`, `dp2hdmi-gpio0`, `gpio0`, `nub-gpio0`

---

## 20. Telemetry, Logging & IOReporting

Instrumentation endpoints: **`IOReportUserClient`** counters (read by `powermetrics`/Activity Monitor), **`CCLogStream`/`CCPipe`/`CCIOService`** CoreCapture channels for Wi-Fi/Bluetooth/firmware logs (notably more numerous here, tracking the new Apple wireless stack), and `IOTimeSyncServiceDaemonClient` for precision time sync. `122` nodes.

**Most common classes**

| Count | Object class |
|---:|:---|
| 66 | `CCIOService` |
| 13 | `IOReportUserClient` |
| 13 | `IOTimeSyncServiceDaemonClient` |
| 5 | `IOTimeSyncClockManagerDaemonClient` |
| 4 | `IOTimeSyncSyncDaemonClient` |
| 2 | `IOTimeSyncgPTPManagerDaemonClient` |
| 1 | `IOUserUserClient` |
| 1 | `CCLogPipe` |
| 1 | `CCLogStream` |
| 1 | `CCDataPipe` |
| 1 | `AppleSPUTimesyncV2` |
| 1 | `AppleARMIODevice` |

- **IOReporting:** `IOReportHub`, `IOReportUserClient`
- **CoreCapture:** `CCDataStream`, `CCFaultReporter`, `CCLogStream`, `CCPipe`
- **Time sync:** `AirshipCentauriHelperTimesyncUserClient`, `AppleSPUTimesyncV2`, `IOTimeSyncClockManager`, `IOTimeSyncClockManagerDaemonClient`, `IOTimeSyncDaemonService`, `IOTimeSyncDaemonUserClient`, `IOTimeSyncDomain`, `IOTimeSyncDomainDaemonClient`, `IOTimeSyncRootService`, `IOTimeSyncServiceDaemonClient`, `IOTimeSyncSyncDaemonClient`, `IOTimeSyncTimeSyncTimePort` _(+4 more)_

---

## 21. User Clients

Per-process bridges between userspace and kernel drivers. They dominate the raw count because the registry is a live snapshot. Headliners: **186× `RootDomainUserClient`** (power-assertion handles), **170× `IOSurfaceRootUserClient`** (shared graphics buffers), and **0× `AppleKeyStoreUserClient`**. These reflect activity, not hardware.

**Most common classes**

| Count | Object class |
|---:|:---|
| 186 | `RootDomainUserClient` |
| 170 | `IOSurfaceRootUserClient` |
| 10 | `IOUserUserClient` |
| 8 | `DIDeviceIOUserClient` |
| 4 | `IOAccessoryManagerUserClient` |
| 4 | `com_apple_driver_FairPlayIOKitUserClient` |
| 3 | `AppleTrustedAccessoryManagerUserClient` |
| 3 | `CoreKDLUserClient` |
| 2 | `AppleBiometricServicesUserClient` |
| 2 | `AppleSSEUserClient` |
| 2 | `AppleSystemPolicyUserClient` |
| 2 | `AppleLIFSUserClient` |
| 1 | `AppleH16CamInUserClient` |
| 1 | `AppleActuatorDeviceUserClient` |
| 1 | `AppleImage4UserClient` |
| 1 | `AppleGCResourceDeviceUserClient` |

---

## 22. Other / Miscellaneous

Everything that didn't map cleanly above — `295` nodes. The class table shows what's here.

**Most common classes**

| Count | Object class |
|---:|:---|
| 43 | `AppleARMIODevice` |
| 35 | `IOService` |
| 20 | `IOUserService` |
| 16 | `IODPPortService` |
| 13 | `AppleSPU` |
| 13 | `ADMAChannelInterface` |
| 8 | `IOSurfaceAcceleratorClient` |
| 6 | `AppleTCONComponent` |
| 5 | `AppleMxWrap` |
| 4 | `AppleHPMDeviceHALType3` |
| 3 | `AppleTypeCRetimer` |
| 3 | `AppleHPMLDCMType2` |
| 3 | `AIDImageDownloader` |
| 3 | `AppleT6050PCIeC` |
| 3 | `ApplePCIeCPIODMA` |
| 3 | `AppleSPUAppInterface` |
| 3 | `AppleARMNORFlashDevice` |
| 3 | `APCIECMSIController` |

---

## 23. Appendix A — Full object-class frequency table

All distinct object classes in the export, by frequency — the authoritative inventory.

| Count | Object class |
|---:|:---|
| 251 | `IOHIDEventServiceUserClient` |
| 219 | `AppleARMIODevice` |
| 186 | `RootDomainUserClient` |
| 170 | `IOSurfaceRootUserClient` |
| 161 | `AGXDeviceUserClient` |
| 157 | `IODARTMapperNub` |
| 157 | `IODARTMapper` |
| 150 | `AppleARMPMUPowerSensor` |
| 133 | `AppleKeyStoreUserClient` |
| 108 | `RTBuddyEndpointService` |
| 93 | `AFKEPInterfaceKextV2` |
| 75 | `AppleARMPMUTempSensor` |
| 71 | `AFKEPInterfaceServiceKextV2` |
| 66 | `CCIOService` |
| 65 | `DCPEndpointV2` |
| 60 | `IOHIDLibUserClient` |
| 52 | `IOThunderboltPort` |
| 43 | `AppleT8110DART` |
| 41 | `IOPlatformDevice` |
| 40 | `AppleAPFSGraft` |
| 35 | `IOHIDInterface` |
| 35 | `IOService` |
| 30 | `IOUserUserClient` |
| 24 | `IOUserService` |
| 24 | `AppleA7IOPNub` |
| 23 | `IOUSBHostInterface` |
| 22 | `RTBuddy` |
| 22 | `RTBuddyService` |
| 21 | `IOMediaBSDClient` |
| 21 | `AppleAPFSVolume` |
| 21 | `AppleAPFSVolumeBSDClient` |
| 20 | `IOMedia` |
| 18 | `AppleARMCPU` |
| 18 | `AppleUSB20HubPort` |
| 18 | `AudioDMAChannel` |
| 17 | `IOUSBHostDevice` |
| 17 | `IOMobileFramebufferUserClient` |
| 16 | `AppleARMIICDevice` |
| 16 | `IODPPortService` |
| 16 | `AppleUSB30HubPort` |
| 15 | `AppleUSBXHCIAUSSPort` |
| 15 | `AppleCredentialManagerUserClient` |
| 14 | `AppleARMSPMIDevice` |
| 14 | `IOPCIDevice` |
| 14 | `AppleASCWrapV6` |
| 14 | `AppleHDCPInterface` |
| 14 | `IOHIDResourceDeviceUserClient` |
| 14 | `IOHIDUserDevice` |
| 13 | `IOPAudioNode` |
| 13 | `AppleSPU` |
| 13 | `ADMAChannelInterface` |
| 13 | `IOReportUserClient` |
| 13 | `IOTimeSyncServiceDaemonClient` |
| 12 | `AppleUserHIDEventService` |
| 12 | `IONetworkStack` |
| 12 | `IONetworkStackUserClient` |
| 12 | `IOBlockStorageDriver` |
| 12 | `RTBuddyIOReportingEndpoint` |
| 12 | `AppleThunderboltDPInAdapterOS2` |
| 12 | `AppleATCDPINAdapterPort` |
| 12 | `AppleSEPDeviceService` |
| 12 | `IOUSBDeviceInterface` |
| 12 | `IOHIDParamUserClient` |
| 11 | `AppleAPFSContainerScheme` |
| 11 | `AppleAPFSMedia` |
| 11 | `AppleAPFSMediaBSDClient` |
| 11 | `AppleAPFSContainer` |
| 10 | `IOAudio2DeviceUserClient` |
| 10 | `BootPolicyUserClient` |
| 9 | `AppleS5L8940XI2CController` |
| 9 | `IOGUIDPartitionScheme` |
| 9 | `DCPAVControllerProxy` |
| 9 | `DCPDPControllerProxy` |
| 9 | `AppleDCPDPTXRemoteHDCPInterfaceProxy` |
| 9 | `AppleIOPADMAStream` |
| 9 | `AppleARMIISDevice` |
| 8 | `AppleSPMIController` |
| 8 | `AppleSPUHIDInterface` |
| 8 | `AppleSPUHIDDevice` |
| 8 | `AudioDMAController` |
| 8 | `AppleDCPDPTXRemotePortProxy` |
| 8 | `AppleDCPDPTXRemotePortUFP` |
| 8 | `IOSurfaceAcceleratorClient` |
| 8 | `AppleAVDUserClient` |
| 8 | `AppleDiskImageDevice` |
| 8 | `DIDeviceIOUserClient` |
| 7 | `IOEthernetInterface` |
| 7 | `AppleSPUAppInterface` |
| 7 | `AppleSPUHIDDriver` |
| 7 | `AppleSMCClient` |
| 7 | `AppleUSBHostCompositeDevice` |
| 6 | `AppleTCONComponent` |
| 6 | `AppleHIDTransportInterface` |
| 6 | `AppleHIDTransportHIDDevice` |
| 6 | `AppleThunderboltUSBDownAdapter` |
| 6 | `AFKEPKextV2` |
| 6 | `AppleUSBDeviceNCMControl` |
| 6 | `AppleUSBDeviceNCMData` |
| 6 | `AudioDMACLLTEscalationDetector` |
| 6 | `IOUserServer` |
| 5 | `ApplePMUFirmwareDriver` |
| 5 | `AppleMxWrap` |
| 5 | `IOPCI2PCIBridge` |
| 5 | `AppleSMCInterface` |
| 5 | `AppleUserHIDDevice` |
| 5 | `IOMobileFramebufferShim` |
| 5 | `AppleDCPExpert` |
| 5 | `AFKLocalMemoryDescriptorManager` |
| 5 | `AppleDCPLinkServiceSoC` |
| 5 | `DCPAVAudioDMADelegate` |
| 5 | `H1xANELoadBalancerDirectPathClient` |
| 5 | `IOTimeSyncClockManagerDaemonClient` |
| 4 | `AppleHPMARMSPMI` |
| 4 | `AppleHPMDeviceHALType3` |
| 4 | `IOPortFeaturePowerIn` |
| 4 | `IOPortTransportStateCC` |
| 4 | `IOAccessoryManagerUserClient` |
| 4 | `AppleHPMUserClient` |
| 4 | `IOUserNetworkWLAN` |
| 4 | `IOSkywalkNetworkBSDClient` |
| 4 | `AppleT8142ATCDPXBAR` |
| 4 | `ApplePMGRNub` |
| 4 | `AppleCLPCUserClient` |
| 4 | `AppleSMCChargerUtil` |
| 4 | `AppleT6050TypeCPhy` |
| 4 | `AppleUSB20Hub` |
| 4 | `AppleUSBHostBillboardDevice` |
| 4 | `AppleUSB30Hub` |
| 4 | `AppleDPTXNub` |
| 4 | `AppleDCPDPTXRemoteHDCPAuthSessionProxy` |
| 4 | `AppleJPEGDriverUserClient` |
| 4 | `AppleExternalSecondaryAudio` |
| 4 | `com_apple_driver_FairPlayIOKitUserClient` |
| 4 | `IOServiceCompatibility` |
| 4 | `IOTimeSyncSyncDaemonClient` |
| 3 | `AppleTypeCRetimer` |
| 3 | `AppleHPMInterfaceType10` |
| 3 | `AppleHPMLDCMType2` |
| 3 | `IOPortFeatureLDCMUserClient` |
| 3 | `AppleTypeCPhyCIO80PhyMBI` |
| 3 | `AIDImageDownloader` |
| 3 | `AppleT6050PCIeC` |
| 3 | `ApplePCIECHostBridge` |
| 3 | `ApplePCIeCPIODMA` |
| 3 | `AppleThunderboltHALType7` |
| 3 | `AppleThunderboltNHIType7` |
| 3 | `IOThunderboltControllerType7` |
| 3 | `IOThunderboltLocalNode` |
| 3 | `IOThunderboltXDomainServiceClientManager` |
| 3 | `AppleThunderboltIPService` |
| 3 | `AppleThunderboltIPPort` |
| 3 | `IOThunderboltSwitchType7` |
| 3 | `AppleThunderboltPCIDownAdapter` |
| 3 | `AppleThunderboltDPOutAdapterOS2` |
| 3 | `AppleThunderboltPCIDownAdapterType5` |
| 3 | `AppleThunderboltUSBType2DownAdapter` |
| 3 | `AppleThunderboltDPConnectionManager` |
| 3 | `IOTBTTunnelClientInterfaceManager` |
| 3 | `AppleMxWrapACIO` |
| 3 | `AppleATCDPAltModePort` |
| 3 | `IOPortTransportStateDisplayPort` |
| 3 | `AppleT8101GPIOIC` |
| 3 | `AppleTrustedAccessoryManagerUserClient` |
| 3 | `CoreKDLUserClient` |
| 3 | `IOSerialBSDClient` |
| 3 | `AppleARMNORFlashDevice` |
| 3 | `AppleT8142USBXHCI` |
| 3 | `AppleUSB20XHCIARMPort` |
| 3 | `AppleUSB30XHCIARMPort` |
| 3 | `AppleT8142USBXDCI` |
| 3 | `IOUSBDeviceConfigurator` |
| 3 | `AppleUSBDeviceNCMPrivateEthernetInterface` |
| 3 | `AppleDialogSPMIPMU` |
| 3 | `IOPortFeaturePowerSource` |
| 3 | `DCPAVDeviceProxy` |
| 3 | `DCPDPDeviceProxy` |
| 3 | `DCPAVServiceProxy` |
| 3 | `DCPDPServiceProxy` |
| 3 | `DCPAVVideoInterfaceProxy` |
| 3 | `APCIECMSIController` |
| 3 | `ApplePCIECLegacyIntController` |
| 3 | `EndpointSecurityExternalClient` |
| 2 | `IODTNVRAMVariables` |
| 2 | `AppleProResHW` |
| 2 | `IOPAudioController` |
| 2 | `AppleSPIMCController` |
| 2 | `AppleARMSPIDevice` |
| 2 | `AppleMesaSEPDriver` |
| 2 | `AppleBiometricServices` |
| 2 | `AppleBiometricServicesUserClient` |
| 2 | `ApplePCIEHostBridge` |
| 2 | `TSNUserWiFiControlInterface` |
| 2 | `TSNWiFiInterface` |
| 2 | `AppleT6020PCIePIODMA` |
| 2 | `AppleDeviceManagementHIDEventService` |
| 2 | `AppleHIDKeyboardEventDriverV2` |
| 2 | `RTBuddyTraceKitEndpoint` |
| 2 | `AppleSPUHIDDriverUserClient` |
| 2 | `AOPAudioService` |
| 2 | `AFKFirmwareService` |
| 2 | `AppleSEPXARTService` |
| 2 | `AppleSSEUserClient` |
| 2 | `AppleUSBCDCCompositeDevice` |
| 2 | `IOSCSILogicalUnitNub` |
| 2 | `IOSCSIPeripheralDeviceType00` |
| 2 | `IOBlockStorageServices` |
| 2 | `AppleAUXDPTX` |
| 2 | `AppleDPTXController` |
| 2 | `AppleDPTXCrossbarAUXOnlyUFP` |
| 2 | `DCPAVAudioInterfaceProxy` |
| 2 | `DCPAVAudioDriver` |
| 2 | `AppleM2ScalerCSCDriver` |
| 2 | `AppleAVE2Driver` |
| 2 | `AppleJPEGDriver` |
| 2 | `AGXFirmwareKextG17RTBuddy` |
| 2 | `AppleSecondaryAudio` |
| 2 | `AppleEmbeddedAudioDevice` |
| 2 | `AppleProcessorTraceUserClient` |
| 2 | `IOTimeSyncgPTPManagerDaemonClient` |
| 2 | `AppleSystemPolicyUserClient` |
| 2 | `AppleLIFSUserClient` |
| 2 | `AppleBSDKextStarter` |
| 1 | `IORegistryEntry` |
| 1 | `IOPlatformExpertDevice` |
| 1 | `IODTNVRAM` |
| 1 | `IODTNVRAMDiags` |
| 1 | `IODTNVRAMPlatformNotifier` |
| 1 | `AppleARMPE` |
| 1 | `IOSystemStateNotification` |
| 1 | `IOPMrootDomain` |
| 1 | `IORootParent` |
| 1 | `AppleSoCIO` |
| 1 | `AppleSN012776Amp` |
| 1 | `AppleCS42L84Audio` |
| 1 | `AppleCS42L84Mikey` |
| 1 | `IOPAudioIsolatedVoiceTriggerDevice` |
| 1 | `IOPAudioVoiceTriggerDeviceUserClient` |
| 1 | `MogulAuthI2CRelayInterface` |
| 1 | `AppleAuthCPRelay` |
| 1 | `AppleAuthCPUserClient` |
| 1 | `AppleSandDollar` |
| 1 | `AppleMesaShim` |
| 1 | `AppleParadeDP855TCON` |
| 1 | `AppleH16CamIn` |
| 1 | `AppleH16CamInUserClient` |
| 1 | `IOExclaveProxy` |
| 1 | `AppleS5L8920XFPWM` |
| 1 | `AppleARMPWMDevice` |
| 1 | `AppleT6050PCIe` |
| 1 | `IOSkywalkLegacyEthernet` |
| 1 | `IOSkywalkLegacyEthernetInterface` |
| 1 | `AppleCentauriManager` |
| 1 | `CCLogPipe` |
| 1 | `CCLogStream` |
| 1 | `CCDataPipe` |
| 1 | `CCDataStream` |
| 1 | `AppleSDXC` |
| 1 | `AppleSDXCSlot` |
| 1 | `IOPortTransportStateSD` |
| 1 | `AppleSDXCBlockStorageDevice` |
| 1 | `AppleDockChannel` |
| 1 | `AppleDockChannelDevice` |
| 1 | `AppleHIDTransportHibernator` |
| 1 | `AppleHIDTransportDeviceFIFO` |
| 1 | `AppleHIDTransportBootloaderRTBuddy` |
| 1 | `AppleHIDTransportProtocolSCMFIFO` |
| 1 | `AppleHIDTransportManagement` |
| 1 | `AppleHIDTransportBootloaderCBOR` |
| 1 | `AppleMultitouchTrackpadHIDEventDriver` |
| 1 | `AppleMultitouchDevice` |
| 1 | `AppleMultitouchDeviceUserClient` |
| 1 | `AppleHIDTransportBootloaderHIDDevice` |
| 1 | `AppleActuatorHIDEventDriver` |
| 1 | `AppleActuatorDevice` |
| 1 | `AppleActuatorDeviceUserClient` |
| 1 | `AppleSecureRepair` |
| 1 | `IOThunderboltSwitchIntelJHL9580` |
| 1 | `AppleThunderboltPCIUpAdapter` |
| 1 | `AppleThunderboltUSBUpAdapter` |
| 1 | `AppleT6050DisplayCrossbar` |
| 1 | `AppleDisplayConnectionManager` |
| 1 | `AppleATCDPHDMIPort` |
| 1 | `AppleHDMIPortController` |
| 1 | `AppleT6050MemCacheController` |
| 1 | `AppleInterruptControllerV3` |
| 1 | `AppleARMWatchdogTimer` |
| 1 | `IOWatchdogUserClient` |
| 1 | `AppleSoCErrorHandler` |
| 1 | `AppleS8000AESAccelerator` |
| 1 | `AppleSPUTimesyncV2` |
| 1 | `AppleSPUFirmwareService` |
| 1 | `AppleSPUAppDriver` |
| 1 | `AppleSPUProfileDriver` |
| 1 | `AppleSPUHIDDeviceUserClient` |
| 1 | `AppleSPUVD6286` |
| 1 | `AppleSPUProfileFirmwareDriver` |
| 1 | `SecureRTBuddyProxy` |
| 1 | `SecureRTBuddyIOReporting` |
| 1 | `RTBuddyEntropyEndpoint` |
| 1 | `AppleT6050PMGR` |
| 1 | `AppleT6050SOCTuner` |
| 1 | `AppleCLPC` |
| 1 | `ApplePassthroughPPM` |
| 1 | `ApplePPMUserClient` |
| 1 | `AppleEventLogHandler` |
| 1 | `AppleSmartIO` |
| 1 | `AppleSmartIODMANub` |
| 1 | `AppleSmartIODMAController` |
| 1 | `ApplePMPFirmware` |
| 1 | `RTBuddyCoreAnalyticsEndpoint` |
| 1 | `ApplePMPv2` |
| 1 | `AppleASCWrapV6SEP` |
| 1 | `AppleSEPManager` |
| 1 | `NVMeSEPNotifier` |
| 1 | `HibernationService` |
| 1 | `AppleTrustedAccessoryManager` |
| 1 | `AppleSEPHDCPManager` |
| 1 | `CoreKDLDriver` |
| 1 | `AppleSSE` |
| 1 | `AppleSEPUserClient` |
| 1 | `ExclaveSEPManagerProxy` |
| 1 | `AppleANS3CGv2Controller` |
| 1 | `AppleEmbeddedNVMeTemperatureSensor` |
| 1 | `IOEmbeddedNVMeBlockDevice` |
| 1 | `AppleAPFSSnapshot` |
| 1 | `AppleNVMeNamespaceDevice` |
| 1 | `AppleNVMeEAN` |
| 1 | `AppleNVMeEANUC` |
| 1 | `IOCoastGuardSARTMapper` |
| 1 | `AppleSMCKeysEndpoint` |
| 1 | `AppleSMCPMU` |
| 1 | `AppleSmartBatteryManager` |
| 1 | `AppleSmartBattery` |
| 1 | `ApplePTD` |
| 1 | `AppleSamsungSerial` |
| 1 | `AppleSimpleUARTSync` |
| 1 | `AppleOnboardSerialBSDClient` |
| 1 | `AppleSerialShim` |
| 1 | `AppleQSPIMCController` |
| 1 | `AppleARMQuadSPIDevice` |
| 1 | `AppleARMSPIFlashController` |
| 1 | `AppleEmbeddedSimpleSPINORFlasherDriver` |
| 1 | `AppleARMNORNVRAM` |
| 1 | `AppleDiagnosticDataAccessReadOnly` |
| 1 | `AppleUSBACMControl` |
| 1 | `AppleUSBACMData` |
| 1 | `IOUSBMassStorageInterfaceNub` |
| 1 | `IOUSBMassStorageDriverNub` |
| 1 | `IOUSBMassStorageDriver` |
| 1 | `AppleUSBNCMControl` |
| 1 | `AppleUSBNCMData` |
| 1 | `AppleT6050USBXHCIAUSS` |
| 1 | `AppleDialogSPMIPMURTC` |
| 1 | `AppleBTM` |
| 1 | `IOPortTransportComponentCCUSBPDSOPp` |
| 1 | `IOPortTransportComponentCCUSBPDSOP` |
| 1 | `IOPortTransportStateUSB2` |
| 1 | `IOPortTransportStateCIO` |
| 1 | `IOPortTransportStateUSB3` |
| 1 | `IOPortTransportStatePCIe` |
| 1 | `AppleHPMInterfaceType11` |
| 1 | `AppleStockholmSPMI` |
| 1 | `AppleStockholmControlConfig` |
| 1 | `AppleStockholmControl` |
| 1 | `AFKEndpointInterfaceUserClient` |
| 1 | `DCPAVPowerControllerProxy` |
| 1 | `DCPAVRemoteSACControllerProxy` |
| 1 | `DCPAVSACController` |
| 1 | `H11ANEIn` |
| 1 | `ANEClientHints` |
| 1 | `ANEExclaveProxy` |
| 1 | `AppleAVD` |
| 1 | `AGXAcceleratorG17X` |
| 1 | `AGXArmFirmwareMapper` |
| 1 | `IOPAudioLPMicDevice` |
| 1 | `IOPAudioLPMicDeviceUserClient` |
| 1 | `IOPAudioIsolatedIOBufferDevice` |
| 1 | `IOPAudioIsolatedIOBufferDeviceUserClient` |
| 1 | `IOPAudioClientManagerDevice` |
| 1 | `IOPAudioClientManagerDeviceUserClient` |
| 1 | `SharedDARTMapperProxy` |
| 1 | `DMAChannelProxy` |
| 1 | `IISAudioIsolatedStreamECProxy` |
| 1 | `AppleSMCSensorDispatcher` |
| 1 | `AppleSMCSensorDispatcherUserClient` |
| 1 | `AppleARMLightEmUp` |
| 1 | `AppleS5L8920XPWM` |
| 1 | `AppleProcessorTraceT6050` |
| 1 | `AppleProcessorTraceNub` |
| 1 | `AppleM68Buttons` |
| 1 | `AppleARMBacklight` |
| 1 | `AppleSDXCSDDetect` |
| 1 | `AppleARMSlowAdaptiveClockingManager` |
| 1 | `AppleImage4` |
| 1 | `AppleImage4UserClient` |
| 1 | `AppleMobileApNonce` |
| 1 | `PassthruInterruptController` |
| 1 | `ApplePCIEMSIController` |
| 1 | `IOResources` |
| 1 | `com_apple_driver_FairPlayIOKit` |
| 1 | `AUC` |
| 1 | `AppleARMBootPerf` |
| 1 | `AppleARMSFRManifest` |
| 1 | `AppleMesaResources` |
| 1 | `AppleCredentialManager` |
| 1 | `AppleDiskImagesController` |
| 1 | `AppleFDEKeyStore` |
| 1 | `H1xANELoadBalancer` |
| 1 | `H1xANELoadBalancerClient` |
| 1 | `AppleIPAppender` |
| 1 | `AppleLockdownMode` |
| 1 | `AppleRSMChannelController` |
| 1 | `AppleRSMChannelControllerClient` |
| 1 | `AppleKeyStore` |
| 1 | `AppleKeyStoreTest` |
| 1 | `AppleT6050ANEHAL` |
| 1 | `AppleUIOMem` |
| 1 | `CoreAnalyticsHub` |
| 1 | `CoreAnalyticsMessenger` |
| 1 | `CoreAnalyticsUserClient` |
| 1 | `EndpointSecurityDriver` |
| 1 | `EndpointSecurityDriverClient` |
| 1 | `IOBluetoothHCIController` |
| 1 | `IOBluetoothACPIMethods` |
| 1 | `IOBluetoothHCIUserClient` |
| 1 | `IOBluetoothDevice` |
| 1 | `IOUserSerial` |
| 1 | `IODisplayWrangler` |
| 1 | `IOHDIXController` |
| 1 | `IOKitRegistryCompatibility` |
| 1 | `IOReportHub` |
| 1 | `AppleUSBHostResourcesTypeC` |
| 1 | `AppleUSBUserHCIResources` |
| 1 | `IOUSBMassStorageResource` |
| 1 | `IOUserEthernetResource` |
| 1 | `AppleEpochManager` |
| 1 | `IOTimeSyncRootService` |
| 1 | `IOTimeSyncClockManager` |
| 1 | `IOTimeSyncTranslationMach` |
| 1 | `IOTimeSyncgPTPManager` |
| 1 | `IOTimeSyncDomain` |
| 1 | `IOTimeSyncTimeSyncTimePort` |
| 1 | `IOTimeSyncDomainDaemonClient` |
| 1 | `IOTimeSyncDaemonService` |
| 1 | `IOTimeSyncDaemonUserClient` |
| 1 | `com_apple_AppleFSCompression_AppleFSCompressionTypeDataless` |
| 1 | `com_apple_AppleFSCompression_AppleFSCompressionTypeZlib` |
| 1 | `AppleMobileFileIntegrity` |
| 1 | `AppleGCResource` |
| 1 | `AppleGCResourceDeviceUserClient` |
| 1 | `AppleSystemPolicy` |
| 1 | `com_apple_BootCache` |
| 1 | `BootPolicy` |
| 1 | `com_apple_filesystems_hfs` |
| 1 | `com_apple_filesystems_hfs_encodings` |
| 1 | `IOHIDResource` |
| 1 | `AppleTrustedAccessory` |
| 1 | `AppleMesaAccessory` |
| 1 | `IOHIDSystem` |
| 1 | `IOHIDUserClient` |
| 1 | `IOHIDEventSystemUserClient` |
| 1 | `IOHIDPowerSourceController` |
| 1 | `IOHIDPowerSource` |
| 1 | `IOSurfaceRoot` |
| 1 | `AppleFairplayTextCrypter` |
| 1 | `com_apple_filesystems_apfs` |
| 1 | `com_apple_filesystems_lifs` |
| 1 | `com_apple_filesystems_nfs` |
| 1 | `IOAVBNub` |
| 1 | `IOAVBValidate` |
| 1 | `AppleSCSISubsystemGlobals` |
| 1 | `IOUserResources` |

---

_Generated from `ioservice-m5-max.json` — 3,950 registry nodes across 472 object classes._