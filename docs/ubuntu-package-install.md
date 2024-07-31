# Installation of 'onedrive' package on Debian and Ubuntu

This document outlines the steps for installing the 'onedrive' client on Debian, Ubuntu, and their derivatives using the OpenSuSE Build Service Packages.

> [!CAUTION]
> This information is specifically for the following platforms and distributions:
> * Debian
> * Deepin
> * Elementary OS
> * Kali Linux
> * Lubuntu
> * Linux Mint
> * Pop!_OS
> * Peppermint OS
> * Raspbian | Raspberry Pi OS
> * Ubuntu | Kubuntu | Xubuntu | Ubuntu Mate
> * Zorin OS
>
> Although packages for the 'onedrive' client are available through distribution repositories, it is strongly advised against installing them. These distribution-provided packages are outdated, unsupported, and contain bugs and issues that have already been resolved in newer versions. They should not be used.

## Determine which instructions to use
Ubuntu and its clones are based on various different releases, thus, you must use the correct instructions below, otherwise you may run into package dependency issues and will be unable to install the client.

### Step 1: Remove any configured PPA and associated 'onedrive' package and systemd service files

#### Step 1a: Remove PPA if configured
Many Internet 'help' pages provide inconsistent details on how to install the OneDrive Client for Linux. A number of these websites continue to point users to install the client via the yann1ck PPA repository however this PPA no longer exists and should not be used. If you have previously configured, or attempted to add this PPA, this needs to be removed.

To remove the PPA repository and the older client, perform the following actions:
```text
sudo apt remove onedrive
sudo add-apt-repository --remove ppa:yann1ck/onedrive
```

#### Step 1b: Remove errant systemd service file installed by PPA or distribution package

Additionally, the distributon packages have a bad habit of creating a 'default' systemd service file when installing the 'onedrive' package so that the client will automatically run the client post being authenticated:
```
Created symlink /etc/systemd/user/default.target.wants/onedrive.service → /usr/lib/systemd/user/onedrive.service.
```
This systemd entry is erroneous and needs to be removed. Without removing this erroneous systemd link, this increases your risk of getting the following error message:
```
Opening the item database ...

ERROR: onedrive application is already running - check system process list for active application instances
 - Use 'sudo ps aufxw | grep onedrive' to potentially determine acive running process
```

To remove this symbolic link, run the following command:
```
sudo rm /etc/systemd/user/default.target.wants/onedrive.service
```

### Step 2: Ensure your system is up-to-date
Use a script, similar to the following to ensure your system is updated correctly:
```text
#!/bin/bash
rm -rf /var/lib/dpkg/lock-frontend
rm -rf /var/lib/dpkg/lock
apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get autoclean -y
```

Run this script as 'root' by using `su -` to elevate to 'root'. Example below:
```text
Welcome to Ubuntu 20.04.1 LTS (GNU/Linux 5.4.0-48-generic x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/advantage

425 updates can be installed immediately.
208 of these updates are security updates.
To see these additional updates run: apt list --upgradable

Your Hardware Enablement Stack (HWE) is supported until April 2025.
Last login: Thu Jan 20 14:21:48 2022 from my.ip.address
alex@ubuntu-20-LTS:~$ su -
Password: 
root@ubuntu-20-LTS:~# ls -la
total 28
drwx------  3 root root 4096 Oct 10  2020 .
drwxr-xr-x 20 root root 4096 Oct 10  2020 ..
-rw-------  1 root root  175 Jan 20 14:23 .bash_history
-rw-r--r--  1 root root 3106 Dec  6  2019 .bashrc
drwx------  2 root root 4096 Apr 23  2020 .cache
-rw-r--r--  1 root root  161 Dec  6  2019 .profile
-rwxr-xr-x  1 root root  174 Oct 10  2020 update-os.sh
root@ubuntu-20-LTS:~# cat update-os.sh 
#!/bin/bash
rm -rf /var/lib/dpkg/lock-frontend
rm -rf /var/lib/dpkg/lock
apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get autoclean -y
root@ubuntu-20-LTS:~# ./update-os.sh 
Hit:1 http://au.archive.ubuntu.com/ubuntu focal InRelease
Hit:2 http://au.archive.ubuntu.com/ubuntu focal-updates InRelease
Hit:3 http://au.archive.ubuntu.com/ubuntu focal-backports InRelease
Hit:4 http://security.ubuntu.com/ubuntu focal-security InRelease
Reading package lists... 96%
...
Sourcing file `/etc/default/grub'
Sourcing file `/etc/default/grub.d/init-select.cfg'
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-5.13.0-27-generic
Found initrd image: /boot/initrd.img-5.13.0-27-generic
Found linux image: /boot/vmlinuz-5.4.0-48-generic
Found initrd image: /boot/initrd.img-5.4.0-48-generic
Found memtest86+ image: /boot/memtest86+.elf
Found memtest86+ image: /boot/memtest86+.bin
done
Removing linux-modules-5.4.0-26-generic (5.4.0-26.30) ...
Processing triggers for libc-bin (2.31-0ubuntu9.2) ...
Reading package lists... Done
Building dependency tree       
Reading state information... Done
root@ubuntu-20-LTS:~#
```

Reboot your system after running this process before continuing with Step 3.
```text
reboot
```

### Step 3: Determine what your OS is based on
Determine what your OS is based on. To do this, run the following command:
```text
lsb_release -a
```
**Example:**
```text
alex@ubuntu-system:~$ lsb_release -a
No LSB modules are available.
Distributor ID: Ubuntu
Description:    Ubuntu 22.04 LTS
Release:        22.04
Codename:       jammy
```

### Step 4: Pick the correct instructions to use
If required, review the table below based on your 'lsb_release' information to pick the appropriate instructions to use:

| Release & Codename | Instructions to use |
|--------------------|---------------------|
| Linux Mint 19.x           | This platform is End-of-Life (EOL) and no longer supported. You must upgrade to Linux Mint 21.x |
| Linux Mint 20.x           | Use [Ubuntu 20.04](#distribution-ubuntu-2004) instructions below |
| Linux Mint 21.x           | Use [Ubuntu 22.04](#distribution-ubuntu-2204) instructions below |
| Linux Mint Debian Edition (LMDE) 5 / Elsie | Use [Debian 11](#distribution-debian-11) instructions below |
| Linux Mint Debian Edition (LMDE) 6 / Faye  | Use [Debian 12](#distribution-debian-12) instructions below |
| Debian 9                  | This platform is End-of-Life (EOL) and no longer supported. You must upgrade to Debian 12 |
| Debian 10                 | You must build from source or upgrade your Operating System to Debian 12 |
| Debian 11                 | Use [Debian 11](#distribution-debian-11) instructions below |
| Debian 12                 | Use [Debian 12](#distribution-debian-12) instructions below |
| Debian Sid                | Refer to https://packages.debian.org/sid/onedrive for assistance |
| Raspbian GNU/Linux 10     | You must build from source or upgrade your Operating System to Raspbian GNU/Linux 12 |
| Raspbian GNU/Linux 11     | Use [Debian 11](#distribution-debian-11) instructions below |
| Raspbian GNU/Linux 12     | Use [Debian 12](#distribution-debian-12) instructions below |
| Ubuntu 18.04 / Bionic     | This platform is End-of-Life (EOL) and no longer supported. You must upgrade to Ubuntu 22.04 |
| Ubuntu 20.04 / Focal      | Use [Ubuntu 20.04](#distribution-ubuntu-2004) instructions below |
| Ubuntu 21.04 / Hirsute    | Use [Ubuntu 21.04](#distribution-ubuntu-2104) instructions below |
| Ubuntu 21.10 / Impish     | Use [Ubuntu 21.10](#distribution-ubuntu-2110) instructions below |
| Ubuntu 22.04 / Jammy      | Use [Ubuntu 22.04](#distribution-ubuntu-2204) instructions below |
| Ubuntu 22.10 / Kinetic    | Use [Ubuntu 22.10](#distribution-ubuntu-2210) instructions below |
| Ubuntu 23.04 / Lunar      | Use [Ubuntu 23.04](#distribution-ubuntu-2304) instructions below |
| Ubuntu 23.10 / Mantic     | Use [Ubuntu 23.10](#distribution-ubuntu-2310) instructions below |
| Ubuntu 24.04 / Noble      | Use [Ubuntu 24.04](#distribution-ubuntu-2404) instructions below |

> [!IMPORTANT]
> If your Linux distribution and release is not in the table above, you have 2 options:
>
> 1. Compile the application from source. Refer to install.md (Compilation & Installation) for assistance.
> 2. Raise a support case with your Linux Distribution to provide you with an applicable package you can use.

## Distribution Package Install Instructions

### Distribution: Debian 11
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|✔|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_11/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_11/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Debian 12
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|✔|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_12/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_12/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 20.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_20.04/Release.key | sudo apt-key add -
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo 'deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_20.04/ ./' | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 21.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.04/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.04/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 21.10
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.10/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.10/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 22.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_22.04/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_22.04/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 22.10
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_22.10/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_22.10/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 23.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_23.04/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_23.04/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 23.10
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|❌|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_23.10/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_23.10/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 24.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|❌|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_24.04/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_24.04/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

## Known Issues with Installing from the above packages

### 1. The client may segfault | core-dump when exiting
When the client is run in `--monitor` mode manually, or when using the systemd service, the client may segfault on exit.

This issue is caused by the way the 'onedrive' packages are built using the distribution LDC package & the default distribution compiler options which is the root cause for this issue. Refer to: https://bugs.launchpad.net/ubuntu/+source/ldc/+bug/1895969

**Additional references:**
*  https://github.com/abraunegg/onedrive/issues/1053
*  https://github.com/abraunegg/onedrive/issues/1609

**Resolution Options:**
*  Uninstall the package and build client from source
