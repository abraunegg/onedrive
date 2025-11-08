# Installing or Upgrading the OneDrive Client for Linux

## Table of Contents

## Overview

## Recommended Installation Method (Using Pre-Built Packages)

### Important Notice for all Debian | Ubuntu | Linux Mint | Pop!_OS | Raspberry Pi OS | Zorin Users

> [!IMPORTANT]
> **DO NOT install the OneDrive client from your distribution repositories**
> These packages are **outdated, unsupported, and contain known defects**
> Install the fully supported package from the **openSUSE Build Service (OBS)**

### Which Installation Method Should I Use?

| Distribution                    | Distribution Package Name & Link                                                                         | &nbsp;&nbsp;Distribution Package Version&nbsp;&nbsp; | Correct Installation Method |
|---------------------------------|----------------------------------------------------------------------------------------------------------|:----------------------------------------------------:|-----------------------------|
| Alpine Linux                    | [onedrive](https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge)                              |<a href="https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge"><img src="https://repology.org/badge/version-for-repo/alpine_edge/onedrive.svg?header=" alt="Alpine Linux Edge package" width="46" height="20"></a>||
| Arch Linux<br><br>Manjaro Linux | [onedrive-abraunegg](https://aur.archlinux.org/packages/onedrive-abraunegg/)                             |<a href="https://aur.archlinux.org/packages/onedrive-abraunegg"><img src="https://repology.org/badge/version-for-repo/aur/onedrive-abraunegg.svg?header=" alt="AUR package" width="46" height="20"></a>||
| CentOS 8                        | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_8/onedrive.svg?header=" alt="CentOS 8 package" width="46" height="20"></a>||
| CentOS 9                        | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_9/onedrive.svg?header=" alt="CentOS 9 package" width="46" height="20"></a>||
| Debian 11                       | [onedrive](https://packages.debian.org/bullseye/source/onedrive)                                         |<a href="https://packages.debian.org/bullseye/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_11/onedrive.svg?header=" alt="Debian 11 package" width="46" height="20"></a>| **Install using the openSUSE Build Service (OBS)** |
| Debian 12                       | [onedrive](https://packages.debian.org/bookworm/source/onedrive)                                         |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_12/onedrive.svg?header=" alt="Debian 12 package" width="46" height="20"></a>| **Install using the openSUSE Build Service (OBS)** |
| Debian 13                       | [onedrive](https://packages.debian.org/trixie/source/onedrive)                                           |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_13/onedrive.svg?header=" alt="Debian 13 package" width="46" height="20"></a>| **Install using the openSUSE Build Service (OBS)** |
| Debian Sid                      | [onedrive](https://packages.debian.org/sid/onedrive)                                                     |<a href="https://packages.debian.org/sid/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_unstable/onedrive.svg?header=" alt="Debian Sid package" width="46" height="20"></a>||
| Fedora                          | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/fedora_rawhide/onedrive.svg?header=" alt="Fedora Rawhide package" width="46" height="20"></a>||
| FreeBSD                         | [onedrive](https://www.freshports.org/net/onedrive)                                                      |<a href="https://www.freshports.org/net/onedrive"><img src="https://repology.org/badge/version-for-repo/freebsd/onedrive.svg?header=" alt="FreeBSD package" width="46" height="20"></a>||
| Gentoo                          | [onedrive](https://packages.gentoo.org/packages/net-misc/onedrive)                                       |<a href="https://packages.gentoo.org/packages/net-misc/onedrive"><img src="https://repology.org/badge/version-for-repo/gentoo/onedrive.svg?header=" alt="Gentoo package" width="46" height="20"></a>||
| Homebrew                        | [onedrive-cli](https://formulae.brew.sh/formula/onedrive-cli)                                            |<a href="https://formulae.brew.sh/formula/onedrive-cli"><img src="https://repology.org/badge/version-for-repo/homebrew/onedrive-cli.svg?header=" alt="Homebrew package" width="46" height="20"></a> ||
| Linux Mint 20.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** |
| Linux Mint 21.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** |
| Linux Mint 22.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** |
| NixOS                           | [onedrive](https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive) |<a href="https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive"><img src="https://repology.org/badge/version-for-repo/nix_unstable/onedrive.svg?header=" alt="nixpkgs unstable package" width="46" height="20"></a>||
| OpenSUSE                        | [onedrive](https://software.opensuse.org/package/onedrive)                                               |<a href="https://software.opensuse.org/package/onedrive"><img src="https://repology.org/badge/version-for-repo/opensuse_network_tumbleweed/onedrive.svg?header=" alt="openSUSE Tumbleweed package" width="46" height="20"></a>||
| Raspbian                        | [onedrive](https://archive.raspbian.org/raspbian/pool/main/o/onedrive/)                                  |<a href="https://archive.raspbian.org/raspbian/pool/main/o/onedrive/"><img src="https://repology.org/badge/version-for-repo/raspbian_stable/onedrive.svg?header=" alt="Raspbian Stable package" width="46" height="20"></a> ||
| Slackware                       | [onedrive](https://slackbuilds.org/result/?search=onedrive&sv=)                                          |<a href="https://slackbuilds.org/result/?search=onedrive&sv="><img src="https://repology.org/badge/version-for-repo/slackbuilds/onedrive.svg?header=" alt="SlackBuilds package" width="46" height="20"></a>||
| Solus                           | [onedrive](https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc)                          |<a href="https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc"><img src="https://repology.org/badge/version-for-repo/solus/onedrive.svg?header=" alt="Solus package" width="46" height="20"></a>||
| Ubuntu 20.04 LTS                | [onedrive](https://packages.ubuntu.com/focal/onedrive)                                                   |<a href="https://packages.ubuntu.com/focal/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** |
| Ubuntu 22.04 LTS                | [onedrive](https://packages.ubuntu.com/jammy/onedrive)                                                   |<a href="https://packages.ubuntu.com/jammy/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** |
| Ubuntu 24.04 LTS                | [onedrive](https://packages.ubuntu.com/noble/onedrive)                                                   |<a href="https://packages.ubuntu.com/noble/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> | **Install using the openSUSE Build Service (OBS)** |
| Void Linux                      | [onedrive](https://voidlinux.org/packages/?arch=x86_64&q=onedrive)                                       |<a href="https://voidlinux.org/packages/?arch=x86_64&q=onedrive"><img src="https://repology.org/badge/version-for-repo/void_x86_64/onedrive.svg?header=" alt="Void Linux x86_64 package" width="46" height="20"></a>||




## When Should You Build From Source?
Short list of real reasons:
- You are packaging for a custom or minimal distro
- You are contributing patches or developing features
- You require code newer than the latest release

Otherwise → **use packages above.**

## Building from Source
1. Ensure your system meets the minimum requirements
2. Install Build Dependencies
3. Clone, configure, build, install

### Minimum Requirements
- 1GB RAM + 1GB Swap recommended
- D compiler: DMD ≥ 2.091.1, LDC ≥ 1.20.1, or GDC ≥ 15

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




