# Installing or Upgrading the OneDrive Client for Linux

## Table of Contents

## Overview
This page details the recommended installation methods for the OneDrive Client for Linux for most Linux distributions and FreeBSD.


## Recommended Installation Method (Using Pre-Built Packages)

### Important Notice for all Debian | Ubuntu | Linux Mint | Pop!_OS | Raspbian | Zorin Users

> [!IMPORTANT]
> **Do NOT install the OneDrive client from your distribution’s default repositories.** These packaged versions are **outdated, unsupported, and contain known defects.**
>
> Instead, install the **fully supported and actively maintained version** from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md)


### Which Installation Method Should I Use?

| Distribution & Version                 | Distribution Package Name & Link                                                                         | Distribution Package Version | Correct Installation Method |
|----------------------------------------|----------------------------------------------------------------------------------------------------------|:----------------------------------------------------:|-----------------------------|
| Alpine Linux                           | [onedrive](https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge)                              |<a href="https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge"><img src="https://repology.org/badge/version-for-repo/alpine_edge/onedrive.svg?header=" alt="Alpine Linux Edge package" width="46" height="20"></a> | Alpine **Stable** may ship older versions. If your version is outdated, you need to build from source |
| Arch Linux<br><br>Manjaro Linux        | [onedrive-abraunegg](https://aur.archlinux.org/packages/onedrive-abraunegg/)                             |<a href="https://aur.archlinux.org/packages/onedrive-abraunegg"><img src="https://repology.org/badge/version-for-repo/aur/onedrive-abraunegg.svg?header=" alt="AUR package" width="46" height="20"></a>| Install via: `pamac build onedrive-abraunegg` from the Arch Linux User Repository (AUR)<br><br>**Note:** You must first install 'base-devel' as this is a pre-requisite for using the AUR<br><br>**Note:** If asked regarding a provider for 'd-runtime' and 'd-compiler', select 'liblphobos' and 'ldc'<br><br>**Note:** System must have at least 1GB of memory & 1GB swap space<br><br>AUR package `onedrive-abraunegg` follows the release versions<br>AUR package `onedrive-abraunegg-git` follows the 'master' branch |
| CentOS Stream 8                        | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_8/onedrive.svg?header=" alt="CentOS 8 package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| CentOS Stream 9                        | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_9/onedrive.svg?header=" alt="CentOS 9 package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| CentOS Stream 10                       | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_10/onedrive.svg?header=" alt="CentOS 10 package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| Debian 11                              | [onedrive](https://packages.debian.org/bullseye/source/onedrive)                                         |<a href="https://packages.debian.org/bullseye/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_11/onedrive.svg?header=" alt="Debian 11 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Debian 12                              | [onedrive](https://packages.debian.org/bookworm/source/onedrive)                                         |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_12/onedrive.svg?header=" alt="Debian 12 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Debian 13                              | [onedrive](https://packages.debian.org/trixie/source/onedrive)                                           |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_13/onedrive.svg?header=" alt="Debian 13 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Debian Sid                             | [onedrive](https://packages.debian.org/sid/onedrive)                                                     |<a href="https://packages.debian.org/sid/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_unstable/onedrive.svg?header=" alt="Debian Sid package" width="46" height="20"></a>| Install via: `sudo apt install --no-install-recommends --no-install-suggests onedrive` |
| Fedora                                 | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/fedora_rawhide/onedrive.svg?header=" alt="Fedora Rawhide package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| FreeBSD                                | [onedrive](https://www.freshports.org/net/onedrive)                                                      |<a href="https://www.freshports.org/net/onedrive"><img src="https://repology.org/badge/version-for-repo/freebsd/onedrive.svg?header=" alt="FreeBSD package" width="46" height="20"></a>| Install via: `pkg install onedrive` |
| Gentoo                                 | [onedrive](https://packages.gentoo.org/packages/net-misc/onedrive)                                       |<a href="https://packages.gentoo.org/packages/net-misc/onedrive"><img src="https://repology.org/badge/version-for-repo/gentoo/onedrive.svg?header=" alt="Gentoo package" width="46" height="20"></a>| Install via: `sudo emerge net-misc/onedrive` |
| Homebrew                               | [onedrive-cli](https://formulae.brew.sh/formula/onedrive-cli)                                            |<a href="https://formulae.brew.sh/formula/onedrive-cli"><img src="https://repology.org/badge/version-for-repo/homebrew/onedrive-cli.svg?header=" alt="Homebrew package" width="46" height="20"></a> | Install via: `brew install onedrive-cli` |
| Linux Mint 20.x                        | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Linux Mint 21.x                        | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Linux Mint 22.x                        | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Linux Mint Debian Edition 6            | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_12/onedrive.svg?header=" alt="Debian 12 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Linux Mint Debian Edition 7            | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_13/onedrive.svg?header=" alt="Debian 13 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| NixOS                                  | [onedrive](https://search.nixos.org/packages?channel=25.05&query=onedrive)                               |<a href="https://search.nixos.org/packages?channel=25.05&query=onedrive"><img src="https://repology.org/badge/version-for-repo/nix_unstable/onedrive.svg?header=" alt="nixpkgs unstable package" width="46" height="20"></a>| Install via: `nix-env -iA nixpkgs.onedrive` **or** `services.onedrive.enable = true` in `configuration.nix` |
| OpenSUSE                               | [onedrive](https://software.opensuse.org/package/onedrive)                                               |<a href="https://software.opensuse.org/package/onedrive"><img src="https://repology.org/badge/version-for-repo/opensuse_network_tumbleweed/onedrive.svg?header=" alt="openSUSE Tumbleweed package" width="46" height="20"></a>| Install via: `sudo zypper install onedrive` |
| Raspbian                               | [onedrive](https://archive.raspbian.org/raspbian/pool/main/o/onedrive/)                                  |<a href="https://archive.raspbian.org/raspbian/pool/main/o/onedrive/"><img src="https://repology.org/badge/version-for-repo/raspbian_stable/onedrive.svg?header=" alt="Raspbian Stable package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Slackware                              | [onedrive](https://slackbuilds.org/result/?search=onedrive&sv=)                                          |<a href="https://slackbuilds.org/result/?search=onedrive&sv="><img src="https://repology.org/badge/version-for-repo/slackbuilds/onedrive.svg?header=" alt="SlackBuilds package" width="46" height="20"></a>| Install via SlackBuilds: https://slackbuilds.org/result/?search=onedrive |
| Solus                                  | [onedrive](https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc)                          |<a href="https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc"><img src="https://repology.org/badge/version-for-repo/solus/onedrive.svg?header=" alt="Solus package" width="46" height="20"></a>| Install via: `sudo eopkg install onedrive` |
| Ubuntu 22.04 LTS                       | [onedrive](https://packages.ubuntu.com/jammy/onedrive)                                                   |<a href="https://packages.ubuntu.com/jammy/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Ubuntu 24.04 LTS                       | [onedrive](https://packages.ubuntu.com/noble/onedrive)                                                   |<a href="https://packages.ubuntu.com/noble/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |


> [!IMPORTANT]
> Distribution versions that are considered **End-of-Life (EOL)** are **no longer supported** or tested with current client releases.


## When Should You Build From Source?
You should only build from source in the following circumstances:

1. You are packaging for a custom or minimal distro
2. Your distribution does not have a package for your to install. Refer to [repology](https://repology.org/project/onedrive/versions) as a source of all 'onedrive' client versions available across tracked distributions
3. You require code newer than the latest release or are building a Pull Request to validate a bugfix

Outside of these 3 reasons, you should not be building the client yourself. You should endeavour where possible to use a pre-built package.

> [!IMPORTANT]
> If your distribution does not currently offer a packaged version of the client, you should **request that your distribution maintainers package and support it** as part of their official repositories.


## Building from Source
1. Ensure your system meets the minimum build requirements
2. Install Build Dependencies including the relevant compiler
3. Clone, configure, build, install

### Minimum Build Requirements
*   For successful compilation of this application, it's crucial that the build environment is equipped with a minimum of 1GB of memory and an additional 1GB of swap space.
*   Install the required distribution package dependencies covering the required development tools and development libraries for curl and sqlite
*   Install the [Digital Mars D Compiler (DMD)](https://dlang.org/download.html), [LDC – the LLVM-based D Compiler](https://github.com/ldc-developers/ldc), or, at least version 15 of the [GNU D Compiler (GDC)](https://www.gdcproject.org/)

> [!IMPORTANT]
> To compile this application successfully, the minimum supported versions of each compiler are: DMD **2.091.1**, LDC **1.20.1**, and, GDC **15**. Ensuring compatibility and optimal performance necessitates the use of these specific versions or their more recent updates.
>
> You only need 1 compiler installed. You do not need to install DMD, LDC and GDC. Please *pick* the most applicable compiler for your distribution.

#### Installing DMD Compiler
To install the DMD Compiler, this can be achieved in the following manner:
```text
curl -fsS https://dlang.org/install.sh | bash -s dmd
```

#### Installing LDC Compiler
To install the LDC Compiler, this can be achieved in the following manner:
```text
curl -fsS https://dlang.org/install.sh | bash -s ldc
```

#### Installing GDC Compiler
You will need at least GDC version 15. If your distribution's repositories include a suitable version, you can install it from there. Common names for the GDC package are listed on the [GDC website](https://www.gdcproject.org/downloads#linux-distribution-packages). If the package is unavailable or its version is too old, you can try building it from source following [these instructions](https://wiki.dlang.org/GDC/Installation).


### Install Build Dependencies (By Distribution)

#### Arch Linux | Manjaro Linux
```text
sudo pacman -S git make pkg-config curl sqlite dbus ldc
```
For GUI notifications the following is also necessary:
```text
sudo pacman -S libnotify
```

#### CentOS 6.x | RHEL 6.x
CentOS 6.x and RHEL 6.x reached End of Life status on November 30th 2020 and is no longer supported or tested against.

#### CentOS 7.x | RHEL 7.x
CentOS 7.x and RHEL 7.x reached End of Life status on June 30th 2024 and is no longer supported or tested against.

#### CentOS Stream 8 | CentOS Stream 9
```text
sudo dnf groupinstall 'Development Tools'
sudo dnf install libcurl-devel sqlite-devel dbus-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For GUI notifications the following is also necessary:
```text
sudo dnf install libnotify-devel
```

#### CentOS Stream 10
 - detail packages

#### Debian 9
Debian 9 reached the end of its five-year LTS window on July 18th 2020 and is no longer supported or tested against.

#### Debian 10
Debian 10 reached the end of its five-year LTS window on September 10th 2022 and is no longer supported or tested against.

#### Debian 11 | Debian 12 | Debian 13 | Linux Mint Debian Edition 6 | Linux Mint Debian Edition 7 - x86_64
 ```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev libsqlite3-dev pkg-config git curl systemd-dev libdbus-1-dev
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For GUI notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

#### Debian 11 | Debian 12 | Debian 13 - ARMHF and ARM64
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev libsqlite3-dev pkg-config git curl ldc systemd-dev libdbus-1-dev
```
For GUI notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

#### Fedora
> [!NOTE]
> Fedora 41 and above uses **dnf5** which removes some deprecated aliases, specifically 'groupinstall' in this instance.

```text
sudo dnf group install development-tools
sudo dnf install libcurl-devel sqlite-devel dbus-devel
```
Before running the dmd install you need to check for the option 'use-keyboxd' in your gnupg common.conf file and comment it out while running the install.
```text
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
Or you may get the following error:
```text
myuser@fedora:~$ curl -fsS https://dlang.org/install.sh | bash -s dmd
Downloading https://dlang.org/d-keyring.gpg
######################################################################## 100.0%
gpg: Note: Specified keyrings are ignored due to option "use-keyboxd"
gpg: Signature made Thu 06 Mar 2025 10:45:29 GMT
gpg:                using RSA key F3F896F3274BBD9BBBA59058710592E7FB7AF6CA
gpg: Can't check signature: No public key
Invalid signature https://dlang.org/d-keyring.gpg.sig
```
For GUI notifications the following is also necessary:
```text
sudo dnf install libnotify-devel
```

#### FreeBSD
> [!NOTE]
> Install the required FreeBSD packages as 'root' unless you have installed 'sudo'

```text
pkg install bash bash-completion gmake pkgconf autoconf automake logrotate libinotify git sqlite3 ldc
```
For GUI notifications the following is also necessary:
```text
pkg install libnotify
```

#### Gentoo
```text
sudo emerge --onlydeps net-misc/onedrive
```

#### OpenSUSE Leap
```text
sudo zypper refresh
sudo zypper install gcc git libcurl-devel sqlite3-devel dmd phobos-devel phobos-devel-static dbus-1-devel
```
For GUI notifications the following is also necessary:
```text
sudo zypper install libnotify-devel
```

#### OpenSUSE Tumbleweed
- detail packages

#### Raspbian - ARMHF and ARM64
> [!CAUTION]
> The minimum LDC compiler version required to compile this application is 1.20.1, which is not available for Debian Buster or distributions based on Debian Buster. You are advised to first upgrade your platform distribution to one that is based on Debian Bullseye (Debian 11) or later.

> [!NOTE]
> These dependencies were validated using:
> *   `Linux raspberrypi 5.10.92-v8+ #1514 SMP PREEMPT Mon Jan 17 17:39:38 GMT 2022 aarch64` (2022-01-28-raspios-bullseye-armhf-lite) using Raspberry Pi 3B (revision 1.2)
> *   `Linux raspberrypi 5.10.92-v8+ #1514 SMP PREEMPT Mon Jan 17 17:39:38 GMT 2022 aarch64` (2022-01-28-raspios-bullseye-arm64-lite) using Raspberry Pi 3B (revision 1.2)
> *   `Linux ubuntu 5.15.0-1005-raspi #5-Ubuntu SMP PREEMPT Mon Apr 4 12:21:48 UTC 2022 aarch64 aarch64 aarch64 GNU/Linux` (ubuntu-22.04-preinstalled-server-arm64+raspi) using Raspberry Pi 3B (revision 1.2)

```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev libsqlite3-dev pkg-config git curl ldc systemd-dev libdbus-1-dev
```
For GUI notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

#### Ubuntu 16.x
Ubuntu 16.x LTS reached the end of its five-year LTS window on April 30th 2021 and is no longer supported or tested against.

#### Ubuntu 18.x 
Ubuntu 18.x LTS reached the end of its five-year LTS window on May 31th 2023 and is no longer supported or tested against.

#### Ubuntu 20.x
Ubuntu 20.x LTS reached the end of its five-year LTS window on May 31th 2025 and is no longer supported or tested against.

#### Ubuntu 22.x | Ubuntu 24.x
> [!NOTE]
> These dependency requirements also apply to any distribution derived from Ubuntu, including but not limited to:
> *   Lubuntu
> *   Linux Mint
> *   Pop!_OS
> *   Peppermint OS
> *   Zorin OS

```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev libsqlite3-dev pkg-config git curl systemd-dev libdbus-1-dev
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For GUI notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

### Clone, Configure, Build, Install

#### Using defaults

#### Using optional features
--enable-notifications
--enable-debug
--enable-completions
Systemd override installation paths

#### Building on ARM | Raspberry Pi


#### Building on FreeBSD


## Upgrading the Client


## Uninstalling the client




