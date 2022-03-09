# Run the OneDrive Client for Linux under Podman
This client can be run as a Podman container, with 3 available options for you to choose from:
1.  Container based on Fedora 35 - Docker Tag: latest
2.  Container based on Debian 11 - Docker Tag: debian
3.  Container based on Alpine Linux - Docker Tag: alpine

These containers offer a simple monitoring-mode service for the OneDrive Client for Linux.

The instructions below have been validated on:
*   Fedora 35

The instructions below will utilise the 'latest' tag, however this can be substituted for 'stretch' or 'alpine' if desired. The below instructions for podman have only been tested as the root user while running the containers themselves as non-root users.


## Basic Setup
### 0. Install podman using your distribution platform's instructions if not already installed
1.  Ensure that SELinux has been disabled on your system. A reboot may be required to ensure that this is correctly disabled.
2.  Install Podman as per requried for your platform
3.  Obtain your normal, non-root user UID and GID by using the `id` command or select another non-root id to run the container as

**NOTE:** SELinux context needs to be configured or disabled for Podman to be able to write to OneDrive host directory.

### 1.1 Prepare data volume
The container requries 2 Podman volumes:
*    Config Volume
*    Data Volume

The first volume is for your data folder and is created in the next step. This volume needs to be a path to a directory on your local filesystem, and this is where your data will be stored from OneDrive. Keep in mind that:

*   The owner of this specified folder must not be root
*   Podman will attempt to change the permissions of the volume to the user the container is configured to run as

**NOTE:** Issues occur when this target folder is a mounted folder of an external system (NAS, SMB mount, USB Drive etc) as the 'mount' itself is owed by 'root'. If this is your use case, you *must* ensure your normal user can mount your desired target without having the target mounted by 'root'. If you do not fix this, your Podman container will fail to start with the following error message:
```bash
ROOT level privileges prohibited!
```

### 1.2 Prepare config volume
Although not required, you can prepare the config volume before starting the container. Otherwise it will be created automatically during initial startup of the container.

Create the config volume with the following command:
```bash
podman volume create onedrive_conf
```

This will create a podman volume labeled `onedrive_conf`, where all configuration of your onedrive account will be stored. You can add a custom config file and other things later.

### 2. First run
The 'onedrive' client within the container needs to be authorized with your Microsoft account. This is achieved by initially running podman in interactive mode. 

Run the podman image with the commands below and make sure to change `ONEDRIVE_DATA_DIR` to the actual onedrive data directory on your filesystem that you wish to use (e.g. `"/home/abraunegg/OneDrive"`).

It is a requirement that the container be run using a non-root uid and gid, you must insert a non-root UID and GID (e.g.` export ONEDRIVE_UID=1000` and export `ONEDRIVE_GID=1000`). 

```bash
export ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
export ONEDRIVE_UID=1000
export ONEDRIVE_GID=1000
mkdir -p ${ONEDRIVE_DATA_DIR}
podman run -it --name onedrive --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" \
    -v onedrive_conf:/onedrive/conf:U,Z \
    -v "onedrive-test-data:/onedrive/data:U,Z" \
    driveone/onedrive:latest
```
**Important:** The 'target' folder of `ONEDRIVE_DATA_DIR` must exist before running the podman container

**If you plan to use podmans built in auto-updating of container images described in step 5, you must pass an additional argument to set a label during the first run.**

The run command would look instead look like as follows:
```
podman run -it --name onedrive --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" \
    -v onedrive_conf:/onedrive/conf:U,Z \
    -v "onedrive-test-data:/onedrive/data:U,Z" \
    -e PODMAN=1 \
    --label "io.containers.autoupdate=image"
    driveone/onedrive:latest
```

When the Podman container successfully starts:
*   You will be asked to open a specific link using your web browser 
*   Login to your Microsoft Account and give the application the permission 
*   After giving the permission, you will be redirected to a blank page
*   Copy the URI of the blank page into the application prompt to authorise the application

Once the 'onedrive' application is authorised, the client will automatically start monitoring your `ONEDRIVE_DATA_DIR` for data changes to be uploaded to OneDrive. Files stored on OneDrive will be downloaded to this location.

If the client is working as expected, you can detach from the container with Ctrl+p, Ctrl+q.

### 4. Podman Container Status, stop, and restart
Check if the monitor service is running

```bash
podman ps -f name=onedrive
```

Show monitor run logs

```bash
podman logs onedrive
```

Stop running monitor

```bash
podman stop onedrive
```

Resume monitor

```bash
podman start onedrive
```

Remove onedrive container

```bash
podman rm -f onedrive
```
## Advanced Setup

### 5. Systemd Service & Auto Updating

Podman supports running containers as a systemd service and also auto updating of the container images. Using the existing running container you can generate a systemd unit file to be installed by the **root** user. To have your container image auto-update with podman, it must first be created with the label `"io.containers.autoupdate=image"` mentioned in step 2.

```
cd /tmp
podman generate systemd --new --restart-policy on-failure --name -f onedrive
/tmp/container-onedrive.service

# copy the generated systemd unit file to the systemd path and reload the daemon

cp -Z ~/container-onedrive.service /usr/lib/systemd/system
systemctl daemon-reload

#optionally enable it to startup on boot

systemctl enable container-onedrive.service

#check status

systemctl status container-onedrive

#start/stop/restart container as a systemd service

systemctl stop container-onedrive
systemctl start container-onedrive
```

To update the image using podman (Ad-hoc)
```
podman auto-update
```

To update the image using systemd (Automatic/Scheduled)
```
# Enable the podman-auto-update.timer service at system start:

systemctl enable podman-auto-update.timer

# Start the service

systemctl start podman-auto-update.timer

# Containers with the autoupdate label will be updated on the next scheduled timer

systemctl list-timers --all
```

### 6. Edit the config
The 'onedrive' client should run in default configuration, however you can change this default configuration by placing a custom config file in the `onedrive_conf` podman volume. First download the default config from [here](https://raw.githubusercontent.com/abraunegg/onedrive/master/config)  
Then put it into your onedrive_conf volume path, which can be found with:  

```bash
podman volume inspect onedrive_conf
```
Or you can map your own config folder to the config volume. Make sure to copy all files from the volume into your mapped folder first.

The detailed document for the config can be found here: [Configuration](https://github.com/abraunegg/onedrive/blob/master/docs/USAGE.md#configuration)

### 7. Sync multiple accounts
There are many ways to do this, the easiest is probably to
1. Create a second podman config volume (replace `Work` with your desired name):  `podman volume create onedrive_conf_Work`
2. And start a second podman monitor container (again replace `Work` with your desired name):
```
export ONEDRIVE_DATA_DIR_WORK="/home/abraunegg/OneDriveWork"
mkdir -p ${ONEDRIVE_DATA_DIR_WORK}
podman run -it --restart unless-stopped --name onedrive_work \
   -v onedrive_conf_Work:/onedrive/conf \
   -v "${ONEDRIVE_DATA_DIR_WORK}:/onedrive/data" \
   --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" \
   driveone/onedrive:latest
```

## Environment Variables
| Variable | Purpose | Sample Value  |
| ---------------- | --------------------------------------------------- |:-------------:|
| <B>ONEDRIVE_UID</B> | UserID (UID) to run as  | 1000 |
| <B>ONEDRIVE_GID</B> | GroupID (GID) to run as | 1000 |
| <B>ONEDRIVE_VERBOSE</B> | Controls "--verbose" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_DEBUG</B> | Controls "--verbose --verbose" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_DEBUG_HTTPS</B> | Controls "--debug-https" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_RESYNC</B> | Controls "--resync" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_DOWNLOADONLY</B> | Controls "--download-only" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_LOGOUT</B> | Controls "--logout" switch. Default is 0 | 1 |
| <B>ONEDRIVE_REAUTH</B> | Controls "--reauth" switch. Default is 0 | 1 |
| <B>ONEDRIVE_AUTHFILES</B> | Controls "--auth-files" option. Default is "" | "authUrl:responseUrl" |
| <B>ONEDRIVE_AUTHRESPONSE</B> | Controls "--auth-response" option. Default is "" | See [here](https://github.com/abraunegg/onedrive/blob/master/docs/USAGE.md#authorize-the-application-with-your-onedrive-account) |

### Usage Examples
**Verbose Output:**
```bash
podman run -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:latest
```
**Debug Output:**
```bash
podman run -e ONEDRIVE_DEBUG=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:latest
```
**Perform a --resync:**
```bash
podman run -e ONEDRIVE_RESYNC=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:latest
```
**Perform a --resync and --verbose:**
```bash
podman run -e ONEDRIVE_RESYNC=1 -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:latest
```
**Perform a --logout and re-authenticate:**
```bash
podman run -it -e ONEDRIVE_LOGOUT=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:latest
```

## Build instructions

You can also build your own image instead of pulling the one from [hub.docker.com](https://hub.docker.com/r/driveone/onedrive):
```bash
git clone https://github.com/abraunegg/onedrive
cd onedrive
podman build . -t local-onedrive -f contrib/docker/Dockerfile
```

There are alternate, smaller images available by building
Dockerfile-stretch or Dockerfile-alpine.  These [multi-stage builder
pattern](https://docs.docker.com/develop/develop-images/multistage-build/)

#### How to build and run a custom Docker image based on Debian Stretch
``` bash
podman build . -t local-ondrive-stretch -f contrib/docker/Dockerfile-stretch
podman run -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" local-ondrive-stretch:latest
```

#### How to build and run a custom Docker image based on Alpine Linux
``` bash
podman build . -t local-ondrive-alpine -f contrib/docker/Dockerfile-alpine
podman run -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" local-ondrive-alpine:latest
```

#### How to build and run a custom Docker image for ARMHF (Raspberry Pi)
Compatible with:
*    Raspberry Pi
*    Raspberry Pi 2
*    Raspberry Pi Zero
*    Raspberry Pi 3
*    Raspberry Pi 4
``` bash
podman build . -t local-onedrive-rpi -f contrib/docker/Dockerfile-rpi
podman run -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" local-ondrive-rpi:latest
```

#### How to build and run a custom Docker image for AARCH64 Platforms
``` bash
podman build . -t local-onedrive-aarch64 -f contrib/docker/Dockerfile-aarch64
podman run -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" local-onedrive-aarch64:latest
```
