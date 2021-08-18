# Building from Source

## High Level Requirements

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
sudo apt install build-essential libcurl4-openssl-dev libsqlite3-dev pkg-config git curl
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

## Uninstalling the client
From within your GitHub repository clone, perform the following to remove the 'onedrive' binary:
```text
sudo make uninstall
```

If you are not upgrading your client, to remove your application state and configuration, perform the following additional step:
```
rm -rf ~/.config/onedrive
```
**Note:** If you are using the `--confdir option`, substitute `~/.config/onedrive` above for that directory.

If you want to just delete the application key, but keep the items database:
```text
rm -f ~/.config/onedrive/refresh_token
```

## Upgrading the client

If you have installed the client from a distribution package, the package maintainer will, hopefully, update the package so you can upgrade with it.

If you have built the client from source, to upgrade your client, you must first uninstall your existing 'onedrive' binary (see above), then re-install the client by re-cloning, re-compiling and re-installing the client again to install the new version.

To confirm you have the new version installed, use `onedrive --version` to determine the version installed.

