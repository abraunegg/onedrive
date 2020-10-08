# Building and Installing the OneDrive Free Client

## Linux Packages
This project has been packaged for the following Linux distributions:

*   Arch Linux, available from AUR as [onedrive-abraunegg](https://aur.archlinux.org/packages/onedrive-abraunegg/)
*   Debian, available from the package repository as [onedrive](https://packages.debian.org/sid/net/onedrive)
*   Fedora, available via package repositories as [onedrive](https://koji.fedoraproject.org/koji/packageinfo?packageID=26044)
*   Gentoo, available via portage overlay as [onedrive](https://gpo.zugaina.org/net-misc/onedrive)
*   NixOS, use package `onedrive` either by adding it to `configuration.nix` or by using the command `nix-env -iA <channel name>.onedrive`. This does not install a service. To install a service, use unstable channel (will stabilize in 20.09) and add `services.onedrive.enable=true` in `configuration.nix`. You can also add a custom package using the `services.onedrive.package` option (recommended since package lags upstream). Enabling the service installs a default package too (based on the channel). You can also add multiple onedrive accounts trivially, see [documentation](https://github.com/NixOS/nixpkgs/pull/77734#issuecomment-575874225)`.
*   openSUSE, available for Tumbleweed, Leap 15.2, Leap 15.1 as [onedrive](https://software.opensuse.org/package/onedrive) 
*   Slackware, available from the slackbuilds.org repository as [onedrive](https://slackbuilds.org/repository/14.2/network/onedrive/)
*   Solus, available from the package repository as [onedrive](https://dev.getsol.us/search/query/FB7PIf1jG9Z9/#R)
*   Ubuntu, available as a package from the following PPA [onedrive](https://launchpad.net/~yann1ck/+archive/ubuntu/onedrive)

#### Important Note:
Distribution packages may be of an older release when compared to the latest release that is [available](https://github.com/abraunegg/onedrive/releases). If a package is out of date, please contact the package maintainer for resolution.

#### Important information for all Ubuntu and Ubuntu based distribution users:
This information is specifically for the following platforms and distributions:
*   Ubuntu
*   Lubuntu
*   Linux Mint
*   POP OS
*   Peppermint OS

Whilst there are [onedrive](https://packages.ubuntu.com/search?keywords=onedrive&searchon=names&suite=all&section=all) packages available for Ubuntu, do not install 'onedrive' from these packages via `apt install onedrive`. These packages are out-of-date and should not be used. If you wish to use a package, it is highly recommended that you utilise the Ubuntu PPA listed above. If the Ubuntu PPA does not support your distribution or version, your only option is to compile from source using the relevant Ubuntu instructions below.

If you wish to change this situation so that you can just use 'apt install onedrive', consider becoming the Ubuntu package maintainer and contribute back to the community.

## Build Requirements
*   Build environment must have at least 1GB of memory & 1GB swap space
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
### Dependencies: Ubuntu 16.x - i386 / i686 (less than 1GB Memory) 
**Important:** Build environment must have at least 512 of memory & 1GB swap space

**Important:** Only use this method if you have <1GB of physical memory.

**Note:** Peppermint 7 validated with the DMD compiler on the following i386 / i686 platform:
```text
DISTRIB_ID=Peppermint
DISTRIB_RELEASE=7
DISTRIB_CODENAME=xenial
DISTRIB_DESCRIPTION="Peppermint 7 Seven"
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
sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
sudo apt-get update && sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring
sudo apt-get update && sudo apt-get install dmd-compiler dub
```

### Dependencies: Ubuntu 16.x - i386 / i686 / x86_64 (1GB Memory or more)
**Note:** Ubuntu 16.x validated with the DMD compiler on the following Ubuntu i386 / i686 platform:
```text
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=16.04
DISTRIB_CODENAME=xenial
DISTRIB_DESCRIPTION="Ubuntu 16.04.6 LTS"
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
In addition to the above requirements, the `sqlite` version used on CentOS 6.x / RHEL 6.x needs to be upgraded. Use the following instructions to update your version of `sqlite` so that it can support this client:
```text
sudo yum -y update
sudo yum -y install epel-release wget
sudo yum -y install mock
wget https://kojipkgs.fedoraproject.org//packages/sqlite/3.7.15.2/2.fc19/src/sqlite-3.7.15.2-2.fc19.src.rpm
mock --rebuild sqlite-3.7.15.2-2.fc19.src.rpm
sudo yum -y upgrade /var/lib/mock/epel-6-`arch`/result/sqlite-*
```

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

### Dependencies: Arch Linux
```text
sudo pacman -S curl sqlite dmd
```
For notifications the following is also necessary:
```text
sudo pacman -S libnotify
```

### Dependencies: Raspbian (ARMHF)
**Note:** Build environment must have at least 1GB of memory & 1GB swap space. Check with `swapon`.
```text
sudo apt-get install libcurl4-openssl-dev
sudo apt-get install libsqlite3-dev
sudo apt-get install libxml2
sudo apt-get install pkg-config
wget https://github.com/ldc-developers/ldc/releases/download/v1.16.0/ldc2-1.16.0-linux-armhf.tar.xz
tar -xvf ldc2-1.16.0-linux-armhf.tar.xz
```
For notifications the following is also necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Debian (ARM64)
```text
sudo apt-get install libcurl4-openssl-dev
sudo apt-get install libsqlite3-dev
sudo apt-get install libxml2
sudo apt-get install pkg-config
wget https://github.com/ldc-developers/ldc/releases/download/v1.16.0/ldc2-1.16.0-linux-aarch64.tar.xz
tar -xvf ldc2-1.16.0-linux-aarch64.tar.xz
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
sudo zypper addrepo --check --refresh --name "D" http://download.opensuse.org/repositories/devel:/languages:/D/openSUSE_Leap_15.0/devel:languages:D.repo
sudo zypper install git libcurl-devel sqlite3-devel D:dmd D:libphobos2-0_81 D:phobos-devel D:phobos-devel-static
```
For notifications the following is also necessary:
```text
sudo zypper install libnotify-devel
```

## Compilation & Installation
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
./configure DC=~/ldc2-1.16.0-linux-armhf/bin/ldmd2
make clean; make
sudo make install
```

#### ARM64 Architecture
**Note:** Build environment must have at least 1GB of memory & 1GB swap space. Check with `swapon`
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure DC=~/ldc2-1.16.0-linux-aarch64/bin/ldmd2
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
