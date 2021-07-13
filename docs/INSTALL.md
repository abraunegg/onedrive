# Installing from Distribution Packages or Building the OneDrive Client for Linux from source

## Installing from Distribution Packages
This project has been packaged for the following Linux distributions as per below. The current client release is: [![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)

Only the current release version or greater is supported.

#### Important Note:
Distribution packages may be of an older release when compared to the latest release that is [available](https://github.com/abraunegg/onedrive/releases). If a package is out of date, please contact the package maintainer for resolution.

| Distribution                    | Package Name & Package Link                                                  | &nbsp;&nbsp;PKG_Version&nbsp;&nbsp; | &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 | Extra Details                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
|---------------------------------|------------------------------------------------------------------------------|:---------------:|:----:|:------:|:-----:|:-------:|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Alpine Linux                    | [onedrive](https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge)  |<a href="https://pkgs.alpinelinux.org/packages?name=onedrive&branch=edge"><img src="https://repology.org/badge/version-for-repo/alpine_edge/onedrive.svg?header=" alt="Alpine Linux Edge package" width="46" height="20"></a>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/> | |
| Arch Linux<br><br>Manjaro Linux | [onedrive-abraunegg](https://aur.archlinux.org/packages/onedrive-abraunegg/) |<a href="https://aur.archlinux.org/packages/onedrive-abraunegg"><img src="https://repology.org/badge/version-for-repo/aur/onedrive-abraunegg.svg?header=" alt="AUR package" width="46" height="20"></a>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/> | Install via: `pamac build onedrive-abraunegg` from the Arch Linux User Repository (AUR)<br><br>**Note:** If asked regarding a provider for 'd-runtime' and 'd-compiler', select 'liblphobos' and 'ldc'<br><br>**Note:** System must have at least 1GB of memory & 1GB swap space
| Debian                          | [onedrive](https://packages.debian.org/search?keywords=onedrive)             |<a href="https://packages.debian.org/search?keywords=onedrive"><img src="https://repology.org/badge/version-for-repo/debian_testing/onedrive.svg?header=" alt="Debian Testing package" width="46" height="20"></a>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>| |
| Fedora                          | [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)  |<a href="https://koji.fedoraproject.org/koji/packageinfo?packageID=26044"><img src="https://repology.org/badge/version-for-repo/fedora_rawhide/onedrive.svg?header=" alt="Fedora Rawhide package" width="46" height="20"></a>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>| |
| Gentoo                          | [onedrive](https://gpo.zugaina.org/net-misc/onedrive)                        | No API Available |<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| |
| NixOS                           | [onedrive](https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive)|<a href="https://search.nixos.org/packages?channel=20.09&from=0&size=50&sort=relevance&query=onedrive"><img src="https://repology.org/badge/version-for-repo/nix_unstable/onedrive.svg?header=" alt="nixpkgs unstable package" width="46" height="20"></a>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| Use package `onedrive` either by adding it to `configuration.nix` or by using the command `nix-env -iA <channel name>.onedrive`. This does not install a service. To install a service, use unstable channel (will stabilize in 20.09) and add `services.onedrive.enable=true` in `configuration.nix`. You can also add a custom package using the `services.onedrive.package` option (recommended since package lags upstream). Enabling the service installs a default package too (based on the channel). You can also add multiple onedrive accounts trivially, see [documentation](https://github.com/NixOS/nixpkgs/pull/77734#issuecomment-575874225). |
| openSUSE                        | [onedrive](https://software.opensuse.org/package/onedrive)                   |<a href="https://software.opensuse.org/package/onedrive"><img src="https://repology.org/badge/version-for-repo/opensuse_tumbleweed/onedrive.svg?header=" alt="openSUSE Tumbleweed package" width="46" height="20"></a>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| |
| Raspbian                        | [onedrive](https://archive.raspbian.org/raspbian/pool/main/o/onedrive/)      |<a href="https://archive.raspbian.org/raspbian/pool/main/o/onedrive/"><img src="https://repology.org/badge/version-for-repo/raspbian_stable/onedrive.svg?header=" alt="Raspbian Stable package" width="46" height="20"></a>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| |
| Slackware                       | [onedrive](https://slackbuilds.org/repository/14.2/network/onedrive/)        |<a href="https://slackbuilds.org/repository/14.2/network/onedrive/"><img src="https://repology.org/badge/version-for-repo/slackbuilds/onedrive.svg?header=" alt="SlackBuilds package" width="46" height="20"></a>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| |
| Solus                           | [onedrive](https://dev.getsol.us/search/query/FB7PIf1jG9Z9/#R)               |<a href="https://dev.getsol.us/search/query/FB7PIf1jG9Z9/#R"><img src="https://repology.org/badge/version-for-repo/solus/onedrive.svg?header=" alt="Solus package" width="46" height="20"></a>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| |
| Ubuntu 18.04                    | [onedrive](https://packages.ubuntu.com/bionic/onedrive)                      |<a href="https://packages.ubuntu.com/bionic/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_18_04/onedrive.svg?header=" alt="Ubuntu 18.04 package" width="88" height="20"></a>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| |
| Ubuntu 20.04                    | [onedrive](https://packages.ubuntu.com/focal/onedrive)                       |<a href="https://packages.ubuntu.com/focal/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_04/onedrive.svg?header=" alt="Ubuntu 20.04 package" width="46" height="20"></a>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>| |
| Ubuntu 20.10                    | [onedrive](https://packages.ubuntu.com/groovy/onedrive)                      |<a href="https://packages.ubuntu.com/groovy/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_20_10/onedrive.svg?header=" alt="Ubuntu 20.10 package" width="46" height="20"></a>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>| |
| Ubuntu 21.04                    | [onedrive](https://packages.ubuntu.com/hirsute/onedrive)                     |<a href="https://packages.ubuntu.com/hirsute/onedrive"><img src="https://repology.org/badge/version-for-repo/ubuntu_21_04/onedrive.svg?header=" alt="Ubuntu 21.04 package" width="46" height="20"></a>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>| |
| Ubuntu PPA                      | [onedrive](https://launchpad.net/~yann1ck/+archive/ubuntu/onedrive)          |<a href="https://launchpad.net/~yann1ck/+archive/ubuntu/onedrive"><img src="https://repology.org/badge/version-for-repo/debian_testing/onedrive.svg?header=" alt="Ubuntu PPA package" width="46" height="20"></a> |<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| Install via the Ubuntu PPA Archive:<br><br>`sudo add-apt-repository ppa:yann1ck/onedrive`<br>`sudo apt-get update`<br>`sudo apt install onedrive`|
| Void Linux                      | [onedrive](https://voidlinux.org/packages/)                                  |<a href="https://voidlinux.org/packages/"><img src="https://repology.org/badge/version-for-repo/void_x86_64/onedrive.svg?header=" alt="Void Linux x86_64 package" width="46" height="20"></a>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/tick.gif" alt="supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>|<img src="./images/cross.gif" alt="not_supported" width="39" height="39"/>| |

#### Important information for all Ubuntu and Ubuntu based distribution users:
This information is specifically for the following platforms and distributions:
*   Ubuntu
*   Lubuntu
*   Linux Mint
*   POP OS
*   Peppermint OS

Whilst there are [onedrive](https://packages.ubuntu.com/search?keywords=onedrive&searchon=names&suite=all&section=all) packages available for Ubuntu, do not install 'onedrive' from these packages via `apt install onedrive` without using the above PPA. The default Ubuntu Universe packages are out-of-date and should not be used. If you wish to use a package, it is highly recommended that you utilise the Ubuntu PPA listed above. If the Ubuntu PPA does not support your distribution or version, your only option is to compile from source using the relevant Ubuntu instructions below.

If you wish to change this situation so that you can just use 'apt install onedrive', consider becoming the Ubuntu package maintainer and contribute back to the community.

## Building from Source - High Level Requirements
*   Build environment must have at least 1GB of memory & 1GB swap space
*   Install the required distribution package dependencies
*   [libcurl](http://curl.haxx.se/libcurl/)
*   [SQLite 3](https://www.sqlite.org/) >= 3.7.15
*   [Digital Mars D Compiler (DMD)](http://dlang.org/download.html) or [LDC – the LLVM-based D Compiler](https://github.com/ldc-developers/ldc)

**Note:** DMD version >= 2.083.1 or LDC version >= 1.12.0 is required to compile this application

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

### Dependencies: Ubuntu 18.x, Ubuntu 19.x, Ubuntu 20.x / Debian 9, Debian 10 - x86_64
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
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is also necessary:
```text
sudo yum install libnotify-devel
```

### Dependencies: Fedora > Version 18 / CentOS 8.x / RHEL 8.x
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

### Dependencies: Raspbian (ARMHF)
Validated using:
*   `Linux raspberrypi 5.4.79-v7+ #1373 SMP Mon Nov 23 13:22:33 GMT 2020 armv7l GNU/Linux` (2020-12-02-raspios-buster-armhf) using Raspberry Pi 2 Model B
*   `Linux raspberrypi 5.4.83-v8+ #1379 SMP PREEMPT Mon Dec 14 13:15:14 GMT 2020 aarch64` (2021-01-11-raspios-buster-armhf) using Raspberry Pi 3 Model B+

**Note:** Build environment must have at least 1GB of memory & 1GB swap space. Check with `swapon`.

```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo apt install pkg-config
sudo apt install git
sudo apt install curl
wget https://github.com/ldc-developers/ldc/releases/download/v1.17.0/ldc2-1.17.0-linux-armhf.tar.xz
tar -xvf ldc2-1.17.0-linux-armhf.tar.xz
```
For notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Ubuntu 20.x / Debian 10 (ARM64)
Validated using:
*   `Ubuntu 20.04.2 LTS (GNU/Linux 5.4.0-1028-raspi aarch64)` (ubuntu-20.04.2-preinstalled-server-arm64+raspi) using Raspberry Pi 3 Model B+

**Note:** Build environment must have at least 1GB of memory & 1GB swap space. Check with `swapon`.

```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo apt install pkg-config
sudo apt install git
sudo apt install curl
wget https://github.com/ldc-developers/ldc/releases/download/v1.25.1/ldc2-1.25.1-linux-aarch64.tar.xz
tar -xvf ldc2-1.25.1-linux-aarch64.tar.xz
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
Run `source ~/dlang/dmd-2.081.1/activate` in your shell to use dmd-2.081.1.
This will setup PATH, LIBRARY_PATH, LD_LIBRARY_PATH, DMD, DC, and PS1.
Run `deactivate` later on to restore your environment.
```
Without performing this step, the compilation process will fail.

**Note:** Depending on your DMD version, substitute `2.081.1` above with your DMD version that is installed.

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
#### ARMHF Architecture (Raspbian etc)
**Note:** Build environment must have at least 1GB of memory & 1GB swap space. Check with `swapon`.
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure DC=~/ldc2-1.17.0-linux-armhf/bin/ldmd2
make clean; make
sudo make install
```

#### ARM64 Architecture
**Note:** Build environment must have at least 1GB of memory & 1GB swap space. Check with `swapon`
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure DC=~/ldc2-1.25.1-linux-aarch64/bin/ldmd2
make clean; make
sudo make install
```

## Uninstall
```text
sudo make uninstall
# delete the application state
rm -rf ~/.config/onedrive
```
If you are using the `--confdir option`, substitute `~/.config/onedrive` above for that directory.

If you want to just delete the application key, but keep the items database:
```text
rm -f ~/.config/onedrive/refresh_token
```
