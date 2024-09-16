# Installing or Upgrading using Distribution Packages or Building the OneDrive Client for Linux from source

## Installing or Upgrading using Distribution Packages
This project has been packaged for the following Linux distributions as per below. The current client release is: [![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)

Only the current release version or greater is supported. Earlier versions are not supported and should not be installed or used. 

> [!CAUTION]
> Distribution packages may be of an older release when compared to the latest release that is [available](https://github.com/abraunegg/onedrive/releases). If any package version indicator below is 'red' for your distribution, it is recommended that you build from source. Do not install the software from the available distribution package. If a package is out of date, please contact the package maintainer for resolution.

| Distribution                    | Package Name & Package Link                                                                              | &nbsp;&nbsp;PKG_Version&nbsp;&nbsp; | &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 | Extra Details                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
|---------------------------------|----------------------------------------------------------------------------------------------------------|:---------------:|:----:|:------:|:-----:|:-------:|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Alpine Linux                    | [onedrive](https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge)                              |<a href="https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge"><img src="https://repology.org/badge/version-for-repo/alpine_edge/onedrive.svg?header=" alt="Alpine Linux Edge package" width="46" height="20"></a>|❌|✔|❌|✔ | |
| Arch Linux<br><br>Manjaro Linux | [onedrive-abraunegg](https://aur.archlinux.org/packages/onedrive-abraunegg/)                             |<a href="https://aur.archlinux.org/packages/onedrive-abraunegg"><img src="https://repology.org/badge/version-for-repo/aur/onedrive-abraunegg.svg?header=" alt="AUR package" width="46" height="20"></a>|✔|✔|✔|✔ | Install via: `pamac build onedrive-abraunegg` from the Arch Linux User Repository (AUR)<br><br>**Note:** You must first install 'base-devel' as this is a pre-requisite for using the AUR<br><br>**Note:** If asked regarding a provider for 'd-runtime' and 'd-compiler', select 'liblphobos' and 'ldc'<br><br>**Note:** System must have at least 1GB of memory & 1GB swap space
| CentOS 8                        | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_8/onedrive.svg?header=" alt="CentOS 8 package" width="46" height="20"></a>|❌|✔|❌|✔| **Note:** You must install the EPEL Repository first |
| CentOS 9                        | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/epel_9/onedrive.svg?header=" alt="CentOS 9 package" width="46" height="20"></a>|❌|✔|❌|✔| **Note:** You must install the EPEL Repository first |
| Debian 11                       | [onedrive](https://packages.debian.org/bullseye/source/onedrive)                                         |<a href="https://packages.debian.org/bullseye/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_11/onedrive.svg?header=" alt="Debian 11 package" width="46" height="20"></a>|✔|✔|✔|✔| **Note:** Do not install from Debian Package Repositories as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Debian 11 that you install from OpenSuSE Build Service using the Debian Package Install [Instructions](ubuntu-package-install.md) |
| Debian 12                       | [onedrive](https://packages.debian.org/bookworm/source/onedrive)                                         |<a href="https://packages.debian.org/bookworm/source/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_12/onedrive.svg?header=" alt="Debian 12 package" width="46" height="20"></a>|✔|✔|✔|✔| **Note:** Do not install from Debian Package Repositories as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Debian 12 that you install from OpenSuSE Build Service using the Debian Package Install [Instructions](ubuntu-package-install.md) |
| Debian Sid                      | [onedrive](https://packages.debian.org/sid/onedrive)                                                     |<a href="https://packages.debian.org/sid/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_unstable/onedrive.svg?header=" alt="Debian Sid package" width="46" height="20"></a>|✔|✔|✔|✔| |
| Fedora                          | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)                              |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/fedora_rawhide/onedrive.svg?header=" alt="Fedora Rawhide package" width="46" height="20"></a>|✔|✔|✔|✔| |
| Gentoo                          | [onedrive](https://gpo.zugaina.org/net-misc/onedrive)                                                    | No API Available |✔|✔|❌|❌| |
| Homebrew                        | [onedrive](https://formulae.brew.sh/formula/onedrive)                                                    |<a href="https://formulae.brew.sh/formula/onedrive"><img src="https://repology.org/badge/version-for-repo/homebrew/onedrive.svg?header=" alt="Homebrew package" width="46" height="20"></a> |❌|✔|❌|❌| |
| Linux Mint 20.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Linux Mint Repositories as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Linux Mint that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Linux Mint 21.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Linux Mint Repositories as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Linux Mint that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Linux Mint 22.x                 | [onedrive](https://community.linuxmint.com/software/view/onedrive)                                       |<a href="https://community.linuxmint.com/software/view/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Linux Mint Repositories as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Linux Mint that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| NixOS                           | [onedrive](https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive) |<a href="https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive"><img src="https://repology.org/badge/version-for-repo/nix_unstable/onedrive.svg?header=" alt="nixpkgs unstable package" width="46" height="20"></a>|❌|✔|❌|❌| Use package `onedrive` either by adding it to `configuration.nix` or by using the command `nix-env -iA <channel name>.onedrive`. This does not install a service. To install a service, use unstable channel (will stabilize in 20.09) and add `services.onedrive.enable=true` in `configuration.nix`. You can also add a custom package using the `services.onedrive.package` option (recommended since package lags upstream). Enabling the service installs a default package too (based on the channel). You can also add multiple onedrive accounts trivially, see [documentation](https://github.com/NixOS/nixpkgs/pull/77734#issuecomment-575874225). |
| OpenSuSE                        | [onedrive](https://software.opensuse.org/package/onedrive)                                               |<a href="https://software.opensuse.org/package/onedrive"><img src="https://repology.org/badge/version-for-repo/opensuse_network_tumbleweed/onedrive.svg?header=" alt="openSUSE Tumbleweed package" width="46" height="20"></a>|✔|✔|❌|❌| |
| OpenSuSE Build Service          | [onedrive](https://build.opensuse.org/package/show/home:npreining:debian-ubuntu-onedrive/onedrive)       | No API Available |✔|✔|✔|✔| Package Build Service for Debian and Ubuntu | 
| Raspbian                        | [onedrive](https://archive.raspbian.org/raspbian/pool/main/o/onedrive/)                                  |<a href="https://archive.raspbian.org/raspbian/pool/main/o/onedrive/"><img src="https://repology.org/badge/version-for-repo/raspbian_stable/onedrive.svg?header=" alt="Raspbian Stable package" width="46" height="20"></a> |❌|❌|✔|✔| **Note:** Do not install from Raspbian Package Repositories as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Raspbian that you install from OpenSuSE Build Service using the Debian Package Install [Instructions](ubuntu-package-install.md) |
| Slackware                       | [onedrive](https://slackbuilds.org/result/?search=onedrive&sv=)                                          |<a href="https://slackbuilds.org/result/?search=onedrive&sv="><img src="https://repology.org/badge/version-for-repo/slackbuilds/onedrive.svg?header=" alt="SlackBuilds package" width="46" height="20"></a>|✔|✔|❌|❌| |
| Solus                           | [onedrive](https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc)                          |<a href="https://packages.getsol.us/shannon/o/onedrive/?sort=time&order=desc"><img src="https://repology.org/badge/version-for-repo/solus/onedrive.svg?header=" alt="Solus package" width="46" height="20"></a>|❌|✔|❌|❌| |
| Ubuntu 20.04                    | [onedrive](https://packages.ubuntu.com/focal/onedrive)                                                   |<a href="https://packages.ubuntu.com/focal/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Ubuntu Universe as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Ubuntu that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Ubuntu 22.04                    | [onedrive](https://packages.ubuntu.com/jammy/onedrive)                                                   |<a href="https://packages.ubuntu.com/jammy/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Ubuntu Universe as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Ubuntu that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Ubuntu 23.04                    | [onedrive](https://packages.ubuntu.com/lunar/onedrive)                                                   |<a href="https://packages.ubuntu.com/lunar/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_23_04/onedrive.svg?header=" alt="Ubuntu 23.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Ubuntu Universe as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Ubuntu that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Ubuntu 24.04                    | [onedrive](https://packages.ubuntu.com/noble/onedrive)                                                   |<a href="https://packages.ubuntu.com/noble/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_24_04/onedrive.svg?header=" alt="Ubuntu 24.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Ubuntu Universe as the package is obsolete and is not supported<br><br>For a supported application version, it is recommended that for Ubuntu that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Void Linux                      | [onedrive](https://voidlinux.org/packages/?arch=x86_64&q=onedrive)                                       |<a href="https://voidlinux.org/packages/?arch=x86_64&q=onedrive"><img src="https://repology.org/badge/version-for-repo/void_x86_64/onedrive.svg?header=" alt="Void Linux x86_64 package" width="46" height="20"></a>|✔|✔|❌|❌| |

## Building from Source - High Level Requirements
*   For successful compilation of this application, it's crucial that the build environment is equipped with a minimum of 1GB of memory and an additional 1GB of swap space.
*   Install the required distribution package dependencies coverering the required development tools and development libraries for curl and sqlite
*   Install the [Digital Mars D Compiler (DMD)](https://dlang.org/download.html) or [LDC – the LLVM-based D Compiler](https://github.com/ldc-developers/ldc)

> [!IMPORTANT]
> To compile this application successfully, it is essential to use either DMD version **2.088.0** or higher, or LDC version **1.18.0** or higher. Ensuring compatibility and optimal performance necessitates the use of these specific versions or their more recent updates.

### Example for installing DMD Compiler
```text
curl -fsS https://dlang.org/install.sh | bash -s dmd
```

### Example for installing LDC Compiler
```text
curl -fsS https://dlang.org/install.sh | bash -s ldc
```

## Distribution Package Dependencies
### Dependencies: Ubuntu 16.x
Ubuntu Linux 16.x LTS reached the end of its five-year LTS window on April 30th 2021 and is no longer supported.

### Dependencies: Ubuntu 18.x / Lubuntu 18.x
Ubuntu Linux 18.x LTS reached the end of its five-year LTS window on May 31th 2023 and is no longer supported.

### Dependencies: Debian 9
Debian 9 reached the end of its five-year support window on June 30th 2022 and is no longer supported.

### Dependencies: Ubuntu 20.x -> Ubuntu 24.x / Debian 10 -> Debian 12 - x86_64
These dependencies are also applicable for all Ubuntu based distributions such as:
*   Lubuntu
*   Linux Mint
*   POP OS
*   Peppermint OS
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev libsqlite3-dev pkg-config git curl
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: CentOS 6.x / RHEL 6.x
CentOS 6.x and RHEL 6.x reached End of Life status on November 30th 2020 and is no longer supported.

### Dependencies: CentOS 7.x / RHEL 7.x
CentOS 7.x and RHEL 7.x reached End of Life status on June 30th 2024 and is no longer supported.

### Dependencies: Fedora > Version 18 / CentOS 8.x / CentOS 9.x/ RHEL 8.x / RHEL 9.x
```text
sudo dnf groupinstall 'Development Tools'
sudo dnf install libcurl-devel sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is also necessary:
```text
sudo dnf install libnotify-devel
```

### Dependencies: Arch Linux & Manjaro Linux
```text
sudo pacman -S make pkg-config curl sqlite ldc
```
For notifications the following is also necessary:
```text
sudo pacman -S libnotify
```

### Dependencies: Raspbian (ARMHF) and Ubuntu 22.x / Debian 11 / Debian 12 / Raspbian (ARM64)
> [!CAUTION]
> The minimum LDC compiler version required to compile this application is 1.18.0, which is not available for Debian Buster or distributions based on Debian Buster. You are advised to first upgrade your platform distribution to one that is based on Debian Bullseye (Debian 11) or later.

These instructions were validated using:
*   `Linux raspberrypi 5.10.92-v8+ #1514 SMP PREEMPT Mon Jan 17 17:39:38 GMT 2022 aarch64` (2022-01-28-raspios-bullseye-armhf-lite) using Raspberry Pi 3B (revision 1.2)
*   `Linux raspberrypi 5.10.92-v8+ #1514 SMP PREEMPT Mon Jan 17 17:39:38 GMT 2022 aarch64` (2022-01-28-raspios-bullseye-arm64-lite) using Raspberry Pi 3B (revision 1.2)
*   `Linux ubuntu 5.15.0-1005-raspi #5-Ubuntu SMP PREEMPT Mon Apr 4 12:21:48 UTC 2022 aarch64 aarch64 aarch64 GNU/Linux` (ubuntu-22.04-preinstalled-server-arm64+raspi) using Raspberry Pi 3B (revision 1.2)

> [!IMPORTANT]
> For successful compilation of this application, it's crucial that the build environment is equipped with a minimum of 1GB of memory and an additional 1GB of swap space. To verify your system's swap space availability, you can use the `swapon` command. Ensuring these requirements are met is vital for the application's compilation process.

```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev libsqlite3-dev pkg-config git curl ldc
```
For notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Gentoo
```text
sudo emerge app-portage/layman
sudo layman -a dlang
```
Add ebuild from contrib/gentoo to a local overlay to use.

For notifications the following is also necessary:
```text
sudo emerge x11-libs/libnotify
```

### Dependencies: OpenSuSE Leap 15.0
```text
sudo zypper addrepo https://download.opensuse.org/repositories/devel:languages:D/openSUSE_Leap_15.0/devel:languages:D.repo
sudo zypper refresh
sudo zypper install gcc git libcurl-devel sqlite3-devel dmd phobos-devel phobos-devel-static
```
For notifications the following is also necessary:
```text
sudo zypper install libnotify-devel
```

### Dependencies: OpenSuSE Leap 15.1
```text
sudo zypper addrepo https://download.opensuse.org/repositories/devel:languages:D/openSUSE_Leap_15.1/devel:languages:D.repo
sudo zypper refresh
sudo zypper install gcc git libcurl-devel sqlite3-devel dmd phobos-devel phobos-devel-static
```
For notifications the following is also necessary:
```text
sudo zypper install libnotify-devel
```

### Dependencies: OpenSuSE Leap 15.2
```text
sudo zypper refresh
sudo zypper install gcc git libcurl-devel sqlite3-devel dmd phobos-devel phobos-devel-static
```
For notifications the following is also necessary:
```text
sudo zypper install libnotify-devel
```

## Compilation & Installation
### High Level Steps
1.  Install the platform dependencies for your Linux OS
2.  Activate your DMD or LDC compiler
3.  Clone the GitHub repository, run configure and make, then install
4.  Deactivate your DMD or LDC compiler

### Building using DMD Reference Compiler
Before cloning and compiling, if you have installed DMD via curl for your OS, you will need to activate DMD as per example below:
```text
Run `source ~/dlang/dmd-2.088.0/activate` in your shell to use dmd-2.088.0.
This will setup PATH, LIBRARY_PATH, LD_LIBRARY_PATH, DMD, DC, and PS1.
Run `deactivate` later on to restore your environment.
```
Without performing this step, the compilation process will fail.

> [!NOTE]
> Depending on your DMD version, substitute `2.088.0` above with your DMD version that is installed.

```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure
make clean; make;
sudo make install
```

### Build options
#### GUI Notification Support
GUI notification support can be enabled using the `configure` switch `--enable-notifications`.

#### systemd service directory customisation support
Systemd service files are installed in the appropriate directories on the system,
as provided by `pkg-config systemd` settings. If the need for overriding the
deduced path are necessary, the two options `--with-systemdsystemunitdir` (for
the Systemd system unit location), and `--with-systemduserunitdir` (for the
Systemd user unit location) can be specified. Passing in `no` to one of these
options disabled service file installation.

#### Additional Compiler Debug
By passing `--enable-debug` to the `configure` call, `onedrive` gets built with additional debug
information, useful (for example) to get `perf`-issued figures.

#### Shell Completion Support
By passing `--enable-completions` to the `configure` call, shell completion functions are
installed for `bash`, `zsh` and `fish`. The installation directories are determined
as far as possible automatically, but can be overridden by passing
`--with-bash-completion-dir=<DIR>`, `--with-zsh-completion-dir=<DIR>`, and
`--with-fish-completion-dir=<DIR>` to `configure`.

### Building using a different compiler (for example [LDC](https://wiki.dlang.org/LDC))
#### ARMHF Architecture (Raspbian) and ARM64 Architecture (Ubuntu 22.x / Debian 11 / Debian 12 / Raspbian)
> [!CAUTION]
> The minimum LDC compiler version required to compile this application is 1.18.0, which is not available for Debian Buster or distributions based on Debian Buster. You are advised to first upgrade your platform distribution to one that is based on Debian Bullseye (Debian 11) or later.

> [!IMPORTANT]
> For successful compilation of this application, it's crucial that the build environment is equipped with a minimum of 1GB of memory and an additional 1GB of swap space. To verify your system's swap space availability, you can use the `swapon` command. Ensuring these requirements are met is vital for the application's compilation process.

```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure DC=/usr/bin/ldmd2
make clean; make
sudo make install
```

## Upgrading the client
If you have installed the client from a distribution package, the client will be updated when the distribution package is updated by the package maintainer and will be updated to the new application version when you perform your package update.

If you have built the client from source, to upgrade your client, it is recommended that you first uninstall your existing 'onedrive' binary (see below), then re-install the client by re-cloning, re-compiling and re-installing the client again to install the new version.

> [!NOTE]
> Following the uninstall process will remove all client components including *all* systemd files, including any custom files created for specific access such as SharePoint Libraries.

You can optionally choose to not perform this uninstallation step, and simply re-install the client by re-cloning, re-compiling and re-installing the client again - however the risk here is that you end up with two onedrive client binaries on your system, and depending on your system search path preferences, this will determine which binary is used.

> [!CAUTION]
> Before performing any upgrade, it is highly recommended for you to stop any running systemd service if applicable to ensure that these services are restarted using the updated client version.

Post re-install, to confirm that you have the new version of the client installed, use `onedrive --version` to determine the client version that is now installed.

## Uninstalling the client
### Uninstalling the client if installed from distribution package
Follow your distribution documentation to uninstall the package that you installed

### Uninstalling the client if installed and built from source
From within your GitHub repository clone, perform the following to remove the 'onedrive' binary:
```text
sudo make uninstall
```

If you are not upgrading your client, to remove your application state and configuration, perform the following additional step:
```
rm -rf ~/.config/onedrive
```
> [!IMPORTANT]
> If you are using the `--confdir option`, substitute `~/.config/onedrive` for the correct directory storing your client configuration.

If you want to just delete the application key, but keep the items database:
```text
rm -f ~/.config/onedrive/refresh_token
```
