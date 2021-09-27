# Installation of 'onedrive' package on Debian and Ubuntu

This document covers the appropriate steps to install the 'onedrive' client using the provided packages for Debian and Ubuntu.

#### Important information for all Ubuntu and Ubuntu based distribution users:
This information is specifically for the following platforms and distributions:
*   Ubuntu
*   Lubuntu
*   Linux Mint
*   POP OS
*   Peppermint OS

Whilst there are [onedrive](https://packages.ubuntu.com/search?keywords=onedrive&searchon=names&suite=all&section=all) Universe packages available for Ubuntu, do not install 'onedrive' from these packages via `apt install onedrive`. The default Ubuntu Universe packages are out-of-date and are not supported and should not be used.

## Distribution Package Install Instructions

### Distribution: Debian 10
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
|✔|✔|✔|✔| |

#### Step 1: Update /etc/apt/sources.list
Add the following to the end of your `/etc/apt/sources.list` file:
```text
deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_10/ ./
```

#### Step 2: Download and add the release key
1.  Download the 'Release.key' file: `wget https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/Debian_10/Release.key`
2.  Add the 'Release.key' file to your apt key repository: `apt-key add ./Release.key`

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

#### Step 1: Update /etc/apt/sources.list
Add the following to the end of your `/etc/apt/sources.list` file:
```text
deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_20.04/ ./
```

#### Step 2: Download and add the release key
1.  Download the 'Release.key' file: `wget https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_20.04/Release.key`
2.  Add the 'Release.key' file to your apt key repository: `apt-key add ./Release.key`

#### Step 3: Update your apt package cache
1.  Run: `apt-get update`

#### Step 4: Install 'onedrive'
1.  Run: `apt install onedrive`

#### Step 5: Read 'Known Issues' with these packages
1.  Read and understand the known issues with these packages below, taking any action that is needed.

### Distribution: Ubuntu 20.10
The packages support the following platform architectures:
| &nbsp;i686&nbsp; | x86_64 | ARMHF | AARCH64 |
|:----:|:------:|:-----:|:-------:|
❌|✔|✔|✔| |

#### Step 1: Update /etc/apt/sources.list
Add the following to the end of your `/etc/apt/sources.list` file:
```text
deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_20.10/ ./
```

#### Step 2: Download and add the release key
1.  Download the 'Release.key' file: `wget https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_20.10/Release.key`
2.  Add the 'Release.key' file to your apt key repository: `apt-key add ./Release.key`

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

#### Step 1: Update /etc/apt/sources.list
Add the following to the end of your `/etc/apt/sources.list` file:
```text
deb https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.04/ ./
```

#### Step 2: Download and add the release key
1.  Download the 'Release.key' file: `wget https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/xUbuntu_21.04/Release.key`
2.  Add the 'Release.key' file to your apt key repository: `apt-key add ./Release.key`

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


### 2. On Ubuntu 20.04 the client will segfault | core-dump when exiting
When the client is being run in `--monitor` mode manually, or when using the systemd service, the client will segfault on exit.

This issue is caused by the way the Ubuntu packages are built, because of using the Ubuntu LDC package `ldc-1:1.20.1-1` which is the root cause. Refer to: https://bugs.launchpad.net/ubuntu/+source/ldc/+bug/1895969

**Additional references:**
*  https://github.com/abraunegg/onedrive/issues/1053
*  https://github.com/abraunegg/onedrive/issues/1609

**Resolution Options:**
*  Upgrade to Ubuntu 20.10 or Ubuntu 21.x
*  Uninstall the package and build client from source

