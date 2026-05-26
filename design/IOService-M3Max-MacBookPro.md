# IOService Registry — Apple 14″ MacBook Pro (M3 Max)

A categorized field guide to everything exposed in the **IOService plane** of this machine's I/O Registry. Each node in the export carries its *object class*, *entry name*, *registry ID*, retain count, busy state, and — for the nodes attached to a physical bus — a *location*. The export is a structural snapshot, not a property dump: it maps the **topology and inventory** of hardware blocks, firmware coprocessors, and driver stacks rather than their live register contents.

## At a glance

| Metric | Value |
|---|---|
| Total registry nodes | **2,993** |
| Maximum tree depth | **21** levels |
| Distinct object classes | **419** |
| Distinct entry names | **1221** |
| Platform identifier | **J514mAP** — 14″ MacBook Pro |
| SoC | **Apple T6031 = M3 Max** (seen in `AppleT6031ANEHAL`, `AppleMCA2Cluster_T603x`) |
| CPU | **14 cores** — `AppleARMCPU` ×14 (10 performance + 4 efficiency) |
| GPU | **`AGXAcceleratorG15X`** — Apple family-9 GPU |
| Internal SSD | **APPLE SSD AP1024Z Media** |
| Display pipelines | **5× DCP** — 1 internal panel + 4 external (`dcpext0–3`) |
| Thunderbolt 4 controllers | **3×** `IOThunderboltControllerType5` |
| Wireless | **Broadcom** Wi-Fi (`AppleBCMWLANCore`) + `AppleBluetoothModule` |
| Audio codec | **Cirrus Logic CS42L84** (`AppleCS42L84Audio`) + 6-driver speaker array |

> **Scope & privacy:** this plane carries no serial numbers, MAC addresses, or credentials. It does surface APFS volume *names* and installed Xcode simulator runtimes.

## Table of contents

- [1. System Identity & Platform Fabric](#1-system-identity--platform-fabric)
- [2. CPU Complex](#2-cpu-complex)
- [3. GPU](#3-gpu)
- [4. Neural Engine (ANE)](#4-neural-engine-ane)
- [5. Media Engines — Video & Image](#5-media-engines--video--image)
- [6. Memory Mapping — DART / IOMMU](#6-memory-mapping--dart--iommu)
- [7. Coprocessors & RTKit](#7-coprocessors--rtkit)
- [8. Display & Graphics Output](#8-display--graphics-output)
- [9. Thunderbolt 4 / USB4](#9-thunderbolt-4--usb4)
- [10. USB](#10-usb)
- [11. Networking](#11-networking)
- [12. Bluetooth](#12-bluetooth)
- [13. Storage — NVMe, APFS & Disk Images](#13-storage--nvme-apfs--disk-images)
- [14. Audio Subsystem](#14-audio-subsystem)
- [15. Human Interface Devices](#15-human-interface-devices)
- [16. Power, Thermal & Sensors](#16-power-thermal--sensors)
- [17. Secure Enclave & Security](#17-secure-enclave--security)
- [18. Low-Level Buses & GPIO](#18-lowlevel-buses--gpio)
- [19. Telemetry, Logging & IOReporting](#19-telemetry-logging--ioreporting)
- [20. User Clients](#20-user-clients)
- [21. Other / Miscellaneous](#21-other--miscellaneous)
- [22. Appendix A — Full object-class frequency table](#22-appendix-a--full-objectclass-frequency-table)

---

## 1. System Identity & Platform Fabric

The registry root descends into a single **`IOPlatformExpertDevice`** named **`J514mAP`** — Apple's internal board code for the 14″ MacBook Pro. Everything else hangs beneath it. This category holds the SoC fabric glue: the platform expert, power manager nubs, and the address-space plumbing that the rest of the tree plugs into.

This branch is where macOS decides *what machine it is running on* and wires up the M3 Max's on-die fabric. `8` nodes fall here.

**Most common classes**

| Count | Object class |
|---:|:---|
| 2 | `AppleARMIODevice` |
| 2 | `ApplePMGRNub` |
| 1 | `IODTNVRAMPlatformNotifier` |
| 1 | `AppleH15PlatformErrorHandler` |
| 1 | `AppleT6031PMGR` |
| 1 | `IOServiceCompatibility` |

- **Fabric / power-manager nubs:** `AppleT6031PMGR`, `pmgr`, `pmgrtools`, `ppm`, `soc-tuner`

---

## 2. CPU Complex

Fourteen **`AppleARMCPU`** objects confirm a **14-core M3 Max** — 10 performance cores plus 4 efficiency cores. They are presented to the kernel through `cpu0`–`cpu14` **`IOPlatformDevice`** nubs under a `cpus` container, with an **`AppleMCA2Cluster_T603x`** memory-controller/cluster object marking the `T603x` silicon. Per-core debug interfaces (`acio-cpu*`, `cpu-debug-interface`) are also present.

**Most common classes**

| Count | Object class |
|---:|:---|
| 14 | `AppleARMCPU` |
| 4 | `AppleCLPCUserClient` |
| 4 | `AppleARMIODevice` |
| 1 | `AppleH15MemCacheController` |
| 1 | `ApplePMGRNub` |
| 1 | `AppleCLPC` |

- **Core objects:** `AppleARMCPU`
- **Debug:** `cpu-debug-interface`

---

## 3. GPU

The integrated GPU is an **`AGXAcceleratorG15X`** — the Apple "G15" / family-9 graphics architecture used in the M3 generation. Around it sits the AGX driver stack: the firmware coprocessor (`AGXFirmwareKextG15RTBuddy`), its firmware address mapper (`AGXArmFirmwareMapper`), and a large fleet of **`AGXDeviceUserClient`** objects — one per process currently talking to Metal. `IOAccelerator`, `IOGPU`, and IOSurface accelerator clients complete the rendering path.

This category contains `125` nodes, the bulk of which are per-process Metal clients.

**Most common classes**

| Count | Object class |
|---:|:---|
| 122 | `AGXDeviceUserClient` |
| 1 | `AGXAcceleratorG15X` |
| 1 | `AGXFirmwareKextG15RTBuddy` |
| 1 | `AGXArmFirmwareMapper` |

- **Accelerator:** `AGXAcceleratorG15X`
- **GPU firmware:** `AGXArmFirmwareMapper`, `AGXFirmwareKextG15RTBuddy`
- **Metal device clients:** `AGXDeviceUserClient`

---

## 4. Neural Engine (ANE)

The **Apple Neural Engine** appears as **`H11ANE`** (the hardware) fronted by **`AppleT6031ANEHAL`** — the hardware-abstraction layer keyed to the T6031/M3 Max die — and an **`H1xANELoadBalancer`** that distributes Core ML / `MLComputeUnits` work across the engine. The ANE has its own RTKit coprocessor (`RTBuddy(ANE)`), IOP nub (`iop-ane0-nub`), and dedicated DART (`dart-ane0`). Client objects (`H1xANELoadBalancerClient`, `…DirectPathClient`) represent apps running on-device inference.

**Most common classes**

| Count | Object class |
|---:|:---|
| 5 | `H1xANELoadBalancerDirectPathClient` |
| 2 | `AppleARMIODevice` |
| 1 | `AppleA7IOPNub` |
| 1 | `RTBuddy` |
| 1 | `H11ANEIn` |
| 1 | `ANEClientHints` |
| 1 | `IODARTMapperNub` |
| 1 | `H1xANELoadBalancer` |
| 1 | `H1xANELoadBalancerClient` |
| 1 | `AppleT6031ANEHAL` |

- **Engine + HAL:** `AppleT6031ANEHAL`, `H11ANE`
- **Load balancer:** `ANEDriverRoot`, `H1xANELoadBalancerClient`, `H1xANELoadBalancerDirectPathClient`
- **Device nodes:** `ane0`, `dart-ane0`, `iop-ane0-nub`, `mapper-ane0`
- **RTKit:** `RTBuddy(ANE)`

---

## 5. Media Engines — Video & Image

Apple's dedicated media silicon shows up as discrete engines, each with its own DART:

- **`AppleAVD`** / `avd0` — the **Apple Video Decoder** (H.264/HEVC/AV1 hardware decode).
- **`AppleJPEGDriver`** / `jpeg0` — hardware JPEG encode/decode.
- Scaler/format-conversion and ProRes blocks surface through the same `AppleARMIODevice` pattern.

These offload video and image work from the CPU/GPU and are what make all-day battery video playback and ProRes editing possible on this class of machine. `68` nodes total.

**Most common classes**

| Count | Object class |
|---:|:---|
| 15 | `AFKEPInterfaceKextV2` |
| 14 | `AppleARMIODevice` |
| 12 | `IODARTMapperNub` |
| 10 | `AppleJPEGDriverUserClient` |
| 7 | `AppleAVDUserClient` |
| 2 | `AppleM2ScalerCSCDriver` |
| 2 | `AppleProResHW` |
| 2 | `AppleJPEGDriver` |
| 1 | `DCPAVDeviceProxy` |
| 1 | `AppleAVD` |
| 1 | `AppleEmbeddedAudioDevice` |
| 1 | `AppleSecondaryAudio` |

- **Video decoder:** `AppleAVD`, `AppleAVDUserClient`, `DCPAVDeviceProxy`, `avd0`, `dart-avd0`, `mapper-avd0`, `mapper-avd0-adsbuf`, `mapper-avd0-piodma`
- **JPEG:** `AppleJPEGDriver`, `AppleJPEGDriverUserClient`, `dart-jpeg0`, `dart-jpeg1`, `jpeg0`, `jpeg1`, `mapper-jpeg0`, `mapper-jpeg1`
- **Clients:** `AppleAVDUserClient`, `AppleJPEGDriverUserClient`

---

## 6. Memory Mapping — DART / IOMMU

**DART** (Device Address Resolution Table) is Apple's IOMMU — it gives each peripheral its own isolated, translated view of memory. This is one of the largest categories in the tree (`297` nodes) because *every* DMA-capable block gets a `dart-*` device, an `AppleT8110DART` controller, an `IODARTMapper`, and a per-attachment `IODARTMapperNub`. You can read the DART names like a directory of bus-mastering hardware: `dart-ane0`, `dart-avd0`, `dart-acio0`, `dart-usb0/1`, `dart-sio`, and many more.

**Most common classes**

| Count | Object class |
|---:|:---|
| 122 | `IODARTMapper` |
| 108 | `IODARTMapperNub` |
| 37 | `AppleT8110DART` |
| 29 | `AppleARMIODevice` |
| 1 | `IOCoastGuardSARTMapper` |

- **DART controllers:** `AppleT8110DART`
- **DART devices:** `dart-acio0`, `dart-acio1`, `dart-acio2`, `dart-aop`, `dart-apcie0`, `dart-apcie1`, `dart-apciec0`, `dart-apciec1`, `dart-apciec2`, `dart-apr0`, `dart-apr1`, `dart-ave0` _(+16 more)_
- **Mapper nubs:** `mapper-acio0-rx-0`, `mapper-acio0-rx-1`, `mapper-acio0-rx-10`, `mapper-acio0-rx-11`, `mapper-acio0-rx-2`, `mapper-acio0-rx-3`, `mapper-acio0-rx-4`, `mapper-acio0-rx-5`, `mapper-acio0-rx-6`, `mapper-acio0-rx-7`, `mapper-acio0-rx-8`, `mapper-acio0-rx-9` _(+97 more)_

---

## 7. Coprocessors & RTKit

Apple Silicon is a constellation of small real-time processors coordinated over **RTKit**. In the registry these appear as **`RTBuddy`** cores and **`RTBuddyEndpointService`** / **`DCPEndpointV2`** mailboxes, with **`AppleA7IOPNub`** I/O-processor nubs and **`AppleASCWrapV6`** wrappers around each ASC (Apple System Coprocessor). The **AOP** (Always-On Processor) lives here too, handling sensors and audio wake while the main CPUs sleep. The **`AFKEPInterfaceKextV2`** objects are the "Apple Firmware Kit" endpoints that carry typed messages between the kernel and each coprocessor. This is the single biggest functional category at `234` nodes.

**Most common classes**

| Count | Object class |
|---:|:---|
| 65 | `AFKEPInterfaceServiceKextV2` |
| 30 | `IOPlatformDevice` |
| 20 | `AFKEPInterfaceKextV2` |
| 18 | `RTBuddyEndpointService` |
| 16 | `RTBuddyService` |
| 13 | `AppleASCWrapV6` |
| 11 | `RTBuddyIOReportingEndpoint` |
| 7 | `AppleA7IOPNub` |
| 6 | `RTBuddy` |
| 6 | `IOPCIDevice` |
| 5 | `AFKLocalMemoryDescriptorManager` |
| 4 | `AppleARMIODevice` |

- **RTKit cores:** `RTBuddyService`
- **IOP nubs:** `ans-pcie`, `iop-ans-nub`, `iop-aop-nub`, `iop-gfx-nub0`, `iop-mtp-nub`, `iop-pmp0-nub`, `iop-sio-nub`
- **ASC wrappers:** `AppleASCWrapV6`

---

## 8. Display & Graphics Output

Display is driven by the **DCP — Display CoProcessor**. There are **5** DCP pipelines: one **`AppleDCPExpert`** for the internal Liquid Retina XDR panel plus four **`dcpext0–3`** for external displays (matching the 3 Thunderbolt outputs + HDMI). Each pipeline exposes an `IOMobileFramebuffer`, a remote DisplayPort transmitter proxy (`AppleDCPDPTXRemotePortProxy`), HDCP content-protection interfaces (`AppleHDCPInterface`, `AppleSEPHDCPManager`), and a swarm of `DCPEndpointV2` mailboxes. Panel brightness runs through **`AppleARMBacklight`**; an **`AppleT603XDisplayCrossbar`** routes pixel streams to outputs.

**Most common classes**

| Count | Object class |
|---:|:---|
| 70 | `RTBuddyEndpointService` |
| 65 | `DCPEndpointV2` |
| 42 | `AFKEPInterfaceKextV2` |
| 16 | `AppleARMIODevice` |
| 14 | `AppleHDCPInterface` |
| 13 | `IOMobileFramebufferUserClient` |
| 9 | `DCPAVControllerProxy` |
| 9 | `DCPDPControllerProxy` |
| 9 | `AppleDCPDPTXRemoteHDCPInterfaceProxy` |
| 8 | `AppleDCPDPTXRemotePortProxy` |
| 8 | `AppleDCPDPTXRemotePortUFP` |
| 5 | `IOMobileFramebufferShim` |

- **DCP expert / external:** `AFKDCPEXT0Endpoint1`, `AFKDCPEXT0Endpoint10`, `AFKDCPEXT0Endpoint11`, `AFKDCPEXT0Endpoint12`, `AFKDCPEXT0Endpoint18`, `AFKDCPEXT0Endpoint2`, `AFKDCPEXT0Endpoint3`, `AFKDCPEXT0Endpoint4`, `AFKDCPEXT0Endpoint5`, `AFKDCPEXT0Endpoint6`, `AFKDCPEXT0Endpoint7`, `AFKDCPEXT0Endpoint8` _(+118 more)_
- **Framebuffers:** `IOMobileFramebufferShim`, `IOMobileFramebufferUserClient`
- **HDCP:** `AppleDCPDPTXRemoteHDCPInterfaceProxy`, `AppleHDCPInterface`, `dispext0:dcpdptx-hdcp-interface:0`, `dispext0:dcpdptx-hdcp-interface:1`, `dispext1:dcpdptx-hdcp-interface:0`, `dispext1:dcpdptx-hdcp-interface:1`, `dispext2:dcpdptx-hdcp-interface:0`, `dispext2:dcpdptx-hdcp-interface:1`, `dispext3:dcpdptx-hdcp-interface:0`, `dispext3:dcpdptx-hdcp-interface:1`
- **Backlight & crossbar:** `AppleARMBacklight`, `AppleT603XDisplayCrossbar(display-crossbar0)`, `backlight`, `display-crossbar0`, `kbd-backlight`

---

## 9. Thunderbolt 4 / USB4

Three **`IOThunderboltControllerType5`** + **`AppleThunderboltNHIType5`** stacks correspond to the machine's three **Thunderbolt 4 / USB4** ports. Each carries the full tunnel fabric: **`IOThunderboltPort`** (21 in total), DisplayPort-in adapters (`AppleThunderboltDPInAdapterOS`), PCIe-down and USB-down adapters, an IP-over-Thunderbolt service (`AppleThunderboltIPService`), and an `AppleMxWrapACIO` wrapping the `acio0` Apple Converged I/O block. `78` nodes in all.

**Most common classes**

| Count | Object class |
|---:|:---|
| 21 | `IOThunderboltPort` |
| 6 | `AppleARMIODevice` |
| 6 | `AppleThunderboltDPInAdapterOS` |
| 3 | `AppleThunderboltHALType5` |
| 3 | `AppleThunderboltNHIType5` |
| 3 | `IOThunderboltControllerType5` |
| 3 | `IOThunderboltLocalNode` |
| 3 | `IOThunderboltXDomainServiceClientManager` |
| 3 | `AppleThunderboltIPService` |
| 3 | `AppleThunderboltIPPort` |
| 3 | `IOThunderboltSwitchType5` |
| 3 | `AppleThunderboltPCIDownAdapterType5` |

- **Controllers / NHI:** `AppleThunderboltHALType5`, `AppleThunderboltNHIType5`, `IOThunderboltControllerType5`
- **Ports:** `IOThunderboltPort`
- **Adapters:** `AppleThunderboltDPInAdapterOS`, `AppleThunderboltPCIDownAdapterType5`, `AppleThunderboltUSBDownAdapter`
- **IP-over-TB:** `AppleThunderboltIPPort`, `AppleThunderboltIPService`

---

## 10. USB

The USB stack rides on top of Thunderbolt/USB4 plus the SoC's own **`AppleT8122USBXHCI`** (host) and **`AppleT8122USBXDCI`** (device-mode) controllers and a `usb-drd0` dual-role port (with separate high-speed and SuperSpeed sub-ports). The numerous **`AppleUSBDeviceNCM*`** / **`AppleUSBNCM*`** objects are USB **network control model** interfaces — these back tethering and the internal USB-Ethernet links used by virtualization and device bridging.

**Most common classes**

| Count | Object class |
|---:|:---|
| 12 | `IOUSBDeviceInterface` |
| 6 | `AppleUSBDeviceNCMControl` |
| 6 | `AppleUSBDeviceNCMData` |
| 3 | `AppleARMIODevice` |
| 3 | `AppleT8122USBXHCI` |
| 3 | `AppleUSB20XHCIARMPort` |
| 3 | `AppleUSB30XHCIARMPort` |
| 3 | `AppleT8122USBXDCI` |
| 3 | `IOUSBDeviceConfigurator` |
| 3 | `AppleUSBDeviceNCMPrivateEthernetInterface` |
| 3 | `AppleHPMInterfaceType10` |
| 3 | `IOPlatformDevice` |

- **XHCI/XDCI controllers:** `AppleT8122USBXDCI`, `AppleT8122USBXHCI`, `usb-drd0-port-hs`, `usb-drd0-port-ss`, `usb-drd1-port-hs`, `usb-drd1-port-ss`, `usb-drd2-port-hs`, `usb-drd2-port-ss`
- **Dual-role port:** `usb-drd0`, `usb-drd0-port-hs`, `usb-drd0-port-ss`, `usb-drd1`, `usb-drd1-port-hs`, `usb-drd1-port-ss`, `usb-drd2`, `usb-drd2-port-hs`, `usb-drd2-port-ss`
- **NCM (USB networking):** `AppleUSBDeviceNCMControl`, `AppleUSBDeviceNCMData`, `AppleUSBNCMControl`, `AppleUSBNCMControlAux`, `AppleUSBNCMData`, `AppleUSBNCMDataAux`, `anpi0`, `anpi1`, `anpi2`
- **Configurators:** `IOUSBDeviceConfigurator`

---

## 11. Networking

Wi-Fi is **Broadcom**: `AppleBCMWLANCore` over `AppleBCMWLANBusInterfacePCIe`, surfaced as a `wlan` interface and an `AppleBCMWLANSkywalkInterface`. Modern macOS networking runs on **Skywalk**, Apple's userspace-ish network stack — hence `AppleConvergedIPCSkywalkInterface`, `IOSkywalkKernelPipeBSDClient`, and `IOSkywalkNetworkBSDClient`. Multiple **`IONetworkStack`** instances and 15× `IO80211APIUserClient` round out the picture (Wi-Fi management daemons + virtual interfaces).

**Most common classes**

| Count | Object class |
|---:|:---|
| 15 | `IOUserUserClient` |
| 11 | `IONetworkStack` |
| 11 | `IONetworkStackUserClient` |
| 6 | `IOEthernetInterface` |
| 5 | `AppleConvergedIPCSkywalkInterface` |
| 5 | `IOSkywalkKernelPipeBSDClient` |
| 4 | `IOUserNetworkWLAN` |
| 4 | `IOSkywalkNetworkBSDClient` |
| 3 | `IOUserService` |
| 1 | `IOPCIDevice` |
| 1 | `IOSkywalkLegacyEthernet` |
| 1 | `IOSkywalkLegacyEthernetInterface` |

- **Wi-Fi (Broadcom):** `AppleBCMWLANBusInterfacePCIe`, `AppleBCMWLANCore`, `AppleBCMWLANIO80211APSTAInterface`, `AppleBCMWLANLowLatencyInterface`, `AppleBCMWLANProximityInterface`, `AppleBCMWLANSkywalkInterface`, `IOUserServer(com.apple.bcmwlan-0x100001035)`, `wlan`
- **802.11 clients:** `AppleBCMWLANIO80211APSTAInterface`, `IO80211APIUserClient`, `IO80211ReporterProxy`
- **Skywalk:** `AppleBCMWLANSkywalkInterface`, `AppleConvergedIPCSkywalkInterface`, `IOSkywalkKernelPipeBSDClient`, `IOSkywalkLegacyEthernet`, `IOSkywalkNetworkBSDClient`, `en0`
- **Network stack:** `IONetworkStack`, `IONetworkStackUserClient`

---

## 12. Bluetooth

Bluetooth is a discrete **`AppleBluetoothModule`** on a `bluetooth-pcie` link, driven by an **`IOBluetoothHCIController`**. Note the **`IOUserBluetoothSerialDriver`** running in its own `IOUserServer` — a DriverKit (userspace) driver, reflecting Apple's ongoing migration of drivers out of the kernel.

**Most common classes**

| Count | Object class |
|---:|:---|
| 1 | `IOPCIDevice` |
| 1 | `AppleARMIODevice` |
| 1 | `AppleBluetoothModule` |
| 1 | `IOBluetoothHCIController` |
| 1 | `IOBluetoothACPIMethods` |
| 1 | `IOBluetoothHCIUserClient` |
| 1 | `IOBluetoothDevice` |
| 1 | `IOUserService` |
| 1 | `IOUserUserClient` |
| 1 | `IOUserServer` |

- **Module / transport:** `AppleBluetoothModule`, `bluetooth-pcie`
- **HCI controller:** `IOBluetoothHCIController`
- **DriverKit serial:** `IOUserBluetoothSerialClient`, `IOUserBluetoothSerialDriver`, `IOUserServer(com.apple.IOUserBluetoothSerialDriver-0x1000012ff)`

---

## 13. Storage — NVMe, APFS & Disk Images

The internal drive is **`APPLE SSD AP1024Z Media`** (a 1 TB Apple NVMe module). On top of it macOS builds the standard **APFS** stack: an `AppleAPFSContainer` holding the named volumes, each surfaced through an `AppleAPFSVolumeBSDClient` (the `/dev/diskNsM` node). Partition schemes (`IOGUIDPartitionScheme`), block-storage drivers, and a fleet of mounted **disk images** (`Apple Disk Image Media`) are all here.

**Named macOS volumes present:** `Macintosh HD` and `Macintosh HD - Data` (the signed system snapshot + your data), plus the standard system roles `Preboot`, `Recovery`, `VM`, `Update`, `xART`, `iSCPreboot`, `Hardware`, and `Managed Data (501)`. Signed system cryptexes appear too (`MetalToolchainCryptex`, `…arm64eSystemCryptex`).

**Xcode simulator runtimes mounted as images:** `AppleTVOS 26.5 Simulator`, `WatchOS 26.4 Simulator`, `WatchOS 26.5 Simulator`, `XROS 26.5 Simulator`, `iOS 26.4.1 Simulator`, `iOS 26.5 Simulator`.

**Most common classes**

| Count | Object class |
|---:|:---|
| 37 | `AppleAPFSGraft` |
| 20 | `AppleAPFSVolumeBSDClient` |
| 19 | `IOMediaBSDClient` |
| 19 | `AppleAPFSVolume` |
| 18 | `IOMedia` |
| 10 | `AppleAPFSContainerScheme` |
| 10 | `AppleAPFSMedia` |
| 10 | `AppleAPFSMediaBSDClient` |
| 10 | `AppleAPFSContainer` |
| 9 | `IOBlockStorageDriver` |
| 8 | `IOGUIDPartitionScheme` |
| 6 | `AppleDiskImageDevice` |

- **Physical SSD:** `APPLE SSD AP1024Z Media`
- **APFS containers/volumes:** `AppleAPFSContainer`, `AppleAPFSMedia`, `AppleTVOS 26.5 Simulator`, `Hardware`, `Macintosh HD`, `Macintosh HD - Data`, `Managed Data (501)`, `MetalToolchainCryptex`, `Preboot`, `Recovery`, `Update`, `VM` _(+6 more)_
- **Partition schemes:** `IOGUIDPartitionScheme`
- **Disk images:** `Apple Disk Image Media`, `Apple disk image Media`

---

## 14. Audio Subsystem

Audio is built around the **Cirrus Logic CS42L84** codec (`AppleCS42L84Audio`) and the SoC's **`AppleMCA2Cluster_T603x`** I²S/MCA audio clusters feeding `AudioDMAChannel` engines (56 of them — Apple allocates a generous pool of DMA streams). The internal speaker array is fully enumerated as six drivers — **left woofer ×2 + tweeter** and **right woofer ×2 + tweeter** — alongside the digital microphone array (`Digital Mic`, `audio-leap-mic`) and an internal loopback. The **AOP** (Always-On Processor) hosts `AppleAOPAudioClientManager` for low-power "Hey Siri"-style listening.

**Most common classes**

| Count | Object class |
|---:|:---|
| 56 | `AudioDMAChannel` |
| 7 | `AppleARMIICDevice` |
| 7 | `AppleARMIODevice` |
| 6 | `AppleARMIISDevice` |
| 6 | `IOAudio2DeviceUserClient` |
| 5 | `AppleAOPAudioDeviceNode` |
| 5 | `DCPAVAudioDMADelegate` |
| 4 | `AppleMCA2Controller_T603x` |
| 3 | `AppleMCA2Cluster_T603x` |
| 2 | `AppleExternalSecondaryAudio` |
| 2 | `AudioDMAController` |
| 2 | `AppleAOPAudioClientManager` |

- **Codec:** `AppleCS42L84Audio`, `audio-codec-input`, `audio-codec-output`
- **Speaker drivers:** `Speaker`, `audio-speaker`, `audio-speaker-left-tweeter`, `audio-speaker-left-woofer-2`, `audio-speaker-right-tweeter`, `audio-speaker-right-woofer-1`, `audio-speaker-right-woofer-2`
- **Mic / loopback:** `AppleAOPAudioLPMicInDevice`, `Digital Mic`, `LEAP Internal Loopback`, `Loopback`, `audio-leap-internal-loopback`, `audio-leap-mic`, `audio-loopback`, `audio-lp-mic-in`
- **AOP audio:** `AppleAOPAudioClientManager`, `AppleAOPAudioController`, `AppleAOPAudioLPMicInDevice`, `AppleAOPAudioPDM2Device`, `AppleAOPAudioService`, `AppleAOPAudioUserClient`, `audio-hp`, `audio-leap-internal-loopback`, `audio-lp-mic-in`, `audio-pdm2`, `hfdc-2400000`

---

## 15. Human Interface Devices

Human-interface devices flow through Apple's HID transport. The keyboard, trackpad, and Touch ID/relay sit behind **`AppleHIDTransportHIDDevice`** and the **SPU** (`AppleSPU`, `AppleSPUHIDDriver`) — the sensor/HID processor that also exposes the **ambient-light sensor** (`als`) and lid/temperature inputs. `AppleUserHIDEventDriver` (DriverKit) and a large pool of `IOHIDEventServiceUserClient` / `IOHIDInterface` objects carry events up to userspace. `IOHIDUserDevice` / `IOHIDResourceDeviceUserClient` back virtual HID devices.

**Most common classes**

| Count | Object class |
|---:|:---|
| 140 | `IOHIDEventServiceUserClient` |
| 27 | `IOHIDInterface` |
| 11 | `IOHIDResourceDeviceUserClient` |
| 11 | `IOHIDUserDevice` |
| 8 | `AppleSPUHIDInterface` |
| 8 | `AppleSPUHIDDevice` |
| 7 | `AppleSPUHIDDriver` |
| 7 | `IOHIDParamUserClient` |
| 6 | `AppleHIDTransportInterface` |
| 6 | `AppleHIDTransportHIDDevice` |
| 5 | `AppleUserHIDEventService` |
| 4 | `IOHIDLibUserClient` |

- **HID transport:** `AppleHIDTransportBootloaderCBOR`, `AppleHIDTransportBootloaderHIDDevice`, `AppleHIDTransportBootloaderRTBuddy`, `AppleHIDTransportDeviceFIFO`, `AppleHIDTransportHIDDevice`, `AppleHIDTransportHibernator`, `AppleHIDTransportProtocolSCMFIFO`, `actuator`, `comm`, `keyboard`, `mtp`, `multi-touch` _(+2 more)_
- **SPU HID:** `AppleSPUHIDDevice`, `AppleSPUHIDDeviceUserClient`, `AppleSPUHIDDriver`, `AppleSPUHIDDriverUserClient`, `accel`, `als`, `als-temp`, `cma`, `devmotion6`, `gyro`, `las`, `wakehint`
- **Event drivers:** `AppleActuatorHIDEventDriver`, `AppleDeviceManagementHIDEventService`, `AppleHIDKeyboardEventDriverV2`, `AppleMultitouchTrackpadHIDEventDriver`, `AppleUserHIDEventDriver`, `IOHIDEventServiceUserClient`
- **Interfaces:** `IOHIDInterface`
- **Virtual HID:** `IOHIDResourceDeviceUserClient`, `IOHIDUserDevice`

---

## 16. Power, Thermal & Sensors

This is sensor-dense: **78× `AppleARMPMUPowerSensor`** and **44× `AppleARMPMUTempSensor`** blanket the die, measuring per-block power draw and temperature — the raw inputs to Apple's closed-loop performance/thermal control. The **SMC** (`AppleSMC`, `smc-pmu`, `AppleSMCPMU`) is the system management controller; the **`AppleDialogSPMIPMU`** is the Dialog/Renesas power-management IC reached over **SPMI**, and it provides the real-time clock (`…PMURTC`). The battery is exposed via **`AppleSmartBattery`** + `AppleSmartBatteryManager`.

**Most common classes**

| Count | Object class |
|---:|:---|
| 78 | `AppleARMPMUPowerSensor` |
| 44 | `AppleARMPMUTempSensor` |
| 14 | `AppleARMSPMIDevice` |
| 13 | `AppleARMIODevice` |
| 10 | `AppleSPMIController` |
| 7 | `AppleSMCClient` |
| 5 | `AppleSMCInterface` |
| 4 | `AppleSMCChargerUtil` |
| 4 | `AppleHPMARMSPMI` |
| 4 | `AppleHPMUserClient` |
| 2 | `AppleDialogSPMIPMU` |
| 1 | `AppleA7IOPNub` |

- **Power sensors:** `AppleARMPMUPowerSensor`
- **Temp sensors:** `AppleARMPMUTempSensor`, `smctempsensor0`
- **SMC:** `AppleRSMChannelController`, `AppleRSMChannelControllerClient`, `AppleSMCChargerUtil`, `AppleSMCClient`, `AppleSMCKeysEndpoint`, `AppleSMCPMU`, `RTBuddy(SMC)`, `SMCEndpoint1`, `iop-smc-nub`, `smc`, `smc-charger-util`, `smc-charger-util-0` _(+5 more)_
- **PMIC (Dialog/SPMI):** `AppleDialogSPMIPMU`, `AppleDialogSPMIPMURTC`, `AppleHPMARMSPMI`, `AppleSPMIController`, `AppleStockholmSPMI`, `aop-spmi0`, `aop-spmi1`, `btm`, `hpm0`, `hpm1`, `hpm2`, `hpm5` _(+17 more)_
- **Battery:** `AppleSmartBattery`, `AppleSmartBatteryManager`

---

## 17. Secure Enclave & Security

The **Secure Enclave Processor (SEP)** is its own world: `AppleSEPManager`, `AppleSEPUserClient`, and SEP-hosted services for key storage and content protection. Key blocks:

- **`AppleKeyStore`** / `AppleFDEKeyStore` — FileVault and class-key management (the 129× `AppleKeyStoreUserClient` are per-process keybag handles).
- **`AppleMesaSEPDriver`** — the **Touch ID** fingerprint sensor pipeline ("Mesa").
- **`AppleCredentialManager`** — passkeys / credential storage.
- **`AppleSEPXARTService`** + `xART` volume — anti-replay tamper protection.
- **`BootPolicy`** — Secure Boot policy (the per-volume `…SystemCryptex` and `MetalToolchainCryptex` reflect signed system cryptexes).
- **`AppleS8000AESAccelerator`** — hardware AES for storage encryption.

**Most common classes**

| Count | Object class |
|---:|:---|
| 129 | `AppleKeyStoreUserClient` |
| 12 | `AppleSEPDeviceService` |
| 10 | `AppleCredentialManagerUserClient` |
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
- **Touch ID (Mesa):** `AppleMesaResources`, `AppleMesaSEPDriver`, `AppleMesaShim`, `mesa`
- **Credentials:** `AppleCredentialManager`, `AppleCredentialManagerUserClient`
- **Boot policy:** `BootPolicy`, `BootPolicyUserClient`
- **AES:** `AppleS8000AESAccelerator`

---

## 18. Low-Level Buses & GPIO

The low-level bus controllers that hang sensors, codecs, and PMICs off the SoC: **I²C** (`AppleS5L8940XI2CController`, `AppleARMIICDevice`), **I²S** audio serial (`AppleARMIISDevice`), **SPMI** (`AppleSPMIController` / `AppleARMSPMIDevice`) for power ICs, **PWM** (`AppleARMPWMDevice`, e.g. keyboard backlight), plus GPIO/AON pin controllers. These are the electrical plumbing beneath the higher-level subsystems above.

**Most common classes**

| Count | Object class |
|---:|:---|
| 17 | `AppleARMIODevice` |
| 6 | `AppleS5L8940XI2CController` |
| 5 | `AppleARMIICDevice` |
| 4 | `AppleT8101GPIOIC` |
| 2 | `AppleSPIMCController` |
| 2 | `IOSerialBSDClient` |
| 2 | `IOUserUserClient` |
| 1 | `AppleARMSPIDevice` |
| 1 | `AppleS5L8920XFPWM` |
| 1 | `AppleS8000DWI` |
| 1 | `AppleS5L8960XNCO` |
| 1 | `AppleSamsungSerial` |

- **I2C:** `AppleS5L8940XI2CController`, `atcrt0`, `atcrt1`, `atcrt2`, `i2c1`, `i2c2`, `i2c3`, `i2c4`, `i2c6`, `i2c8`, `pcon0`, `sd-card`
- **PWM:** `AppleS5L8920XFPWM`, `AppleS5L8920XPWM`, `pwm0`, `pwm1`
- **Pin/AON:** `AppleT8101GPIOIC`, `aon-ptd`, `dp2hdmi-gpio0`, `gpio0`, `nub-gpio0`

---

## 19. Telemetry, Logging & IOReporting

Instrumentation and logging endpoints: **`IOReportUserClient`** / `IOReportHub` expose the counters that `powermetrics` and Activity Monitor read; **`CCLogStream`**/`CCPipe`/`CCIOService` are CoreCapture channels (used to capture Wi-Fi/Bluetooth/firmware logs); and **`IOTimeSyncServiceDaemonClient`** handles precision time sync (PTP, used by Thunderbolt and audio). `106` nodes.

**Most common classes**

| Count | Object class |
|---:|:---|
| 50 | `CCIOService` |
| 13 | `IOTimeSyncServiceDaemonClient` |
| 12 | `IOReportUserClient` |
| 5 | `IOTimeSyncClockManagerDaemonClient` |
| 4 | `IOTimeSyncSyncDaemonClient` |
| 2 | `CCLogPipe` |
| 2 | `CCLogStream` |
| 2 | `IOTimeSyncgPTPManagerDaemonClient` |
| 1 | `CCDataPipe` |
| 1 | `AppleSPUTimesyncV2` |
| 1 | `AppleARMIODevice` |
| 1 | `CoreAnalyticsHub` |

- **IOReporting:** `IOReportHub`, `IOReportUserClient`
- **CoreCapture:** `CCDataStream`, `CCFaultReporter`, `CCLogStream`, `CCPipe`
- **Time sync:** `AppleSPUTimesyncV2`, `IOTimeSyncClockManager`, `IOTimeSyncClockManagerDaemonClient`, `IOTimeSyncDaemonService`, `IOTimeSyncDaemonUserClient`, `IOTimeSyncDomain`, `IOTimeSyncDomainDaemonClient`, `IOTimeSyncRootService`, `IOTimeSyncServiceDaemonClient`, `IOTimeSyncSyncDaemonClient`, `IOTimeSyncTimeSyncTimePort`, `IOTimeSyncTranslationMach` _(+3 more)_

---

## 20. User Clients

A **user client** is a per-process bridge object that lets a userspace program talk to a kernel driver. They dominate the raw node count because the registry captures a *live* moment — every running app holds clients to the graphics, surface, keystore, and power subsystems. The headline counts: **170× `RootDomainUserClient`** (power-assertion handles — apps preventing sleep), **140× `IOHIDEventServiceUserClient`**, **133× `IOSurfaceRootUserClient`** (shared graphics buffers), **129× `AppleKeyStoreUserClient`**, **122× `AGXDeviceUserClient`** (Metal). Reading these tells you how busy each subsystem is right now rather than what hardware exists.

**Most common classes**

| Count | Object class |
|---:|:---|
| 170 | `RootDomainUserClient` |
| 133 | `IOSurfaceRootUserClient` |
| 6 | `DIDeviceIOUserClient` |
| 4 | `AppleTrustedAccessoryManagerUserClient` |
| 4 | `IOAccessoryManagerUserClient` |
| 4 | `com_apple_driver_FairPlayIOKitUserClient` |
| 2 | `AppleActuatorDeviceUserClient` |
| 2 | `AppleBiometricServicesUserClient` |
| 2 | `CoreKDLUserClient` |
| 2 | `AppleSSEUserClient` |
| 2 | `AppleImage4UserClient` |
| 2 | `AppleSystemPolicyUserClient` |
| 2 | `AppleLIFSUserClient` |
| 1 | `AppleH13CamInUserClient` |
| 1 | `IOWatchdogUserClient` |
| 1 | `AppleGCResourceDeviceUserClient` |

---

## 21. Other / Miscellaneous

Everything that didn't map cleanly into the categories above — `254` nodes. Worth a scan if you're hunting for something specific; the class table shows what's here.

**Most common classes**

| Count | Object class |
|---:|:---|
| 54 | `AppleARMIODevice` |
| 12 | `AppleSPU` |
| 12 | `IOSurfaceAcceleratorClient` |
| 10 | `IODPPortService` |
| 6 | `AppleTCONComponent` |
| 6 | `AppleConvergedIPCRTIInterface` |
| 6 | `AppleATCDPINAdapterPort` |
| 4 | `AppleT602XATCDPXBAR` |
| 4 | `AppleT8122TypeCPhy` |
| 4 | `AppleHPMDeviceHALType3` |
| 3 | `AIDImageDownloader` |
| 3 | `AppleTypeCRetimer` |
| 3 | `AppleT8122PCIeC` |
| 3 | `ApplePCIeCPIODMA` |
| 3 | `AppleATCDPAltModePort` |
| 3 | `AppleARMNORFlashDevice` |
| 3 | `AppleHPMLDCMType2` |
| 3 | `APCIECMSIController` |

---

## 22. Appendix A — Full object-class frequency table

All distinct object classes in the export, by frequency. This is the authoritative inventory; the categorized sections above are an interpretive overlay on top of it.

| Count | Object class |
|---:|:---|
| 176 | `AppleARMIODevice` |
| 170 | `RootDomainUserClient` |
| 140 | `IOHIDEventServiceUserClient` |
| 133 | `IOSurfaceRootUserClient` |
| 129 | `AppleKeyStoreUserClient` |
| 122 | `IODARTMapperNub` |
| 122 | `IODARTMapper` |
| 122 | `AGXDeviceUserClient` |
| 89 | `RTBuddyEndpointService` |
| 78 | `AppleARMPMUPowerSensor` |
| 77 | `AFKEPInterfaceKextV2` |
| 65 | `DCPEndpointV2` |
| 65 | `AFKEPInterfaceServiceKextV2` |
| 56 | `AudioDMAChannel` |
| 50 | `CCIOService` |
| 44 | `AppleARMPMUTempSensor` |
| 37 | `AppleT8110DART` |
| 37 | `AppleAPFSGraft` |
| 34 | `IOPlatformDevice` |
| 27 | `IOHIDInterface` |
| 21 | `IOThunderboltPort` |
| 20 | `AppleAPFSVolume` |
| 20 | `AppleAPFSVolumeBSDClient` |
| 19 | `IOMediaBSDClient` |
| 18 | `AppleA7IOPNub` |
| 18 | `IOUserUserClient` |
| 18 | `IOMedia` |
| 16 | `RTBuddy` |
| 16 | `RTBuddyService` |
| 15 | `AppleARMSPMIDevice` |
| 14 | `AppleARMCPU` |
| 14 | `AppleHDCPInterface` |
| 13 | `AppleASCWrapV6` |
| 13 | `IOMobileFramebufferUserClient` |
| 13 | `IOTimeSyncServiceDaemonClient` |
| 12 | `AppleARMIICDevice` |
| 12 | `AppleSPU` |
| 12 | `AppleSEPDeviceService` |
| 12 | `IOUSBDeviceInterface` |
| 12 | `IOSurfaceAcceleratorClient` |
| 12 | `IOReportUserClient` |
| 11 | `RTBuddyIOReportingEndpoint` |
| 11 | `IONetworkStack` |
| 11 | `IONetworkStackUserClient` |
| 11 | `IOHIDResourceDeviceUserClient` |
| 11 | `IOHIDUserDevice` |
| 10 | `IODPPortService` |
| 10 | `AppleAPFSContainerScheme` |
| 10 | `AppleAPFSMedia` |
| 10 | `AppleAPFSMediaBSDClient` |
| 10 | `AppleAPFSContainer` |
| 10 | `AppleSPMIController` |
| 10 | `AppleJPEGDriverUserClient` |
| 10 | `AppleCredentialManagerUserClient` |
| 10 | `BootPolicyUserClient` |
| 9 | `IOBlockStorageDriver` |
| 9 | `DCPAVControllerProxy` |
| 9 | `DCPDPControllerProxy` |
| 9 | `AppleDCPDPTXRemoteHDCPInterfaceProxy` |
| 8 | `IOPCIDevice` |
| 8 | `AppleSPUHIDInterface` |
| 8 | `AppleSPUHIDDevice` |
| 8 | `IOGUIDPartitionScheme` |
| 8 | `AppleDCPDPTXRemotePortProxy` |
| 8 | `AppleDCPDPTXRemotePortUFP` |
| 7 | `AppleSPUHIDDriver` |
| 7 | `AppleSMCClient` |
| 7 | `AppleAVDUserClient` |
| 7 | `IOHIDParamUserClient` |
| 6 | `AppleHIDTransportInterface` |
| 6 | `AppleHIDTransportHIDDevice` |
| 6 | `AppleS5L8940XI2CController` |
| 6 | `AppleTCONComponent` |
| 6 | `AppleARMIISDevice` |
| 6 | `IOAudio2DeviceUserClient` |
| 6 | `IOEthernetInterface` |
| 6 | `AppleThunderboltDPInAdapterOS` |
| 6 | `AppleConvergedIPCRTIInterface` |
| 6 | `AppleATCDPINAdapterPort` |
| 6 | `AppleUSBDeviceNCMControl` |
| 6 | `AppleUSBDeviceNCMData` |
| 6 | `AppleDiskImageDevice` |
| 6 | `DIDeviceIOUserClient` |
| 5 | `AppleUserHIDEventService` |
| 5 | `IOUserService` |
| 5 | `AppleConvergedIPCSkywalkInterface` |
| 5 | `IOSkywalkKernelPipeBSDClient` |
| 5 | `AppleAOPAudioDeviceNode` |
| 5 | `AppleSMCInterface` |
| 5 | `IOMobileFramebufferShim` |
| 5 | `AppleDCPExpert` |
| 5 | `AFKLocalMemoryDescriptorManager` |
| 5 | `AppleDCPLinkServiceSoC` |
| 5 | `DCPAVAudioDMADelegate` |
| 5 | `H1xANELoadBalancerDirectPathClient` |
| 5 | `IOTimeSyncClockManagerDaemonClient` |
| 4 | `IOUserNetworkWLAN` |
| 4 | `IOSkywalkNetworkBSDClient` |
| 4 | `AppleT602XATCDPXBAR` |
| 4 | `AppleT8101GPIOIC` |
| 4 | `AppleSPUAppInterface` |
| 4 | `IOHIDLibUserClient` |
| 4 | `AppleCLPCUserClient` |
| 4 | `AppleTrustedAccessoryManagerUserClient` |
| 4 | `AppleSMCChargerUtil` |
| 4 | `AppleT8122TypeCPhy` |
| 4 | `AppleHPMARMSPMI` |
| 4 | `AppleHPMDeviceHALType3` |
| 4 | `IOPortTransportStateCC` |
| 4 | `IOPortFeaturePowerIn` |
| 4 | `IOAccessoryManagerUserClient` |
| 4 | `AppleHPMUserClient` |
| 4 | `AppleMCA2Controller_T603x` |
| 4 | `com_apple_driver_FairPlayIOKitUserClient` |
| 4 | `IOServiceCompatibility` |
| 4 | `IOTimeSyncSyncDaemonClient` |
| 4 | `IOUserServer` |
| 3 | `AIDImageDownloader` |
| 3 | `RTBuddyTraceKitEndpoint` |
| 3 | `AppleTypeCRetimer` |
| 3 | `AppleT8122PCIeC` |
| 3 | `ApplePCIECHostBridge` |
| 3 | `ApplePCIeCPIODMA` |
| 3 | `AppleThunderboltHALType5` |
| 3 | `AppleThunderboltNHIType5` |
| 3 | `IOThunderboltControllerType5` |
| 3 | `IOThunderboltLocalNode` |
| 3 | `IOThunderboltXDomainServiceClientManager` |
| 3 | `AppleThunderboltIPService` |
| 3 | `AppleThunderboltIPPort` |
| 3 | `IOThunderboltSwitchType5` |
| 3 | `AppleThunderboltPCIDownAdapterType5` |
| 3 | `AppleThunderboltUSBDownAdapter` |
| 3 | `AppleThunderboltDPConnectionManager` |
| 3 | `IOTBTTunnelClientInterfaceManager` |
| 3 | `AppleMxWrapACIO` |
| 3 | `AppleATCDPAltModePort` |
| 3 | `ApplePMGRNub` |
| 3 | `AppleARMNORFlashDevice` |
| 3 | `AppleT8122USBXHCI` |
| 3 | `AppleUSB20XHCIARMPort` |
| 3 | `AppleUSB30XHCIARMPort` |
| 3 | `AppleT8122USBXDCI` |
| 3 | `IOUSBDeviceConfigurator` |
| 3 | `AppleUSBDeviceNCMPrivateEthernetInterface` |
| 3 | `AppleHPMInterfaceType10` |
| 3 | `AppleHPMLDCMType2` |
| 3 | `IOPortFeatureLDCMUserClient` |
| 3 | `AppleMCA2Cluster_T603x` |
| 3 | `APCIECMSIController` |
| 3 | `ApplePCIECLegacyIntController` |
| 3 | `EndpointSecurityExternalClient` |
| 2 | `IODTNVRAMVariables` |
| 2 | `AppleMultitouchTrackpadHIDEventDriver` |
| 2 | `AppleMultitouchDevice` |
| 2 | `AppleMultitouchDeviceUserClient` |
| 2 | `AppleDeviceManagementHIDEventService` |
| 2 | `AppleActuatorHIDEventDriver` |
| 2 | `AppleActuatorDevice` |
| 2 | `AppleActuatorDeviceUserClient` |
| 2 | `AppleSPIMCController` |
| 2 | `AppleARMSPIDevice` |
| 2 | `AppleMesaSEPDriver` |
| 2 | `AppleBiometricServices` |
| 2 | `AppleBiometricServicesUserClient` |
| 2 | `AppleLEAPController_T603x` |
| 2 | `AppleExternalSecondaryAudio` |
| 2 | `AudioDMAController` |
| 2 | `ApplePCIEHostBridge` |
| 2 | `AppleT6020PCIePIODMA` |
| 2 | `CCLogPipe` |
| 2 | `CCLogStream` |
| 2 | `AppleSPUHIDDriverUserClient` |
| 2 | `AppleAOPAudioClientManager` |
| 2 | `AppleSEPXARTService` |
| 2 | `CoreKDLUserClient` |
| 2 | `AppleSSEUserClient` |
| 2 | `IOSerialBSDClient` |
| 2 | `AppleDialogSPMIPMU` |
| 2 | `AppleM2ScalerCSCDriver` |
| 2 | `AppleProResHW` |
| 2 | `AppleJPEGDriver` |
| 2 | `AppleAVE2Driver` |
| 2 | `AppleEmbeddedAudioDevice` |
| 2 | `AppleSecondaryAudio` |
| 2 | `AppleImage4UserClient` |
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
| 1 | `AppleMultiFunctionManager` |
| 1 | `AppleH15IO` |
| 1 | `AppleDockChannel` |
| 1 | `AppleDockChannelDevice` |
| 1 | `AppleHIDTransportHibernator` |
| 1 | `AppleHIDTransportDeviceFIFO` |
| 1 | `AppleHIDTransportBootloaderRTBuddy` |
| 1 | `AppleHIDTransportProtocolSCMFIFO` |
| 1 | `AppleHIDTransportManagement` |
| 1 | `AppleHIDTransportBootloaderCBOR` |
| 1 | `AppleHIDTransportBootloaderHIDDevice` |
| 1 | `AppleHIDKeyboardEventDriverV2` |
| 1 | `AppleSN012776Amp` |
| 1 | `AppleCS42L84Audio` |
| 1 | `AppleCS42L84Mikey` |
| 1 | `AppleSandDollar` |
| 1 | `AppleMesaShim` |
| 1 | `AppleParadeDP855TCON` |
| 1 | `AppleH13CamIn` |
| 1 | `AppleH13CamInUserClient` |
| 1 | `AppleS5L8920XFPWM` |
| 1 | `AppleARMPWMDevice` |
| 1 | `AppleT6031PCIe` |
| 1 | `IOSkywalkLegacyEthernet` |
| 1 | `IOSkywalkLegacyEthernetInterface` |
| 1 | `AppleConvergedPCI` |
| 1 | `AppleSDXC` |
| 1 | `AppleSDXCSlot` |
| 1 | `IOPortTransportStateSD` |
| 1 | `AppleSDXCBlockStorageDevice` |
| 1 | `AppleOLYHAL` |
| 1 | `AppleBluetoothModule` |
| 1 | `BTDebug` |
| 1 | `CCDataPipe` |
| 1 | `CCDataStream` |
| 1 | `AppleConvergedIPCOLYBTControl` |
| 1 | `AppleConvergedIPCOLYBTCoreDumpProvider` |
| 1 | `AppleConvergedIPCRTIDevice` |
| 1 | `AppleConvergedIPCOLYBTLogProvider` |
| 1 | `AppleT603XDisplayCrossbar` |
| 1 | `AppleDisplayConnectionManager` |
| 1 | `AppleATCDPHDMIPort` |
| 1 | `AppleHDMIPortController` |
| 1 | `IOPortTransportStateDisplayPort` |
| 1 | `AppleH15MemCacheController` |
| 1 | `AppleInterruptControllerV3` |
| 1 | `AppleARMWatchdogTimer` |
| 1 | `IOWatchdogUserClient` |
| 1 | `AppleH15PlatformErrorHandler` |
| 1 | `AppleS8000DWI` |
| 1 | `AppleS8000AESAccelerator` |
| 1 | `AppleSPUTimesyncV2` |
| 1 | `AppleSPUFirmwareService` |
| 1 | `AppleSPUAppDriver` |
| 1 | `AppleSPUProfileDriver` |
| 1 | `AppleSPUHIDDeviceUserClient` |
| 1 | `AppleAOPAudioController` |
| 1 | `AppleAOPAudioPDM2Device` |
| 1 | `AppleAOPAudioLPMicInDevice` |
| 1 | `AppleAOPAudioUserClient` |
| 1 | `AppleAOPAudioService` |
| 1 | `AppleAOPVoiceTriggerController` |
| 1 | `AppleAOPVoiceTriggerUserClient` |
| 1 | `AppleSPUVD6286` |
| 1 | `AppleT6031PMGR` |
| 1 | `AppleT6031SOCTuner` |
| 1 | `AppleCLPC` |
| 1 | `ApplePassthroughPPM` |
| 1 | `AppleEventLogHandler` |
| 1 | `AppleS5L8960XNCO` |
| 1 | `AppleSmartIO` |
| 1 | `AppleSmartIODMANub` |
| 1 | `AppleSmartIODMAController` |
| 1 | `ApplePMPFirmware` |
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
| 1 | `AppleDialogSPMIPMURTC` |
| 1 | `AppleBTM` |
| 1 | `AppleHPMInterfaceType11` |
| 1 | `AppleStockholmSPMI` |
| 1 | `AppleStockholmControlConfig` |
| 1 | `AppleStockholmControl` |
| 1 | `AFKFirmwareService` |
| 1 | `AFKEndpointInterfaceUserClient` |
| 1 | `DCPAVPowerControllerProxy` |
| 1 | `DCPAVRemoteSACControllerProxy` |
| 1 | `DCPAVDeviceProxy` |
| 1 | `DCPDPDeviceProxy` |
| 1 | `DCPAVServiceProxy` |
| 1 | `DCPDPServiceProxy` |
| 1 | `DCPAVVideoInterfaceProxy` |
| 1 | `DCPAVSACController` |
| 1 | `AppleAVD` |
| 1 | `H11ANEIn` |
| 1 | `ANEClientHints` |
| 1 | `AGXAcceleratorG15X` |
| 1 | `AGXFirmwareKextG15RTBuddy` |
| 1 | `AGXArmFirmwareMapper` |
| 1 | `AppleMCA2Switch` |
| 1 | `AppleSMCSensorDispatcher` |
| 1 | `AppleSMCSensorDispatcherUserClient` |
| 1 | `AppleARMLightEmUp` |
| 1 | `AppleS5L8920XPWM` |
| 1 | `AppleM68Buttons` |
| 1 | `AppleARMBacklight` |
| 1 | `AppleSDXCSDDetect` |
| 1 | `AppleARMSlowAdaptiveClockingManager` |
| 1 | `AppleImage4` |
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
| 1 | `AppleT6031ANEHAL` |
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
| 1 | `KDIURL` |
| 1 | `KDIFileBackingStore` |
| 1 | `KDIUDIFEncoding` |
| 1 | `KDIUDIFDiskImage` |
| 1 | `KDIDiskImageNub` |
| 1 | `IOHDIXHDDriveInKernel` |
| 1 | `IODiskImageBlockStorageDeviceInKernel` |
| 1 | `IOKitRegistryCompatibility` |
| 1 | `IOReportHub` |
| 1 | `AppleUSBHostResourcesTypeC` |
| 1 | `AppleUSBUserHCIResources` |
| 1 | `IOUSBMassStorageResource` |
| 1 | `IOUserEthernetResource` |
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

_Generated from `ioservice.json` — 2,993 registry nodes across 419 object classes._