# 🕹️ Mutable SteamOS Installer

![Platform](https://img.shields.io/badge/platform-SteamDeck%20%7C%20OneXPlayer-blue)
![Status](https://img.shields.io/badge/status-beta-yellow)

This project provides an **Arch-style mutable installation of SteamOS**, originally designed for the OneXPlayer 2 and now adapted for the Steam Deck.  

It installs SteamOS from Valve’s official repositories for a **fully mutable system**, giving you more control and flexibility than the default immutable installation.  

> ⚠️ **Warning:** This is not an official Valve installer. Use at your own risk. Intended mostly for enthusiasts who want a mutable setup.

---

## 🚀 Quick Start

1. **Prepare two drives:**
   - Drive 1: Arch Linux ISO (bootable)  
   - Drive 2: Contains the installer script (`install-steamos.sh`)  

   Optional: A USB hub with Ethernet for downloading the script directly.

2. **Boot Arch Linux ISO** on your target device.

3. **Mount the second drive** somewhere convenient:

   ```bash
   mount /dev/sdX1 /mnt
   cd /mnt
Run the installer script:

./install-steamos.sh
Follow the prompts:

Connect to Wi-Fi

Choose username (deck recommended for Decky Loader)

Select target drive (e.g., nvme0n1 for internal storage)

⚙️ Supported Versions
SteamOS 3.6

SteamOS 3.7

Support for 3.8 will be added once it becomes official.

🔄 Updating Your Installation
After installation, update packages to the latest in the current release branch:

sudo pacman -Syu
This will keep your installation current until the repos are frozen for the next version.

Note: This script does not upgrade between 3.x versions.

📝 Why Use This?
Full control over your SteamOS installation

Mutable system for tweaks, scripts, and customizations

Currently only test on an official Steam Deck

⚡ Author Notes
I created this mainly for myself — but if you enjoy tinkering with SteamOS, this might save you some time.
Mutable installs are fun. 😎

