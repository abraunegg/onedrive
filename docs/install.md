# Installing or Upgrading the OneDrive Client for Linux

## Table of Contents

- [Recommended Installation Method (Using Pre-Built Packages)](#recommended-installation-method-using-pre-built-packages)
  - [Important Notice for all Debian \| Ubuntu \| Linux Mint \| Pop!_OS \| Raspbian \| Zorin Users](#important-notice-for-all-debian--ubuntu--linux-mint--pop_os--raspbian--zorin-users)
  - [Which Installation Method Should I Use?](#which-installation-method-should-i-use)
  - [When Should You Build From Source?](#when-should-you-build-from-source)

- [Building from Source](#building-from-source)
  - [Minimum Build Requirements](#minimum-build-requirements)
  - [Install Build Dependencies (By Distribution)](#install-build-dependencies-by-distribution)

- [Clone, Configure, Build, Install](#clone-configure-build-install)
  - [High Level Steps to building the OneDrive Client for Linux](#high-level-steps-to-building-the-onedrive-client-for-linux)
  - [Building the Application Using Default configure Settings](#building-the-application-using-default-configure-settings)
  - [Build Options for Customising the Application](#build-options-for-customising-the-application)

- [Upgrading the Client](#upgrading-the-client)
  - [If installed from a distribution package](#if-installed-from-a-distribution-package)
  - [If installed from source](#if-installed-from-source)

- [Uninstalling the client](#uninstalling-the-client)
  - [If installed from a distribution package](#if-installed-from-a-distribution-package-1)
  - [If installed from source](#if-installed-from-source-1)


## Overview
This document explains how to install or upgrade the OneDrive Client for Linux.

The preferred installation method is to use pre-built distribution packages wherever they are available and current. On some distributions, particularly Debian, Ubuntu, Linux Mint, and Raspberry Pi OS, the versions provided in the default distribution repositories are outdated and unsupported. These must not be used.

If your distribution provides a current maintained package, you should install the client from your package manager. If your distribution does not provide a supported package, or you need to build the client for a custom or minimal environment, building from source is supported and documented below.

Before continuing, identify your Linux distribution and follow the installation path appropriate to your system.

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
| CentOS Stream 8                        | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_8/onedrive.svg?header=" alt="EPEL 8 package" width="46" height="20"></a>| **Note:** You must install and enable the EPEL Repository first.<br><br>Install via: `sudo dnf install onedrive` |
| CentOS Stream 9                        | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_9/onedrive.svg?header=" alt="EPEL 9 package" width="46" height="20"></a>| **Note:** You must install and enable the EPEL Repository first.<br><br>Install via: `sudo dnf install onedrive` |
| CentOS Stream 10                       | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_10/onedrive.svg?header=" alt="EPEL 10 package" width="46" height="20"></a>| **Note:** You must install and enable the EPEL Repository first.<br><br>Install via: `sudo dnf install onedrive` |
| Debian 11                              | [onedrive](https://packages.debian.org/bullseye/source/onedrive)                                         |<a href="https://packages.debian.org/bullseye/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_11/onedrive.svg?header=" alt="Debian 11 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Debian 12                              | [onedrive](https://packages.debian.org/bookworm/source/onedrive)                                         |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_12/onedrive.svg?header=" alt="Debian 12 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Debian 13                              | [onedrive](https://packages.debian.org/trixie/source/onedrive)                                           |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_13/onedrive.svg?header=" alt="Debian 13 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Debian Sid                             | [onedrive](https://packages.debian.org/sid/onedrive)                                                     |<a href="https://packages.debian.org/sid/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_unstable/onedrive.svg?header=" alt="Debian Sid package" width="46" height="20"></a>| Install via: `sudo apt install --no-install-recommends --no-install-suggests onedrive` |
| Fedora                                 | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/fedora_rawhide/onedrive.svg?header=" alt="Fedora Rawhide package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| FreeBSD                                | [onedrive](https://www.freshports.org/net/onedrive)                                                      |<a href="https://www.freshports.org/net/onedrive"><img src="https://repology.org/badge/version-for-repo/freebsd/onedrive.svg?header=" alt="FreeBSD package" width="46" height="20"></a>| Install via: `pkg install onedrive` |
| Gentoo                                 | [onedrive](https://packages.gentoo.org/packages/net-misc/onedrive)                                       |<a href="https://packages.gentoo.org/packages/net-misc/onedrive"><img src="https://repology.org/badge/version-for-repo/gentoo/onedrive.svg?header=" alt="Gentoo package" width="46" height="20"></a>| Install via: `sudo emerge net-misc/onedrive` |
| Homebrew                               | [onedrive-cli](https://formulae.brew.sh/formula/onedrive-cli)                                            |<a href="https://formulae.brew.sh/formula/onedrive-cli"><img src="https://repology.org/badge/version-for-repo/homebrew/onedrive-cli.svg?header=" alt="Homebrew package" width="46" height="20"></a> | Install via: `brew install onedrive-cli` |
| Linux Mint 21.x                        | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Linux Mint 22.x                        | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Linux Mint Debian Edition 6            | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_12/onedrive.svg?header=" alt="Debian 12 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Linux Mint Debian Edition 7            | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_13/onedrive.svg?header=" alt="Debian 13 package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| NixOS                                  | [onedrive](https://search.nixos.org/packages?channel=25.05&query=onedrive)                               |<a href="https://search.nixos.org/packages?channel=25.05&query=onedrive"><img src="https://repology.org/badge/version-for-repo/nix_unstable/onedrive.svg?header=" alt="nixpkgs unstable package" width="46" height="20"></a>| Install via: `nix-env -iA nixpkgs.onedrive` **or** `services.onedrive.enable = true` in `configuration.nix` |
| MX Linux 25                            | [onedrive](https://mxrepo.com/mx/repo/pool/main/o/onedrive/)                                             |<a href="https://mxrepo.com/mx/repo/pool/main/o/onedrive/"><img src="https://repology.org/badge/version-for-repo/mx_25/onedrive.svg?header=" alt="MX Linux package" width="46" height="20"></a>| Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| OpenSUSE                               | [onedrive](https://software.opensuse.org/package/onedrive)                                               |<a href="https://software.opensuse.org/package/onedrive"><img src="https://repology.org/badge/version-for-repo/opensuse_network_tumbleweed/onedrive.svg?header=" alt="openSUSE Tumbleweed package" width="46" height="20"></a>| Install via: `sudo zypper install onedrive` |
| OpenSUSE Build Service                 | [onedrive](https://build.opensuse.org/package/show/home:npreining:debian-ubuntu-onedrive/onedrive)       | No API available for version information | |
| Raspbian                               | [onedrive](https://archive.raspbian.org/raspbian/pool/main/o/onedrive/)                                  |<a href="https://archive.raspbian.org/raspbian/pool/main/o/onedrive/"><img src="https://repology.org/badge/version-for-repo/raspbian_stable/onedrive.svg?header=" alt="Raspbian Stable package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| RedHat Enterprise Linux 8              | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_8/onedrive.svg?header=" alt="EPEL 8 package" width="46" height="20"></a>| **Note:** You must install and enable the EPEL Repository first.<br><br>Install via: `sudo dnf install onedrive` |
| RedHat Enterprise Linux 9              | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_9/onedrive.svg?header=" alt="EPEL 9 package" width="46" height="20"></a>| **Note:** You must install and enable the EPEL Repository first.<br><br>Install via: `sudo dnf install onedrive` |
| RedHat Enterprise Linux 10             | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_10/onedrive.svg?header=" alt="EPEL 10 package" width="46" height="20"></a>| **Note:** You must install and enable the EPEL Repository first.<br><br>Install via: `sudo dnf install onedrive` |
| Slackware                              | [onedrive](https://slackbuilds.org/result/?search=onedrive&sv=)                                          |<a href="https://slackbuilds.org/result/?search=onedrive&sv="><img src="https://repology.org/badge/version-for-repo/slackbuilds/onedrive.svg?header=" alt="SlackBuilds package" width="46" height="20"></a>| Install via SlackBuilds: https://slackbuilds.org/result/?search=onedrive |
| Solus                                  | [onedrive](https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc)                          |<a href="https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc"><img src="https://repology.org/badge/version-for-repo/solus/onedrive.svg?header=" alt="Solus package" width="46" height="20"></a>| Install via: `sudo eopkg install onedrive` |
| Ubuntu 22.04 LTS                       | [onedrive](https://packages.ubuntu.com/jammy/onedrive)                                                   |<a href="https://packages.ubuntu.com/jammy/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |
| Ubuntu 24.04 LTS                       | [onedrive](https://packages.ubuntu.com/noble/onedrive)                                                   |<a href="https://packages.ubuntu.com/noble/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> | Install from the openSUSE Build Service (OBS) repository by following the [Ubuntu / Debian Package Installation Guide](ubuntu-package-install.md) |

> [!IMPORTANT]
> Distribution versions that are considered **End-of-Life (EOL)** are **no longer supported** or tested with current client releases.

> [!IMPORTANT]
> Distribution package maintainers are volunteers who generously contribute their time to make software available for your system. New releases of the client may take some time to appear in your distribution’s repositories.
> 
> If you believe a new release is significantly delayed, please contact your distribution’s package maintainer directly to request an update.
>
> **Do not open a bug report or discussion about this here**, as we have no control over the packaging process for your distribution.

### When Should You Build From Source?
You should only build from source in the following circumstances:

1. You are packaging for a custom or minimal distribution.
2. Your distribution does not have a package for your to install. Refer to [repology](https://repology.org/project/onedrive/versions) as a source of all 'onedrive' client versions available across tracked distributions.
3. You require code newer than the latest release or are building a Pull Request to validate a bugfix.

Outside of these 3 reasons, you should not be building the client yourself. You should endeavour where possible to use a pre-built package.

> [!IMPORTANT]
> If your distribution does not currently offer a packaged version of the client, you should **request that your distribution maintainers package and support it** as part of their official repositories.


## Building from Source
If you need to build the client from source, follow this high-level process:
1. Ensure your system meets the [minimum build requirements](#minimum-build-requirements).
2. Install the necessary build dependencies and a supported D compiler.
3. Clone the repository, configure the build options, compile, and install the client.

### Minimum Build Requirements
*   For successful compilation of this application, it's crucial that the build environment is equipped with a minimum of 1GB of memory and an additional 1GB of swap space.
*   Install the required distribution package dependencies covering the required development tools and development libraries for curl, sqlite and dbus where required.
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

> [!NOTE]
> Note the `source ~/dlang/dmd-X.XXX.X/activate` string as this will be needed later when building the client.

#### Installing LDC Compiler
To install the LDC Compiler, this can be achieved in the following manner:
```text
curl -fsS https://dlang.org/install.sh | bash -s ldc
```

> [!NOTE]
> Note the `source ~/dlang/ldc-X.XX.X/activate` string as this will be needed later when building the client.

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

#### CentOS Stream 8 | CentOS Stream 9 | CentOS Stream 10
```text
sudo dnf groupinstall 'Development Tools'
sudo dnf install libcurl-devel sqlite-devel dbus-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For GUI notifications the following is also necessary:
```text
sudo dnf install libnotify-devel
```

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
> [!NOTE]
> For Debian ARM platforms it is advisable to use the distribution provided 'ldc' package to ensure compiler consistency.

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
> 
> For FreeBSD it is advisable to use the distribution provided 'ldc' package to ensure compiler consistency.

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

#### MX Linux 25
 ```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev libsqlite3-dev pkg-config git curl systemd-dev libdbus-1-dev
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For GUI notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

#### OpenSUSE Leap | OpenSUSE Tumbleweed
```text
sudo zypper refresh
sudo zypper install gcc git libcurl-devel sqlite3-devel dmd phobos-devel phobos-devel-static dbus-1-devel
```
For GUI notifications the following is also necessary:
```text
sudo zypper install libnotify-devel
```

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

#### RedHat Enterprise Linux (RHEL) 8 | RedHat Enterprise Linux (RHEL) 9 | RedHat Enterprise Linux (RHEL) 10

```text
sudo dnf groupinstall 'Development Tools'
sudo dnf install libcurl-devel sqlite-devel dbus-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For GUI notifications the following is also necessary:
```text
sudo dnf install libnotify-devel
```

> [!NOTE]
> **Make sure repos are enabled/subscribed**. Minimal images/containers sometimes don’t have group metadata; on those, the group may appear “not available” until you enable the right repos (or use a full image).

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

## Clone, Configure, Build, Install

### High Level Steps to building the OneDrive Client for Linux
The overall process is as follows:
1. Install the required platform dependencies (see above)
2. If necessary, enable your DMD or LDC compiler environment
3. Clone the GitHub repository
4. Run the configure script adding any applicable build options (see below), then build the application
5. Either run the built binary directly from the build directory, or install it system-wide
6. If applicable, deactivate the DMD or LDC compiler environment when finished

### Building the Application Using Default configure Settings

#### Building on Linux using DMD, LDC or GDC
You must first **activate** the compiler environment before building. For example:
```text
source ~/dlang/dmd-2.091.1/activate

# or

source ~/dlang/ldc-1.20.1/activate
```

This command updates your environment (`PATH`, `LIBRARY_PATH`, `LD_LIBRARY_PATH`, etc.) so that the correct compiler is available.

If you skip this step, the build will fail because the compiler will not be found.

> [!NOTE]
> Replace the `source` string with the compiler environment activation string displayed when you installed the relevant compiler.

Once the compiler is activated, clone, build and install the client:
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure
make clean; make;
sudo make install
deactivate
```

> [!NOTE]
> If using GDC ≥ 15, specify it explicitly when configuring the application:
> ```text
> ./configure DC=gdc
> ```


#### Building on FreeBSD using gmake
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure
gmake clean; gmake;
gmake install
```
> [!NOTE]
> Build and install the application as 'root' unless you have installed 'sudo'

#### Building on ARM | Raspberry Pi
> [!CAUTION]
> The minimum LDC compiler version required to compile this application is 1.20.1, which is not available for Debian Buster or distributions based on Debian Buster. You are advised to first upgrade your platform distribution to one that is based on Debian Bullseye (Debian 11) or later.

> [!IMPORTANT]
> For successful compilation of this application, it's crucial that the build environment is equipped with a minimum of 1GB of memory and an additional 1GB of swap space. To verify your system's swap space availability, you can use the `swapon` command. Ensuring these requirements are met is vital for the application's compilation process.

> [!NOTE]
> The `configure` step will detect the correct version of LDC to be used when compiling the client under ARMHF and ARM64 CPU architectures.

```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure; make clean; make;
sudo make install
```

### Build Options for Customising the Application
The `configure` script provides several options that allow you to tailor the build to your needs. These options can be used to enable or adjust specific features in the client, including:
* Enabling GUI desktop notifications
* Enabling shell completion support
* Enabling internal debugging to assist with troubleshooting and performance analysis
* Specifying a custom systemd service installation directory

#### Build Option: Enable GUI Desktop Notifications
To enable GUI notification support, include the `--enable-notifications` option when running `configure`, for example:
```text
./configure --enable-notifications
```

Enabling this option allows the client to send GUI notifications through the Display Manager via the DBus interface.

> [!TIP]
> Package maintainers are encouraged to enable this option.
>
> When this option is enabled, the client automatically checks at runtime whether GUI notifications can be delivered via the Display Manager through the DBus interface. If this option is **not** enabled, GUI notifications are **disabled**.

#### Build Option: Enable Shell Completion Support
To enable command-line shell completions, include the `--enable-completions` option when running `configure`, for example:
```text
./configure --enable-completions
```
When enabled, completion scripts will be installed for **bash**, **zsh**, and **fish** shells.

By default, the installation directories are detected automatically.
If needed, you can manually specify the installation paths using the following options:
```text
--with-bash-completion-dir=<DIR>
--with-zsh-completion-dir=<DIR>
--with-fish-completion-dir=<DIR>
```

> [!TIP]
> Package maintainers are encouraged to enable this option.

#### Build Option: Enabling internal debugging
To enable internal debugging support, include the `--enable-debug` option when running `configure`, for example:
```text
./configure --enable-debug
```
Enabling this option builds the client with additional debug symbols outside of creating a separate debug package build.

This is particularly useful when investigating performance issues (e.g. with `perf`) or diagnosing application crashes.

**What difference does this make?**
Without this option, if the application encounters a crash, the stack trace may contain unresolved symbols, often shown as `??:??`, which makes identifying the cause very difficult.

With `--enable-debug` enabled, the resulting crash stack trace includes full source file and line information. This allows the issue to be located and isolated quickly and accurately.

> [!TIP]
> Package maintainers are encouraged to enable this option.

#### Build Option: Customising the Systemd Service Installation Directory
By default, systemd service files are installed into the directories detected via `pkg-config --variable=systemdsystemunitdir systemd` and related settings.

If you need to override these locations, specify one or both of the following options when running `configure`:
```text
--with-systemdsystemunitdir=<DIR>   # System-wide service unit directory
--with-systemduserunitdir=<DIR>     # User-level service unit directory
```
To **disable** installation of a service file entirely, pass `no` as the directory value. For example:
```text
./configure --with-systemduserunitdir=no
```
This prevents the corresponding service unit from being installed.


## Upgrading the Client
> [!CAUTION]
> Before starting any upgrade, **stop any running systemd service for the client**. This ensures the service is restarted using the updated binary.

How you upgrade depends on how the client was originally installed:

### If installed from a distribution package
When the package maintainer publishes an updated version, the client will be upgraded automatically as part of your normal system package updates (e.g., `apt upgrade`, `dnf upgrade`, `zypper up`, etc.).

### If installed from source
To upgrade a source-built installation, the recommended approach is:

1. Uninstall the existing client (see instructions below).
2. Re-clone the repository.
3. Re-compile and re-install the new version.

> [!NOTE]
> The uninstall process removes all components, including systemd service files.
> If you created custom systemd unit files (e.g., for SharePoint library access), you will need to recreate or restore them after re-installation.

You **may** choose to skip the uninstall step and simply re-compile and re-install over the top.
However, this risks leaving **multiple** `onedrive` **binaries** on your system.
Depending on your system `PATH`, the wrong binary may be executed.

After installation, verify the version in use:
```text
onedrive --version
```
This confirms that the upgrade was successful.

## Uninstalling the client
How to uninstall depends on how the client was installed.

### If installed from a distribution package
Uninstall the client using your distribution’s package management tools.

Refer to your distribution’s documentation for the correct removal command (e.g. `apt remove`, `dnf remove`, `zypper remove`, etc.).

### If installed from source
If you built and installed the client from a GitHub clone, run the following command from within the cloned repository directory:
```text
sudo make uninstall
```
This removes the installed `onedrive` binary and associated system files.

#### Optional: Remove client configuration and state
If you do not plan to upgrade or reinstall and wish to remove all client data, run:
```text
rm -rf ~/.config/onedrive
```

> [!IMPORTANT]
> If you used the `--confdir` option, replace `~/.config/onedrive` with the custom configuration directory you specified.

#### Optional: Remove only the application key
If you want to retain your items database but remove the stored authentication token, run:
```text
rm -f ~/.config/onedrive/refresh_token
```
This preserves sync state while requiring re-authentication on next run.