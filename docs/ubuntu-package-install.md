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
> * MX Linux
> * Pop!_OS
> * Peppermint OS
> * Raspbian | Raspberry Pi OS
> * Ubuntu | Kubuntu | Xubuntu | Ubuntu Mate
> * Zorin OS
>
> Although packages for the 'onedrive' client are available through distribution repositories, it is strongly advised against installing them. These distribution-provided packages are outdated, unsupported, and contain bugs and issues that have already been resolved in newer versions. They should not be used.

> [!IMPORTANT]
> The distribution versions listed below are **End-of-Life (EOL)** and are **no longer supported** or tested with current client releases. You must upgrade to a supported distribution before proceeding.
> * Debian 9
> * Debian 10
> * Ubuntu 16.x
> * Ubuntu 18.x
> * Ubuntu 20.x


## Determine which instructions to use
Ubuntu and its clones are based on various different releases, thus, you must use the correct instructions below, otherwise you may run into package dependency issues and will be unable to install the client.

### Step 1: Remove any configured PPA and associated 'onedrive' package and systemd service files

#### Step 1a: Remove PPA if configured
Many Internet 'help' pages provide inconsistent details on how to install the OneDrive Client for Linux. A number of these websites continue to point users to install the client via the yann1ck PPA repository however this PPA no longer exists and should not be used. If you have previously configured, or attempted to add this PPA, this needs to be removed.

To remove the yann1ck PPA repository, perform the following actions:
```text
sudo add-apt-repository --remove ppa:yann1ck/onedrive
```

#### Step 1b: Remove 'onedrive' package installed from Debian / Ubuntu repositories
Many Internet 'help' pages provide inconsistent details on how to install the OneDrive Client for Linux. A number of these websites continue to advise users to install the client via `sudo apt install onedrive` without first configuring the OpenSuSE Build Service (OBS) Repository. When installing without OBS, you install an obsolete client version with known bugs that have been fixed, but this package also contains an errant systemd service (see below) that impacts background running of this client.

To remove the Ubuntu Universe client, perform the following actions:
```text
sudo apt remove onedrive
```

#### Step 1c: Remove errant systemd service file installed by Debian / Ubuntu distribution packages

The Debian and Ubuntu distribution packages automatically create and enable a default user-level systemd service when installing the onedrive package so that the client runs automatically after authentication. During installation you may see:

```
Created symlink /etc/systemd/user/default.target.wants/onedrive.service → /usr/lib/systemd/user/onedrive.service.
```

This systemd entry is not part of this project’s installation model and is introduced by Debian/Ubuntu packaging defaults. It should be removed. If left in place, it can cause the following error:

```
Opening the item database ...

ERROR: onedrive application is already running - check system process list for active application instances
 - Use 'sudo ps aufxw | grep onedrive' to potentially determine active running process

Waiting for all internal threads to complete before exiting application
```
As the client is built with GUI notifications enabled, each automatic restart of this service may also spam your desktop with notifications.

To remove this symbolic link created by the distribution package, run:

```
sudo rm /etc/systemd/user/default.target.wants/onedrive.service
```

If this service is not removed, uninstalling the `onedrive` package may result in repeated systemd restart attempts and log entries similar to:
```
Feb 10 10:32:00 host systemd[USER_A]: Started onedrive.service - OneDrive Client for Linux.
Feb 10 10:32:00 host (onedrive)[PID_A]: onedrive.service: Unable to locate executable '/usr/bin/onedrive': No such file or directory
Feb 10 10:32:00 host (onedrive)[PID_A]: onedrive.service: Failed at step EXEC spawning /usr/bin/onedrive: No such file or directory
Feb 10 10:32:00 host systemd[USER_A]: onedrive.service: Main process exited, code=exited, status=203/EXEC
Feb 10 10:32:00 host systemd[USER_A]: onedrive.service: Failed with result 'exit-code'.
Feb 10 10:32:02 host systemd[USER_B]: Started onedrive.service - OneDrive Client for Linux.
Feb 10 10:32:02 host (onedrive)[PID_B]: onedrive.service: Unable to locate executable '/usr/bin/onedrive': No such file or directory
Feb 10 10:32:02 host (onedrive)[PID_B]: onedrive.service: Failed at step EXEC spawning /usr/bin/onedrive: No such file or directory
Feb 10 10:32:02 host systemd[USER_B]: onedrive.service: Main process exited, code=exited, status=203/EXEC
Feb 10 10:32:02 host systemd[USER_B]: onedrive.service: Failed with result 'exit-code'.
Feb 10 10:32:03 host systemd[USER_A]: onedrive.service: Scheduled restart job, restart counter is at 201.
Feb 10 10:32:03 host systemd[USER_A]: Starting onedrive.service - OneDrive Client for Linux...
Feb 10 10:32:05 host systemd[USER_B]: onedrive.service: Scheduled restart job, restart counter is at 105.
Feb 10 10:32:05 host systemd[USER_B]: Starting onedrive.service - OneDrive Client for Linux...

```

This behaviour originates from Debian/Ubuntu packaging defaults and does not occur with the OpenSuSE Build Service packages.


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
Welcome to Ubuntu 24.04 LTS (GNU/Linux 6.8.0-36-generic x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/pro

Expanded Security Maintenance for Applications is not enabled.

0 updates can be applied immediately.

Enable ESM Apps to receive additional future security updates.
See https://ubuntu.com/esm or run: sudo pro status


The list of available updates is more than a week old.
To check for new updates run: sudo apt update
Last login: Mon Nov 10 06:42:58 2025 from xxx.xxx.xxx.xxx
alex@ubuntu-24-04:~$ su -
Password: 
root@ubuntu-24-04:~# ls -la
total 36
drwx------  5 root root 4096 Nov 10 06:43 .
drwxr-xr-x 23 root root 4096 Jun 30  2024 ..
-rw-------  1 root root  168 Nov 10 06:43 .bash_history
-rw-r--r--  1 root root 3106 Apr 22  2024 .bashrc
drwx------  2 root root 4096 Apr 24  2024 .cache
-rw-r--r--  1 root root  161 Apr 22  2024 .profile
drwx------  6 root root 4096 Jun 30  2024 snap
drwx------  2 root root 4096 Jun 30  2024 .ssh
-rwxr-xr-x  1 root root  174 Nov 10 06:43 update_os.sh
root@ubuntu-24-04:~# cat update_os.sh 
#!/bin/bash
rm -rf /var/lib/dpkg/lock-frontend
rm -rf /var/lib/dpkg/lock
apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get autoclean -y
root@ubuntu-24-04:~# ./update_os.sh 
Get:1 http://security.ubuntu.com/ubuntu noble-security InRelease [126 kB]
Hit:2 http://au.archive.ubuntu.com/ubuntu noble InRelease                
Get:3 http://au.archive.ubuntu.com/ubuntu noble-updates InRelease [126 kB]
Get:4 http://au.archive.ubuntu.com/ubuntu noble-backports InRelease [126 kB]
Get:5 http://au.archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages [1,585 kB]
....
Unpacking libglx-mesa0:amd64 (25.0.7-0ubuntu0.24.04.2) over (24.0.5-1ubuntu1) ...
Preparing to unpack .../6-libgl1-amber-dri_21.3.9-0ubuntu3~24.04.1_amd64.deb ...
Unpacking libgl1-amber-dri:amd64 (21.3.9-0ubuntu3~24.04.1) over (21.3.9-0ubuntu2) ...
(Reading database ... 152058 files and directories currently installed.)
Removing libglapi-mesa:amd64 (24.0.5-1ubuntu1) ...
Selecting previously unselected package libglapi-amber:amd64.
(Reading database ... 152049 files and directories currently installed.)
Preparing to unpack .../00-libglapi-amber_21.3.9-0ubuntu3~24.04.1_amd64.deb ...
Unpacking libglapi-amber:amd64 (21.3.9-0ubuntu3~24.04.1) ...
Selecting previously unselected package libmalcontent-0-0:amd64.
Preparing to unpack .../01-libmalcontent-0-0_0.11.1-1ubuntu1.2_amd64.deb ...
Unpacking libmalcontent-0-0:amd64 (0.11.1-1ubuntu1.2) ...
Preparing to unpack .../02-gnome-control-center_1%3a46.7-0ubuntu0.24.04.2_amd64.deb ...
Unpacking gnome-control-center (1:46.7-0ubuntu0.24.04.2) over (1:46.0.1-1ubuntu7) ...
Preparing to unpack .../03-libxatracker2_25.0.7-0ubuntu0.24.04.2_amd64.deb ...
Unpacking libxatracker2:amd64 (25.0.7-0ubuntu0.24.04.2) over (24.0.5-1ubuntu1) ...
Selecting previously unselected package linux-modules-6.14.0-35-generic.
Preparing to unpack .../04-linux-modules-6.14.0-35-generic_6.14.0-35.35~24.04.1_amd64.deb ...
Unpacking linux-modules-6.14.0-35-generic (6.14.0-35.35~24.04.1) ...
Selecting previously unselected package linux-image-6.14.0-35-generic.
Preparing to unpack .../05-linux-image-6.14.0-35-generic_6.14.0-35.35~24.04.1_amd64.deb ...
Unpacking linux-image-6.14.0-35-generic (6.14.0-35.35~24.04.1) ...
Selecting previously unselected package linux-modules-extra-6.14.0-35-generic.
Preparing to unpack .../06-linux-modules-extra-6.14.0-35-generic_6.14.0-35.35~24.04.1_amd64.deb ...
....
Del libpam-modules-bin 1.5.3-5ubuntu5.1 [51.9 kB]
Del systemd-sysv 255.4-1ubuntu8.1 [11.9 kB]
root@ubuntu-24-04:~# 
```

Reboot your system after running this process before continuing with Step 3. This ensures that your system is correctly up-to-date and any prior running 'onedrive' process and systemd service is now correctly removed and not running.
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
alex@ubuntu-24-04:~$ lsb_release -a
No LSB modules are available.
Distributor ID: Ubuntu
Description:    Ubuntu 24.04 LTS
Release:        24.04
Codename:       noble
alex@ubuntu-24-04:~$ 
```

### Step 4: Pick the correct instructions to use
If required, review the table below based on your 'lsb_release' information to pick the appropriate instructions to use:

| Release & Codename | Instructions to use |
|--------------------|---------------------|
| Linux Mint 19.x           | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Linux Mint 22.x |
| Linux Mint 20.x           | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Linux Mint 22.x |
| Linux Mint 21.x           | Use [Ubuntu 22.04](#distribution-ubuntu-2204) instructions below |
| Linux Mint 22.x           | Use [Ubuntu 24.04](#distribution-ubuntu-2404) instructions below |
| Linux Mint Debian Edition (LMDE) 5 / Elsie | Use [Debian 11](#distribution-debian-11) instructions below |
| Linux Mint Debian Edition (LMDE) 6 / Faye  | Use [Debian 12](#distribution-debian-12) instructions below |
| Linux Mint Debian Edition (LMDE) 7 / Gigi  | Use [Debian 13](#distribution-debian-13) instructions below |
| Debian 9 / stretch        | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Debian 13 |
| Debian 10 / buster        | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Debian 13 |
| Debian 11 / bullseye      | Use [Debian 11](#distribution-debian-11) instructions below |
| Debian 12 / bookworm      | Use [Debian 12](#distribution-debian-12) instructions below |
| Debian 13 / trixie        | Use [Debian 13](#distribution-debian-13) instructions below |
| Debian Sid                | Refer to https://packages.debian.org/sid/onedrive for assistance |
| Raspbian GNU/Linux 10     | You must build from source or upgrade your Operating System to Raspbian GNU/Linux 12 |
| Raspbian GNU/Linux 11     | Use [Debian 11](#distribution-debian-11) instructions below |
| Raspbian GNU/Linux 12     | Use [Debian 12](#distribution-debian-12) instructions below |
| Ubuntu 16.04 / Xenial     | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 24.04 |
| Ubuntu 18.04 / Bionic     | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 24.04 |
| Ubuntu 20.04 / Focal      | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 24.04 |
| Ubuntu 21.04 / Hirsute    | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 24.04 |
| Ubuntu 21.10 / Impish     | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 24.04 |
| Ubuntu 22.04 / Jammy      | Use [Ubuntu 22.04](#distribution-ubuntu-2204) instructions below |
| Ubuntu 22.10 / Kinetic    | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 24.04 |
| Ubuntu 23.04 / Lunar      | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 24.04 |
| Ubuntu 23.10 / Mantic     | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 24.04 |
| Ubuntu 24.04 / Noble      | Use [Ubuntu 24.04](#distribution-ubuntu-2404) instructions below |
| Ubuntu 24.10 / Oracular   | This platform is **End-of-Life (EOL)** and no longer supported. You must upgrade to at least Ubuntu 25.04 |
| Ubuntu 25.04 / Plucky     | Use [Ubuntu 25.04](#distribution-ubuntu-2504) instructions below |
| Ubuntu 25.10 / Questing   | Use [Ubuntu 25.10](#distribution-ubuntu-2510) instructions below |

> [!IMPORTANT]
> If your Linux distribution or release is **not listed in the table above**, you have two options:
>
> 1. Compile the client from source. Refer to [Installing or Upgrading the OneDrive Client for Linux](install.md).
> 2. Request packaging support from your distribution’s maintainers so that an official, supported package can be provided.

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

### Distribution: Debian 13
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|✔|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_13/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_13/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
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

### Distribution: Ubuntu 24.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

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

### Distribution: Ubuntu 25.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_25.04/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_25.04/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.

### Distribution: Ubuntu 25.10
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|❌|✔|✔|✔|

#### Step 1: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_25.10/Release.key | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg > /dev/null
```

#### Step 2: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/obs-onedrive.gpg] https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_25.10/ ./" | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 3: Update your apt package cache
Run: `sudo apt-get update`

#### Step 4: Install 'onedrive'
Run: `sudo apt install --no-install-recommends --no-install-suggests onedrive`

#### Step 5: Read 'Known Issues' with these packages
Read and understand the [known issues](#known-issues-with-installing-from-the-above-packages) with these packages below, taking any action that is needed.


## Known Issues with Installing from the above packages
There are currently no known issues when installing 'onedrive' from the OpenSuSE Build Service repository.
