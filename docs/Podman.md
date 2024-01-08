# Run the OneDrive Client for Linux under Podman
This client can be run as a Podman container, with 3 available container base options for you to choose from:

| Container Base | Docker Tag  | Description                                                    | i686 | x86_64 | ARMHF | AARCH64 |
|----------------|-------------|----------------------------------------------------------------|:------:|:------:|:-----:|:-------:|
| Alpine Linux   | edge-alpine | Podman container based on Alpine 3.18 using 'master'           |❌|✔|❌|✔|
| Alpine Linux   | alpine      | Podman container based on Alpine 3.18 using latest release     |❌|✔|❌|✔|
| Debian         | debian      | Podman container based on Debian Stable using latest release   |✔|✔|✔|✔|
| Debian         | edge        | Podman container based on Debian Stable using 'master'         |✔|✔|✔|✔|
| Debian         | edge-debian | Podman container based on Debian Stable using 'master'         |✔|✔|✔|✔|
| Debian         | latest      | Podman container based on Debian Stable using latest release   |✔|✔|✔|✔|
| Fedora         | edge-fedora | Podman container based on Fedora 38 using 'master'             |❌|✔|❌|✔|
| Fedora         | fedora      | Podman container based on Fedora 38 using latest release       |❌|✔|❌|✔|

These containers offer a simple monitoring-mode service for the OneDrive Client for Linux.

The instructions below have been validated on:
*   Fedora 38

The instructions below will utilise the 'edge' tag, however this can be substituted for any of the other docker tags such as 'latest' from the table above if desired.

The 'edge' Docker Container will align closer to all documentation and features, where as 'latest' is the release version from a static point in time. The 'latest' tag however may contain bugs and/or issues that will have been fixed, and those fixes are contained in 'edge'.

Additionally there are specific version release tags for each release. Refer to https://hub.docker.com/r/driveone/onedrive/tags for any other Docker tags you may be interested in.

**Note:** The below instructions for podman has been tested and validated when logging into the system as an unprivileged user (non 'root' user).

## High Level Configuration Steps
1. Install 'podman' as per your distribution platform's instructions if not already installed.
2. Disable 'SELinux' as per your distribution platform's instructions
3. Test 'podman' by running a test container
4. Prepare the required podman volumes to store the configuration and data
5. Run the 'onedrive' container and perform authorisation
6. Running the 'onedrive' container under 'podman'

## Configuration Steps

### 1. Install 'podman' on your platform
Install 'podman' as per your distribution platform's instructions if not already installed.

### 2. Disable SELinux on your platform
In order to run the Docker container under 'podman', SELinux must be disabled. Without doing this, when the application is authenticated in the steps below, the following error will be presented:
```text
ERROR: The local file system returned an error with the following message:
  Error Message:    /onedrive/conf/refresh_token: Permission denied

The database cannot be opened. Please check the permissions of ~/.config/onedrive/items.sqlite3
```
The only known work-around for the above problem at present is to disable SELinux. Please refer to your distribution platform's instructions on how to perform this step.

* Fedora: https://docs.fedoraproject.org/en-US/quick-docs/selinux-changing-states-and-modes/#_disabling_selinux
* Red Hat Enterprise Linux: https://access.redhat.com/solutions/3176

Post disabling SELinux and reboot your system, confirm that `getenforce` returns `Disabled`:
```text
$ getenforce
Disabled
```

If you are still experiencing permission issues despite disabling SELinux, please read https://www.redhat.com/sysadmin/container-permission-denied-errors

### 3. Test 'podman' on your platform
Test that 'podman' is operational for your 'non-root' user, as per below:
```bash
[alex@fedora38-podman ~]$ podman pull fedora
Resolved "fedora" as an alias (/etc/containers/registries.conf.d/000-shortnames.conf)
Trying to pull registry.fedoraproject.org/fedora:latest...
Getting image source signatures
Copying blob b30887322388 done   | 
Copying config a1cd3cbf8a done   | 
Writing manifest to image destination
a1cd3cbf8adaa422629f2fcdc629fd9297138910a467b11c66e5ddb2c2753dff
[alex@fedora38-podman ~]$ podman run fedora /bin/echo "Welcome to the Podman World"
Welcome to the Podman World
[alex@fedora38-podman ~]$ 
```

### 4. Configure the required podman volumes
The 'onedrive' Docker container requires 2 podman volumes to operate:
*    Config Volume
*    Data Volume

The first volume is the configuration volume that stores all the applicable application configuration + current runtime state. In a non-containerised environment, this normally resides in `~/.config/onedrive` - in a containerised environment this is stored in the volume tagged as `/onedrive/conf`

The second volume is the data volume, where all your data from Microsoft OneDrive is stored locally. This volume is mapped to an actual directory point on your local filesystem and this is stored in the volume tagged as `/onedrive/data`

#### 4.1 Prepare the 'config' volume
Create the 'config' volume with the following command:
```bash
podman volume create onedrive_conf
```

This will create a podman volume labeled `onedrive_conf`, where all configuration of your onedrive account will be stored. You can add a custom config file in this location at a later point in time if required.

#### 4.2 Prepare the 'data' volume
Create the 'data' volume with the following command:
```bash
podman volume create onedrive_data
```

This will create a podman volume labeled `onedrive_data` and will map to a path on your local filesystem. This is where your data from Microsoft OneDrive will be stored. Keep in mind that:

*   The owner of this specified folder must not be root
*   Podman will attempt to change the permissions of the volume to the user the container is configured to run as

**NOTE:** Issues occur when this target folder is a mounted folder of an external system (NAS, SMB mount, USB Drive etc) as the 'mount' itself is owed by 'root'. If this is your use case, you *must* ensure your normal user can mount your desired target without having the target mounted by 'root'. If you do not fix this, your Podman container will fail to start with the following error message:
```bash
ROOT level privileges prohibited!
```

### 5. First run of Docker container under podman and performing authorisation
The 'onedrive' client within the container first needs to be authorised with your Microsoft account. This is achieved by initially running podman in interactive mode.

Run the podman image with the commands below and make sure to change the value of `ONEDRIVE_DATA_DIR` to the actual onedrive data directory on your filesystem that you wish to use (e.g. `export ONEDRIVE_DATA_DIR="/home/abraunegg/OneDrive"`).

**Important:** The 'target' folder of `ONEDRIVE_DATA_DIR` must exist before running the podman container. The script below will create 'ONEDRIVE_DATA_DIR' so that it exists locally for the podman volume mapping to occur.

It is also a requirement that the container be run using a non-root uid and gid, you must insert a non-root UID and GID (e.g.` export ONEDRIVE_UID=1000` and export `ONEDRIVE_GID=1000`). The script below will use `id` to evaluate your system environment to use the correct values.
```bash
export ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
export ONEDRIVE_UID=`id -u`
export ONEDRIVE_GID=`id -g`
mkdir -p ${ONEDRIVE_DATA_DIR}
podman run -it --name onedrive --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" \
    -v onedrive_conf:/onedrive/conf:U,Z \
    -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" \
    driveone/onedrive:edge
```

**Important:** In some scenarios, 'podman' sets the configuration and data directories to a different UID & GID as specified. To resolve this situation, you must run 'podman' with the `--userns=keep-id` flag to ensure 'podman' uses the UID and GID as specified. The updated script example when using `--userns=keep-id` is below:

```bash
export ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
export ONEDRIVE_UID=`id -u`
export ONEDRIVE_GID=`id -g`
mkdir -p ${ONEDRIVE_DATA_DIR}
podman run -it --name onedrive --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" \
    --userns=keep-id \
    -v onedrive_conf:/onedrive/conf:U,Z \
    -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" \
    driveone/onedrive:edge
```


**Important:** If you plan to use the 'podman' built in auto-updating of container images described in 'Systemd Service & Auto Updating' below, you must pass an additional argument to set a label during the first run. The updated script example to support auto-updating of container images is below:

```bash
export ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
export ONEDRIVE_UID=`id -u`
export ONEDRIVE_GID=`id -g`
mkdir -p ${ONEDRIVE_DATA_DIR}
podman run -it --name onedrive --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" \
    --userns=keep-id \
    -v onedrive_conf:/onedrive/conf:U,Z \
    -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" \
    -e PODMAN=1 \
    --label "io.containers.autoupdate=image" \
    driveone/onedrive:edge
```

When the Podman container successfully starts:
*   You will be asked to open a specific link using your web browser 
*   Login to your Microsoft Account and give the application the permission 
*   After giving the permission, you will be redirected to a blank page
*   Copy the URI of the blank page into the application prompt to authorise the application

Once the 'onedrive' application is authorised, the client will automatically start monitoring your `ONEDRIVE_DATA_DIR` for data changes to be uploaded to OneDrive. Files stored on OneDrive will be downloaded to this location.

If the client is working as expected, you can detach from the container with Ctrl+p, Ctrl+q.

### 6. Running the 'onedrive' container under 'podman'

#### 6.1 Check if the monitor service is running
```bash
podman ps -f name=onedrive
```

#### 6.2 Show 'onedrive' runtime logs
```bash
podman logs onedrive
```

#### 6.3 Stop running 'onedrive' container
```bash
podman stop onedrive
```

#### 6.4 Start 'onedrive' container
```bash
podman start onedrive
```

#### 6.5 Remove 'onedrive' container
```bash
podman rm -f onedrive
```


## Advanced Usage

### Systemd Service & Auto Updating

Podman supports running containers as a systemd service and also auto updating of the container images. Using the existing running container you can generate a systemd unit file to be installed by the **root** user. To have your container image auto-update with podman, it must first be created with the label `"io.containers.autoupdate=image"` mentioned in step 5 above.

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

### Editing the running configuration and using a 'config' file
The 'onedrive' client should run in default configuration, however you can change this default configuration by placing a custom config file in the `onedrive_conf` podman volume. First download the default config from [here](https://raw.githubusercontent.com/abraunegg/onedrive/master/config)  
Then put it into your onedrive_conf volume path, which can be found with:  

```bash
podman volume inspect onedrive_conf
```
Or you can map your own config folder to the config volume. Make sure to copy all files from the volume into your mapped folder first.

The detailed document for the config can be found here: [Configuration](https://github.com/abraunegg/onedrive/blob/master/docs/usage.md#configuration)

### Syncing multiple accounts
There are many ways to do this, the easiest is probably to do the following:
1. Create a second podman config volume (replace `work` with your desired name):  `podman volume create onedrive_conf_work`
2. And start a second podman monitor container (again replace `work` with your desired name):

```bash
export ONEDRIVE_DATA_DIR_WORK="/home/abraunegg/OneDriveWork"
export ONEDRIVE_UID=`id -u`
export ONEDRIVE_GID=`id -g`
mkdir -p ${ONEDRIVE_DATA_DIR_WORK}
podman run -it --name onedrive_work --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" \
    --userns=keep-id \
    -v onedrive_conf_work:/onedrive/conf:U,Z \
    -v "${ONEDRIVE_DATA_DIR_WORK}:/onedrive/data:U,Z" \
    -e PODMAN=1 \
    --label "io.containers.autoupdate=image" \
    driveone/onedrive:edge
```

## Supported Podman Environment Variables
| Variable | Purpose | Sample Value |
| ---------------- | --------------------------------------------------- |:-------------:|
| <B>ONEDRIVE_UID</B> | UserID (UID) to run as  | 1000 |
| <B>ONEDRIVE_GID</B> | GroupID (GID) to run as | 1000 |
| <B>ONEDRIVE_VERBOSE</B> | Controls "--verbose" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_DEBUG</B> | Controls "--verbose --verbose" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_DEBUG_HTTPS</B> | Controls "--debug-https" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_RESYNC</B> | Controls "--resync" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_DOWNLOADONLY</B> | Controls "--download-only" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_UPLOADONLY</B> | Controls "--upload-only" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_NOREMOTEDELETE</B> | Controls "--no-remote-delete" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_LOGOUT</B> | Controls "--logout" switch. Default is 0 | 1 |
| <B>ONEDRIVE_REAUTH</B> | Controls "--reauth" switch. Default is 0 | 1 |
| <B>ONEDRIVE_AUTHFILES</B> | Controls "--auth-files" option. Default is "" | "authUrl:responseUrl" |
| <B>ONEDRIVE_AUTHRESPONSE</B> | Controls "--auth-response" option. Default is "" | See [here](https://github.com/abraunegg/onedrive/blob/master/docs/usage.md#authorize-the-application-with-your-onedrive-account) |
| <B>ONEDRIVE_DISPLAY_CONFIG</B> | Controls "--display-running-config" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_SINGLE_DIRECTORY</B> | Controls "--single-directory" option. Default = "" | "mydir" |
| <B>ONEDRIVE_DRYRUN</B> | Controls "--dry-run" option. Default is 0 | 1 |

### Environment Variables Usage Examples
**Verbose Output:**
```bash
podman run -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:edge
```
**Debug Output:**
```bash
podman run -e ONEDRIVE_DEBUG=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:edge
```
**Perform a --resync:**
```bash
podman run -e ONEDRIVE_RESYNC=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:edge
```
**Perform a --resync and --verbose:**
```bash
podman run -e ONEDRIVE_RESYNC=1 -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:edge
```
**Perform a --logout and re-authenticate:**
```bash
podman run -it -e ONEDRIVE_LOGOUT=1 -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" driveone/onedrive:edge
```

## Building a custom Podman image
You can also build your own image instead of pulling the one from [hub.docker.com](https://hub.docker.com/r/driveone/onedrive):
```bash
git clone https://github.com/abraunegg/onedrive
cd onedrive
podman build . -t local-onedrive -f contrib/docker/Dockerfile
```

There are alternate, smaller images available by building
Dockerfile-debian or Dockerfile-alpine.  These [multi-stage builder pattern](https://docs.docker.com/develop/develop-images/multistage-build/)
Dockerfiles require Docker version at least 17.05.

### How to build and run a custom Podman image based on Debian
``` bash
podman build . -t local-ondrive-debian -f contrib/docker/Dockerfile-debian
podman run -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" --userns=keep-id local-ondrive-debian:latest
```

### How to build and run a custom Podman image based on Alpine Linux
``` bash
podman build . -t local-ondrive-alpine -f contrib/docker/Dockerfile-alpine
podman run -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" --userns=keep-id local-ondrive-alpine:latest
```

### How to build and run a custom Podman image for ARMHF (Raspberry Pi)
Compatible with:
*    Raspberry Pi
*    Raspberry Pi 2
*    Raspberry Pi Zero
*    Raspberry Pi 3
*    Raspberry Pi 4
``` bash
podman build . -t local-onedrive-armhf -f contrib/docker/Dockerfile-debian
podman run -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" --userns=keep-id local-onedrive-armhf:latest
```

### How to build and run a custom Podman image for AARCH64 Platforms
``` bash
podman build . -t local-onedrive-aarch64 -f contrib/docker/Dockerfile-debian
podman run -v onedrive_conf:/onedrive/conf:U,Z -v "${ONEDRIVE_DATA_DIR}:/onedrive/data:U,Z" --user "${ONEDRIVE_UID}:${ONEDRIVE_GID}" --userns=keep-id local-onedrive-aarch64:latest
```
