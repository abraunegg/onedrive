# Installing or Upgrading using Distribution Packages or Building the OneDrive Client for Linux from source

## Installing or Upgrading using Distribution Packages
This project has been packaged for the following Linux distributions as per below. The current client release is: [![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)

Only the current release version or greater is supported. Earlier versions are not supported and should not be installed or used. 

#### Important Note:
Distribution packages may be of an older release when compared to the latest release that is [available](https://github.com/abraunegg/onedrive/releases). If any package version indicator below is 'red' for your distribution, it is recommended that you build from source. Do not install the software from the available distribution package. If a package is out of date, please contact the package maintainer for resolution.

| Distribution                    | Package Name & Package Link                                                  | &nbsp;&nbsp;PKG_Version&nbsp;&nbsp; | &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 | Extra Details                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
|---------------------------------|------------------------------------------------------------------------------|:---------------:|:----:|:------:|:-----:|:-------:|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Alpine Linux                    | [onedrive](https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge)  |<a href="https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge"><img src="https://repology.org/badge/version-for-repo/alpine_edge/onedrive.svg?header=" alt="Alpine Linux Edge package" width="46" height="20"></a>|❌|✔|❌|✔ | |
| Arch Linux<br><br>Manjaro Linux | [onedrive-abraunegg](https://aur.archlinux.org/packages/onedrive-abraunegg/) |<a href="https://aur.archlinux.org/packages/onedrive-abraunegg"><img src="https://repology.org/badge/version-for-repo/aur/onedrive-abraunegg.svg?header=" alt="AUR package" width="46" height="20"></a>|✔|✔|✔|✔ | Install via: `pamac build onedrive-abraunegg` from the Arch Linux User Repository (AUR)<br><br>**Note:** If asked regarding a provider for 'd-runtime' and 'd-compiler', select 'liblphobos' and 'ldc'<br><br>**Note:** System must have at least 1GB of memory & 1GB swap space
| Debian                          | [onedrive](https://packages.debian.org/search?keywords=onedrive)             |<a href="https://packages.debian.org/search?keywords=onedrive"><img src="https://repology.org/badge/version-for-repo/debian_11/onedrive.svg?header=" alt="Debian package" width="46" height="20"></a>|✔|✔|✔|✔| **Note:** Do not install from Debian Package Repositories<br><br>It is recommended that for Debian that you install from OpenSuSE Build Service using the Debian Package Install [Instructions](ubuntu-package-install.md) |
| Fedora                          | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)  |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/fedora_rawhide/onedrive.svg?header=" alt="Fedora Rawhide package" width="46" height="20"></a>|✔|✔|✔|✔| |
| Gentoo                          | [onedrive](https://gpo.zugaina.org/net-misc/onedrive)                        | No API Available |✔|✔|❌|❌| |
| Homebrew                        | [onedrive](https://formulae.brew.sh/formula/onedrive)                        | <a href="https://formulae.brew.sh/formula/onedrive"><img src="https://repology.org/badge/version-for-repo/homebrew/onedrive.svg?header=" alt="Homebrew package" width="46" height="20"></a> |❌|✔|❌|❌| |
| NixOS                           | [onedrive](https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive)|<a href="https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive"><img src="https://repology.org/badge/version-for-repo/nix_unstable/onedrive.svg?header=" alt="nixpkgs unstable package" width="46" height="20"></a>|❌|✔|❌|❌| Use package `onedrive` either by adding it to `configuration.nix` or by using the command `nix-env -iA <channel name>.onedrive`. This does not install a service. To install a service, use unstable channel (will stabilize in 20.09) and add `services.onedrive.enable=true` in `configuration.nix`. You can also add a custom package using the `services.onedrive.package` option (recommended since package lags upstream). Enabling the service installs a default package too (based on the channel). You can also add multiple onedrive accounts trivially, see [documentation](https://github.com/NixOS/nixpkgs/pull/77734#issuecomment-575874225). |
| OpenSuSE                        | [onedrive](https://software.opensuse.org/package/onedrive)                   |<a href="https://software.opensuse.org/package/onedrive"><img src="https://repology.org/badge/version-for-repo/opensuse_tumbleweed/onedrive.svg?header=" alt="openSUSE Tumbleweed package" width="46" height="20"></a>|✔|✔|❌|❌| |
| OpenSuSE Build Service          | [onedrive](https://build.opensuse.org/package/show/home:npreining:debian-ubuntu-onedrive/onedrive) | No API Available |✔|✔|✔|✔| Package Build Service for Debian and Ubuntu | 
| Raspbian                        | [onedrive](https://archive.raspbian.org/raspbian/pool/main/o/onedrive/)      |<a href="https://archive.raspbian.org/raspbian/pool/main/o/onedrive/"><img src="https://repology.org/badge/version-for-repo/raspbian_stable/onedrive.svg?header=" alt="Raspbian Stable package" width="46" height="20"></a> |❌|❌|✔|✔| **Note:** Do not install from Raspbian Package Repositories<br><br>It is recommended that for Raspbian that you install from OpenSuSE Build Service using the Debian Package Install [Instructions](ubuntu-package-install.md) |
| Slackware                       | [onedrive](https://slackbuilds.org/result/?search=onedrive&sv=)        |<a href="https://slackbuilds.org/result/?search=onedrive&sv="><img src="https://repology.org/badge/version-for-repo/slackbuilds/onedrive.svg?header=" alt="SlackBuilds package" width="46" height="20"></a>|✔|✔|❌|❌| |
| Solus                           | [onedrive](https://dev.getsol.us/search/query/FB7PIf1jG9Z9/#R)               |<a href="https://dev.getsol.us/search/query/FB7PIf1jG9Z9/#R"><img src="https://repology.org/badge/version-for-repo/solus/onedrive.svg?header=" alt="Solus package" width="46" height="20"></a>|✔|✔|❌|❌| |
| Ubuntu 18.04                    | [onedrive](https://packages.ubuntu.com/bionic/onedrive)                      |<a href="https://packages.ubuntu.com/bionic/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_18_04/onedrive.svg?header=" alt="Ubuntu 18.04 package" width="88" height="20"></a> |✔|✔|✔|❌| **Note:** Do not install from Ubuntu Universe<br><br>You must compile from source for this version of Ubuntu |
| Ubuntu 20.04                    | [onedrive](https://packages.ubuntu.com/focal/onedrive)                       |<a href="https://packages.ubuntu.com/focal/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Ubuntu Universe<br><br>It is recommended that for Ubuntu that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Ubuntu 21.04                    | [onedrive](https://packages.ubuntu.com/hirsute/onedrive)                     |<a href="https://packages.ubuntu.com/hirsute/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_21_04/onedrive.svg?header=" alt="Ubuntu 21.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Ubuntu Universe<br><br>It is recommended that for Ubuntu that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Ubuntu 21.10                    | [onedrive](https://packages.ubuntu.com/impish/onedrive)                      |<a href="https://packages.ubuntu.com/impish/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_21_10/onedrive.svg?header=" alt="Ubuntu 21.10 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Ubuntu Universe<br><br>It is recommended that for Ubuntu that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Ubuntu 22.04                    | [onedrive](https://packages.ubuntu.com/jammy/onedrive)                       |<a href="https://packages.ubuntu.com/jammy/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_22_04/onedrive.svg?header=" alt="Ubuntu 22.04 package" width="46" height="20"></a> |❌|✔|✔|✔| **Note:** Do not install from Ubuntu Universe<br><br>It is recommended that for Ubuntu that you install from OpenSuSE Build Service using the Ubuntu Package Install [Instructions](ubuntu-package-install.md) |
| Void Linux                      | [onedrive](https://voidlinux.org/packages/?arch=x86_64&q=onedrive)           |<a href="https://voidlinux.org/packages/?arch=x86_64&q=onedrive"><img src="https://repology.org/badge/version-for-repo/void_x86_64/onedrive.svg?header=" alt="Void Linux x86_64 package" width="46" height="20"></a>|✔|✔|❌|❌| |

#### Important information for all Ubuntu and Ubuntu based distribution users:
This information is specifically for the following platforms and distributions:
*   Ubuntu
*   Lubuntu
*   Linux Mint
*   POP OS
*   Peppermint OS

Whilst there are [onedrive](https://packages.ubuntu.com/search?keywords=onedrive&searchon=names&suite=all&section=all) Universe packages available for Ubuntu, do not install 'onedrive' from these Universe packages. The default Universe packages are out-of-date and are not supported and should not be used. If you wish to use a package, it is highly recommended that you utilise the [OpenSuSE Build Service](ubuntu-package-install.md) to install packages for these platforms. If the OpenSuSE Build Service does not cater for your version, your only option is to build from source.

If you wish to change this situation so that you can just use the Universe packages via 'apt install onedrive', consider becoming the Ubuntu package maintainer and contribute back to your community.

## Building from Source - High Level Requirements
*   Build environment must have at least 1GB of memory & 1GB swap space
*   Install the required distribution package dependencies
*   [libcurl](http://curl.haxx.se/libcurl/)
*   [SQLite 3](https://www.sqlite.org/) >= 3.7.15
*   [Digital Mars D Compiler (DMD)](http://dlang.org/download.html) or [LDC – the LLVM-based D Compiler](https://github.com/ldc-developers/ldc)

**Note:** DMD version >= 2.088.0 or LDC version >= 1.18.0 is required to compile this application

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
Ubuntu Linux 16.04 LTS reached the end of its five-year LTS window on April 30th 2021 and is no longer supported.

### Dependencies: Ubuntu 18.x / Lubuntu 18.x / Debian 9 - i386 / i686
These dependencies are also applicable for all Ubuntu based distributions such as:
*   Lubuntu
*   Linux Mint
*   POP OS
*   Peppermint OS

**Important:** The DMD compiler cannot be used in its default configuration on Ubuntu 18.x / Lubuntu 18.x / Debian 9 i386 / i686 architectures due to an issue in the Ubuntu / Debian linking process. See [https://issues.dlang.org/show_bug.cgi?id=19116](https://issues.dlang.org/show_bug.cgi?id=19116) for further details.

**Note:** Ubuntu 18.x validated with the DMD compiler on the following Ubuntu i386 / i686 platform:
```text
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=18.04
DISTRIB_CODENAME=bionic
DISTRIB_DESCRIPTION="Ubuntu 18.04.3 LTS"
```
**Note:** Lubuntu 18.x validated with the DMD compiler on the following Lubuntu i386 / i686 platform:
```text
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=18.10
DISTRIB_CODENAME=cosmic
DISTRIB_DESCRIPTION="Ubuntu 18.10"
```
**Note:** Debian 9 validated with the DMD compiler on the following Debian i386 / i686 platform:
```text
cat /etc/debian_version 
9.11
```

First install development dependencies as per below:
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo apt install pkg-config
sudo apt install git
sudo apt install curl
```
For notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```
Second, install the DMD compiler as per below:
```text
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
Thirdly, reconfigure the default linker as per below:
```text
sudo update-alternatives --install "/usr/bin/ld" "ld" "/usr/bin/ld.gold" 20
sudo update-alternatives --install "/usr/bin/ld" "ld" "/usr/bin/ld.bfd" 10
```

### Dependencies: Ubuntu 18.x -> Ubuntu 22.x / Debian 9 -> Debian 11 - x86_64
These dependencies are also applicable for all Ubuntu based distributions such as:
*   Lubuntu
*   Linux Mint
*   POP OS
*   Peppermint OS
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo apt install pkg-config
sudo apt install git
sudo apt install curl
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: CentOS 6.x / RHEL 6.x
CentOS 6.x and RHEL 6.x reached End of Life status on November 30th 2020 and is no longer supported.

### Dependencies: Fedora < Version 18 / CentOS 7.x / RHEL 7.x
```text
sudo yum groupinstall 'Development Tools'
sudo yum install libcurl-devel
sudo yum install sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd-2.099.0
```
For notifications the following is also necessary:
```text
sudo yum install libnotify-devel
```

### Dependencies: Fedora > Version 18 / CentOS 8.x / RHEL 8.x / RHEL 9.x
```text
sudo dnf groupinstall 'Development Tools'
sudo dnf install libcurl-devel
sudo dnf install sqlite-devel
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

### Dependencies: Raspbian (ARMHF) and Ubuntu 22.x / Debian 11 / Raspbian (ARM64)
**Note:** The minimum LDC compiler version required to compile this application is now 1.18.0, which is not available for Debian Buster or distributions based on Debian Buster. You are advised to first upgrade your platform distribution to one that is based on Debian Bullseye (Debian 11) or later.

These instructions were validated using:
*   `Linux raspberrypi 5.10.92-v8+ #1514 SMP PREEMPT Mon Jan 17 17:39:38 GMT 2022 aarch64` (2022-01-28-raspios-bullseye-armhf-lite) using Raspberry Pi 3B (revision 1.2)
*   `Linux raspberrypi 5.10.92-v8+ #1514 SMP PREEMPT Mon Jan 17 17:39:38 GMT 2022 aarch64` (2022-01-28-raspios-bullseye-arm64-lite) using Raspberry Pi 3B (revision 1.2)
*   `Linux ubuntu 5.15.0-1005-raspi #5-Ubuntu SMP PREEMPT Mon Apr 4 12:21:48 UTC 2022 aarch64 aarch64 aarch64 GNU/Linux` (ubuntu-22.04-preinstalled-server-arm64+raspi) using Raspberry Pi 3B (revision 1.2)

**Note:** Build environment must have at least 1GB of memory & 1GB swap space. Check with `swapon`.

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
1.  Install the platform dependancies for your Linux OS
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

**Note:** Depending on your DMD version, substitute `2.088.0` above with your DMD version that is installed.

```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure
make clean; make;
sudo make install
```

### Build options
Notifications can be enabled using the `configure` switch `--enable-notifications`.

Systemd service files are installed in the appropriate directories on the system,
as provided by `pkg-config systemd` settings. If the need for overriding the
deduced path are necessary, the two options `--with-systemdsystemunitdir` (for
the Systemd system unit location), and `--with-systemduserunitdir` (for the
Systemd user unit location) can be specified. Passing in `no` to one of these
options disabled service file installation.

By passing `--enable-debug` to the `configure` call, `onedrive` gets built with additional debug
information, useful (for example) to get `perf`-issued figures.

By passing `--enable-completions` to the `configure` call, shell completion functions are
installed for `bash`, `zsh` and `fish`. The installation directories are determined
as far as possible automatically, but can be overridden by passing
`--with-bash-completion-dir=<DIR>`, `--with-zsh-completion-dir=<DIR>`, and
`--with-fish-completion-dir=<DIR>` to `configure`.

### Building using a different compiler (for example [LDC](https://wiki.dlang.org/LDC))
#### ARMHF Architecture (Raspbian) and ARM64 Architecture (Ubuntu 22.x / Debian 11 / Raspbian)
**Note:** The minimum LDC compiler version required to compile this application is now 1.18.0, which is not available for Debian Buster or distributions based on Debian Buster. You are advised to first upgrade your platform distribution to one that is based on Debian Bullseye (Debian 11) or later.

**Note:** Build environment must have at least 1GB of memory & 1GB swap space. Check with `swapon`.
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure DC=/usr/bin/ldmd2
make clean; make
sudo make install
```

## Upgrading the client
If you have installed the client from a distribution package, the client will be updated when the distribution package is updated by the package maintainer and will be updated to the new application version when you perform your package update.

If you have built the client from source, to upgrade your client, you must first uninstall your existing 'onedrive' binary (see below), then re-install the client by re-cloning, re-compiling and re-installing the client again to install the new version.

To confirm you have the new version installed, use `onedrive --version` to determine the version that is now installed.

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
**Note:** If you are using the `--confdir option`, substitute `~/.config/onedrive` for the correct directory storing your client configuration.

If you want to just delete the application key, but keep the items database:
```text
rm -f ~/.config/onedrive/refresh_token
```