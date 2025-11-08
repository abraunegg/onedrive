# Installing or Upgrading the OneDrive Client for Linux

## Table of Contents

## Overview

## Recommended Installation Method (Using Pre-Built Packages)

### Important Notice for all Debian | Ubuntu | Linux Mint | Pop!_OS | Raspberry Pi OS | Zorin Users

> [!IMPORTANT]
> **DO NOT install the OneDrive client from your distribution repositories**
>
> These packages are **outdated, unsupported, and contain known defects**
>
> Install the fully supported package from the **openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md)

### Which Installation Method Should I Use?

| Distribution                    | Distribution Package Name & Link                                                                         | &nbsp;&nbsp;Distribution Package Version&nbsp;&nbsp; | Correct Installation Method |
|---------------------------------|----------------------------------------------------------------------------------------------------------|:----------------------------------------------------:|-----------------------------|
| Alpine Linux                    | [onedrive](https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge)                              |<a href="https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge"><img src="https://repology.org/badge/version-for-repo/alpine_edge/onedrive.svg?header=" alt="Alpine Linux Edge package" width="46" height="20"></a> | Alpine **Stable** may ship older versions. If your version is outdated, you need to build from source |
| Arch Linux<br><br>Manjaro Linux | [onedrive-abraunegg](https://aur.archlinux.org/packages/onedrive-abraunegg/)                             |<a href="https://aur.archlinux.org/packages/onedrive-abraunegg"><img src="https://repology.org/badge/version-for-repo/aur/onedrive-abraunegg.svg?header=" alt="AUR package" width="46" height="20"></a>| Install via: `pamac build onedrive-abraunegg` from the Arch Linux User Repository (AUR)<br><br>**Note:** You must first install 'base-devel' as this is a pre-requisite for using the AUR<br><br>**Note:** If asked regarding a provider for 'd-runtime' and 'd-compiler', select 'liblphobos' and 'ldc'<br><br>**Note:** System must have at least 1GB of memory & 1GB swap space<br><br>AUR package `onedrive-abraunegg` follows the release versions<br>AUR package `onedrive-abraunegg-git` follows the 'master' branch |
| CentOS Stream 8                 | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_8/onedrive.svg?header=" alt="CentOS 8 package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| CentOS Stream 9                 | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_9/onedrive.svg?header=" alt="CentOS 9 package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| CentOS Stream 10                | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_10/onedrive.svg?header=" alt="CentOS 10 package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| Debian 11                       | [onedrive](https://packages.debian.org/bullseye/source/onedrive)                                         |<a href="https://packages.debian.org/bullseye/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_11/onedrive.svg?header=" alt="Debian 11 package" width="46" height="20"></a>| **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Debian 12                       | [onedrive](https://packages.debian.org/bookworm/source/onedrive)                                         |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_12/onedrive.svg?header=" alt="Debian 12 package" width="46" height="20"></a>| **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Debian 13                       | [onedrive](https://packages.debian.org/trixie/source/onedrive)                                           |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_13/onedrive.svg?header=" alt="Debian 13 package" width="46" height="20"></a>| **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Debian Sid                      | [onedrive](https://packages.debian.org/sid/onedrive)                                                     |<a href="https://packages.debian.org/sid/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_unstable/onedrive.svg?header=" alt="Debian Sid package" width="46" height="20"></a>| Install via: `sudo apt install --no-install-recommends --no-install-suggests onedrive` |
| Fedora                          | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/fedora_rawhide/onedrive.svg?header=" alt="Fedora Rawhide package" width="46" height="20"></a>| Install via: `sudo dnf install onedrive` |
| FreeBSD                         | [onedrive](https://www.freshports.org/net/onedrive)                                                      |<a href="https://www.freshports.org/net/onedrive"><img src="https://repology.org/badge/version-for-repo/freebsd/onedrive.svg?header=" alt="FreeBSD package" width="46" height="20"></a>| Install via: `pkg install onedrive` |
| Gentoo                          | [onedrive](https://packages.gentoo.org/packages/net-misc/onedrive)                                       |<a href="https://packages.gentoo.org/packages/net-misc/onedrive"><img src="https://repology.org/badge/version-for-repo/gentoo/onedrive.svg?header=" alt="Gentoo package" width="46" height="20"></a>| Install via: `sudo emerge net-misc/onedrive` |
| Homebrew                        | [onedrive-cli](https://formulae.brew.sh/formula/onedrive-cli)                                            |<a href="https://formulae.brew.sh/formula/onedrive-cli"><img src="https://repology.org/badge/version-for-repo/homebrew/onedrive-cli.svg?header=" alt="Homebrew package" width="46" height="20"></a> | Install via: `brew install onedrive-cli` |
| Linux Mint 20.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Linux Mint 21.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Linux Mint 22.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| NixOS                           | [onedrive](https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive) |<a href="https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive"><img src="https://repology.org/badge/version-for-repo/nix_unstable/onedrive.svg?header=" alt="nixpkgs unstable package" width="46" height="20"></a>| Install via: `nix-env -iA nixpkgs.onedrive` **or** `services.onedrive.enable = true` in `configuration.nix` |
| OpenSUSE                        | [onedrive](https://software.opensuse.org/package/onedrive)                                               |<a href="https://software.opensuse.org/package/onedrive"><img src="https://repology.org/badge/version-for-repo/opensuse_network_tumbleweed/onedrive.svg?header=" alt="openSUSE Tumbleweed package" width="46" height="20"></a>| Install via: `sudo zypper install onedrive` |
| Raspbian                        | [onedrive](https://archive.raspbian.org/raspbian/pool/main/o/onedrive/)                                  |<a href="https://archive.raspbian.org/raspbian/pool/main/o/onedrive/"><img src="https://repology.org/badge/version-for-repo/raspbian_stable/onedrive.svg?header=" alt="Raspbian Stable package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Slackware                       | [onedrive](https://slackbuilds.org/result/?search=onedrive&sv=)                                          |<a href="https://slackbuilds.org/result/?search=onedrive&sv="><img src="https://repology.org/badge/version-for-repo/slackbuilds/onedrive.svg?header=" alt="SlackBuilds package" width="46" height="20"></a>| Install via SlackBuilds: https://slackbuilds.org/result/?search=onedrive |
| Solus                           | [onedrive](https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc)                          |<a href="https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc"><img src="https://repology.org/badge/version-for-repo/solus/onedrive.svg?header=" alt="Solus package" width="46" height="20"></a>| Install via: `sudo eopkg install onedrive` |
| Ubuntu 20.04 LTS                | [onedrive](https://packages.ubuntu.com/focal/onedrive)                                                   |<a href="https://packages.ubuntu.com/focal/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Ubuntu 22.04 LTS                | [onedrive](https://packages.ubuntu.com/jammy/onedrive)                                                   |<a href="https://packages.ubuntu.com/jammy/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Ubuntu 24.04 LTS                | [onedrive](https://packages.ubuntu.com/noble/onedrive)                                                   |<a href="https://packages.ubuntu.com/noble/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** using these install [instructions](ubuntu-package-install.md) |
| Void Linux                      | [onedrive](https://voidlinux.org/packages/?arch=x86_64&q=onedrive)                                       |<a href="https://voidlinux.org/packages/?arch=x86_64&q=onedrive"><img src="https://repology.org/badge/version-for-repo/void_x86_64/onedrive.svg?header=" alt="Void Linux x86_64 package" width="46" height="20"></a>||


## When Should You Build From Source?
You should only build from source in the following circumstances:

1. You are packaging for a custom or minimal distro
2. Your distribution does not have a package for your to install. Refer to [repology](https://repology.org/project/onedrive/versions) as a source of all 'onedrive' client versions available across tracked distributions
3. You require code newer than the latest release or are building a Pull Request to validate a bugfix

Outside of these 3 reasons, you should not be building the client yourself. You should endevour where possible to use a pre-built package.

> [!IMPORTANT]
> If your distribution does not provide a package, raise a request with them to get the client packaged and maintained in your chosen distribution.


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

#### Arch Linux & Manjaro Linux
- detail packages

#### CentOS
- detail packages

#### Debian | Linux Mint Debian Edition
 - detail packages

#### Fedora
- detail packages

#### FreeBSD
- detail packages

#### Gentoo
- detail packages

#### Ubuntu | Kubuntu | Linux Mint
- detail packages

#### OpenSUSE Leap
- detail packages

#### OpenSUSE Tumbleweed
- detail packages

#### Ubuntu
- detail packages

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




