# BusKit

<p align="center">
  <img src="https://raw.githubusercontent.com/pka-fr/BusKit/main/Assets/buskit-logo-small.png" width="150" alt="BusKit Logo">
  <br/>
  <strong>A native macOS client for Azure Service Bus</strong>
  <br/><br/>
  <img src="https://img.shields.io/badge/platform-macOS-blue?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/macOS-13.0+-blue" alt="macOS">
  <img src="https://img.shields.io/github/v/release/pka-fr/BusKit?include_prereleases" alt="Release">
  <img src="https://img.shields.io/github/license/pka-fr/BusKit?cache_bust=1" alt="License">
  <img src="https://img.shields.io/github/stars/pka-fr/BusKit?style=social" alt="Stars">
</p>

---

## 💡 Motivation

If you've ever worked with Azure Service Bus on a Mac, you've probably felt it —
the gap left by the absence of a true macOS-native client.

[**Azure Service Bus Explorer**](https://github.com/paolosalvatori/ServiceBusExplorer)
is a fantastic tool, but it's Windows-only. Mac users are often left with workarounds:
running VMs, using the Azure Portal, or relying on cross-platform tools that feel
out of place on macOS.

**BusKit was born out of that frustration.**

The goal is simple: bring a first-class Azure Service Bus experience to macOS —
one that doesn't just *run* on a Mac, but *belongs* on a Mac. BusKit is built from
the ground up following **Apple's Human Interface Guidelines**, embracing native
macOS conventions, controls, and design patterns that macOS users expect and love.

No Electron. No ports. No compromises. Just a tool that feels right at home on your Mac. 🍎

## 🏗️ Architecture

BusKit is built on a **Sidecar pattern** — the backend and UI run as separate processes
communicating via **gRPC**:

- **Backend — C#/.NET** — a sidecar process leveraging the official
  [Azure SDK for .NET](https://github.com/Azure/azure-sdk-for-net) for all
  Azure Service Bus operations
- **UI — Swift/SwiftUI** — native macOS front-end that communicates with the
  sidecar via gRPC, following Apple's Human Interface Guidelines

This architecture ensures a **clean separation of concerns** — the Swift layer
focuses purely on the macOS experience, while the C# sidecar handles all
Azure communication.

> 🤖 Development was assisted by AI tools.

## 📦 Installation

Download the latest `.dmg` or `.zip` from the [Releases](https://github.com/pka-fr/BusKit/releases) page, then drag **BusKit.app** to your `/Applications` folder.

### macOS: opening an unsigned app

BusKit is not yet notarized by Apple, so macOS will block the first launch. Use one of the following methods to allow it:

**Option A — Right-click to open (recommended)**

1. In Finder, right-click (or Control-click) **BusKit.app**.
2. Choose **Open** from the context menu.
3. In the dialog that appears, click **Open** again to confirm.

You only need to do this once — subsequent launches work normally.

**Option B — System Settings**

1. Try to open the app normally; macOS will show a security warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the **Security** section and click **Open Anyway** next to the BusKit entry.
4. Authenticate with Touch ID or your password when prompted.

**Option C — Remove quarantine via Terminal**

```bash
xattr -d -r com.apple.quarantine /Applications/BusKit.app
```

> ⚠️ Make sure the path matches where you placed the app. Only run this on files you trust.

> **Note:** do *not* disable Gatekeeper globally (`spctl --master-disable`); the per-app steps above are the safe approach.

### Long-term: code signing & notarization

Code signing and notarization through Apple's Developer Program are the recommended permanent solution and are planned for a future release. Signed builds will launch without any additional steps.
