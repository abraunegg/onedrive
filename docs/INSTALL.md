# Building and Installing the OneDrive Free Client
## Build Requirements
*   Build environment must have at least 1GB of memory & 1GB swap space
*   [libcurl](http://curl.haxx.se/libcurl/)
*   [SQLite 3](https://www.sqlite.org/) >= 3.7.15
*   [Digital Mars D Compiler (DMD)](http://dlang.org/download.html)

**Note:** DMD version >= 2.083.1 or LDC version >= 1.12.0 is required to compile this application

### Dependencies: Ubuntu/Debian - x86_64
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo apt install pkg-config
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Ubuntu - i386 / i686
**Note:** Validated with `Linux ubuntu-i386-vm 4.13.0-36-generic #40~16.04.1-Ubuntu SMP Fri Feb 16 23:26:51 UTC 2018 i686 i686 i686 GNU/Linux` and DMD 2.081.1
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo apt install pkg-config
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Debian - i386 / i686
**Note:** Validated with `Linux debian-i386 4.9.0-8-686-pae #1 SMP Debian 4.9.130-2 (2018-10-27) i686 GNU/Linux` and LDC - the LLVM D compiler (1.12.0).

First install development dependencies as per below:
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo apt install pkg-config
sudo apt install git
```
Second, install the LDC compiler as per below:
```text
mkdir ldc && cd ldc
wget http://httpredir.debian.org/debian/pool/main/g/gcc-8/gcc-8-base_8.2.0-19_i386.deb
wget http://httpredir.debian.org/debian/pool/main/g/gcc-8/libgcc1_8.2.0-19_i386.deb
wget http://httpredir.debian.org/debian/pool/main/l/ldc/libphobos2-ldc-shared82_1.12.0-1_i386.deb
wget http://httpredir.debian.org/debian/pool/main/l/ldc/libphobos2-ldc-shared-dev_1.12.0-1_i386.deb
wget http://httpredir.debian.org/debian/pool/main/l/ldc/ldc_1.12.0-1_i386.deb
wget http://httpredir.debian.org/debian/pool/main/l/llvm-toolchain-6.0/libllvm6.0_6.0.1-10_i386.deb
wget http://httpredir.debian.org/debian/pool/main/n/ncurses/libtinfo6_6.1+20181013-1_i386.deb
sudo dpkg -i ./*.deb
```
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Fedora < Version 18 / CentOS / RHEL
```text
sudo yum groupinstall 'Development Tools'
sudo yum install libcurl-devel
sudo yum install sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is necessary:
```text
sudo yum install libnotify-devel
```

### Dependencies: CentOS 6.x / RHEL 6.x
In addition to the above requirements, the `sqlite` version used on CentOS 6.x / RHEL 6.x needs to be upgraded. Use the following instructions to update your version of `sqlite` so that it can support the client:
```text
sudo yum -y update
sudo yum -y install epel-release wget
sudo yum -y install mock
wget https://kojipkgs.fedoraproject.org//packages/sqlite/3.7.15.2/2.fc19/src/sqlite-3.7.15.2-2.fc19.src.rpm
mock --rebuild sqlite-3.7.15.2-2.fc19.src.rpm
sudo yum -y upgrade /var/lib/mock/epel-6-`arch`/result/sqlite-*
```

### Dependencies: Fedora > Version 18
```text
sudo dnf groupinstall 'Development Tools'
sudo dnf install libcurl-devel
sudo dnf install sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is necessary:
```text
sudo dnf install libnotify-devel
```

### Dependencies: Arch Linux
```text
sudo pacman -S curl sqlite dmd
```
For notifications the following is necessary:
```text
sudo pacman -S libnotify
```

### Dependencies: Raspbian (ARMHF)
```text
sudo apt-get install libcurl4-openssl-dev
sudo apt-get install libsqlite3-dev
sudo apt-get install libxml2
sudo apt-get install pkg-config
wget https://github.com/ldc-developers/ldc/releases/download/v1.16.0/ldc2-1.16.0-linux-armhf.tar.xz
tar -xvf ldc2-1.16.0-linux-armhf.tar.xz
```
For notifications the following is necessary:
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
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Gentoo
```text
sudo emerge app-portage/layman
sudo layman -a dlang
```
Add ebuild from contrib/gentoo to a local overlay to use.

For notifications the following is necessary:
```text
sudo emerge x11-libs/libnotify
```

### Dependencies: OpenSuSE Leap 15.0
```text
sudo zypper addrepo --check --refresh --name "D" http://download.opensuse.org/repositories/devel:/languages:/D/openSUSE_Leap_15.0/devel:languages:D.repo
sudo zypper install git libcurl-devel sqlite3-devel D:dmd D:libphobos2-0_81 D:phobos-devel D:phobos-devel-static
```
For notifications the following is necessary:
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
installed for `bash` and `zsh`. The installation directories are determined
as far as possible automatically, but can be overridden by passing
`--with-bash-completion-dir=<DIR>` and 
`--with-zsh-completion-dir=<DIR>` to `configure`.

### Building using a different compiler (for example [LDC](https://wiki.dlang.org/LDC))
#### Debian - i386 / i686
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure DC=ldc2
make clean; make
sudo make install
```

#### ARMHF Architecture
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure DC=~/ldc2-1.13.0-linux-armhf/bin/ldmd2
make clean; make
sudo make install
```

#### ARM64 Architecture
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
./configure DC=~/ldc2-1.14.0-linux-aarch64/bin/ldmd2
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


