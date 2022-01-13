# Installation of 'onedrive' package on Debian and Ubuntu

This document covers the appropriate steps to install the 'onedrive' client using the provided packages for Debian and Ubuntu.

#### Important information for all Ubuntu and Ubuntu based distribution users:
This information is specifically for the following platforms and distributions:
*   Ubuntu
*   Lubuntu
*   Linux Mint
*   POP OS
*   Peppermint OS

Whilst there are [onedrive](https://packages.ubuntu.com/search?keywords=onedrive&searchon=names&suite=all&section=all) Universe packages available for Ubuntu, do not install 'onedrive' from these Universe packages. The default Ubuntu Universe packages are out-of-date and are not supported and should not be used.

## Determine which instructions to use
Ubuntu and its clones are based on various different releases, thus, you must use the correct instructions below, otherwise you may run into package dependancy issues and will be unable to install the client.

### Step 1: Ensure your systen is up-to-date
Use a script, simalar to the following to ensure your system is updated correctly. Run this script as 'root':
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
Reboot your system after running this process before continuing with Step 2.

### Step 2: Determine what your OS is based on
Determine what your OS is based on. To do this, run the following command:
```text
lsb_release -a
```

### Step 3: Pick the correct instructions to use
If required, review the table below based on your 'lsb_release' information to pick the appropriate instructions to use:

| Release & Codename | Instructions to use |
|--------------------|---------------------|
| 18.x / bionic            | You must build from source or upgrade your Operating System Ubuntu 20.x      |
| Linux Mint 19.x / tina   | You must build from source or upgrade your Operating System Linux Mint 20.x  |
| Linux Mint 20.x / ulyana | Use Ubuntu 20.04 instructions below  |

## Distribution Package Install Instructions

### Distribution: Debian 10
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|✔|✔|✔|✔| |

#### Step 1: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo 'deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_10/ ./' | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 2: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_10/Release.key | sudo apt-key add -
```

#### Step 3: Update your apt package cache
1.  Run: `apt-get update`

#### Step 4: Install 'onedrive'
1.  Run: `apt install onedrive`

#### Step 5: Read 'Known Issues' with these packages
1.  Read and understand the known issues with these packages below, taking any action that is needed.

### Distribution: Debian 11
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|✔|✔|✔|✔| |

#### Step 1: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo 'deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_11/ ./' | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 2: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_11/Release.key | sudo apt-key add -
```

#### Step 3: Update your apt package cache
1.  Run: `apt-get update`

#### Step 4: Install 'onedrive'
1.  Run: `apt install onedrive`

#### Step 5: Read 'Known Issues' with these packages
1.  Read and understand the known issues with these packages below, taking any action that is needed.

### Distribution: Ubuntu 20.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
❌|✔|✔|✔| |

#### Step 1: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo 'deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_20.04/ ./' | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 2: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_20.04/Release.key | sudo apt-key add -
```

#### Step 3: Update your apt package cache
1.  Run: `apt-get update`

#### Step 4: Install 'onedrive'
1.  Run: `apt install onedrive`

#### Step 5: Read 'Known Issues' with these packages
1.  Read and understand the known issues with these packages below, taking any action that is needed.

### Distribution: Ubuntu 21.04
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
❌|✔|✔|✔| |

#### Step 1: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo 'deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.04/ ./' | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 2: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.04/Release.key | sudo apt-key add -
```

#### Step 3: Update your apt package cache
1.  Run: `apt-get update`

#### Step 4: Install 'onedrive'
1.  Run: `apt install onedrive`

#### Step 5: Read 'Known Issues' with these packages
1.  Read and understand the known issues with these packages below, taking any action that is needed.

### Distribution: Ubuntu 21.10
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
❌|✔|✔|✔| |

#### Step 1: Add the OpenSuSE Build Service repository
Add the OpenSuSE Build Service repository using the following command:
```text
echo 'deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.10/ ./' | sudo tee /etc/apt/sources.list.d/onedrive.list
```

#### Step 2: Add the OpenSuSE Build Service repository release key
Add the OpenSuSE Build Service repository release key using the following command:
```text
wget -qO - https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.10/Release.key | sudo apt-key add -
```

#### Step 3: Update your apt package cache
1.  Run: `apt-get update`

#### Step 4: Install 'onedrive'
1.  Run: `apt install onedrive`

#### Step 5: Read 'Known Issues' with these packages
1.  Read and understand the known issues with these packages below, taking any action that is needed.

## Known Issues with Installing from the above packages

### 1. The 'onedrive' client will automatically startup post 'authentication' without any further actions.
The 'onedrive' client will automatically startup post 'authentication' without any further actions. In some circumstances this may be highly undesirable and can also lead to data loss.

This is because, when the package is installed, the following symbolic link is created:
```text
Created symlink /etc/systemd/user/default.target.wants/onedrive.service → /usr/lib/systemd/user/onedrive.service.
```

This issue is being tracked by: [#1274](https://github.com/abraunegg/onedrive/issues/1274)

**Important:** It is highly advisable that you remove this symbolic link before you configure or authenticate your client. If you do not remove this symbolic link before you configure or authenticate your client this could lead to multiple copies of the client running, leading to sync conflics and operational issues which may include data loss (data deleted locally & on OneDrive).

Do not rely on this symbolic link for your systemd configuration to automatically start your onedrive client - refer to [Running 'onedrive' as a system service](https://github.com/abraunegg/onedrive/blob/master/docs/USAGE.md#running-onedrive-as-a-system-service) on how to configure this correctly.

### 2. The client will segfault | core-dump when exiting
When the client is being run in `--monitor` mode manually, or when using the systemd service, the client will segfault on exit.

This issue is caused by the way the Ubuntu 'onedrive' packages are built using the Ubuntu LDC package & compiler options which is the root cause for this issue. Refer to: https://bugs.launchpad.net/ubuntu/+source/ldc/+bug/1895969

**Additional references:**
*  https://github.com/abraunegg/onedrive/issues/1053
*  https://github.com/abraunegg/onedrive/issues/1609

**Resolution Options:**
*  Uninstall the package and build client from source

