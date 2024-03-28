# Run the OneDrive Client for Linux under Docker
This client can be run as a Docker container, with 3 available container base options for you to choose from:

| Container Base | Docker Tag  | Description                                                    | i686 | x86_64 | ARMHF | AARCH64 |
|----------------|-------------|----------------------------------------------------------------|:------:|:------:|:-----:|:-------:|
| Alpine Linux   | edge-alpine | Docker container based on Alpine 3.18 using 'master'           |❌|✔|❌|✔|
| Alpine Linux   | alpine      | Docker container based on Alpine 3.18 using latest release     |❌|✔|❌|✔|
| Debian         | debian      | Docker container based on Debian Stable using latest release   |✔|✔|✔|✔|
| Debian         | edge        | Docker container based on Debian Stable using 'master'         |✔|✔|✔|✔|
| Debian         | edge-debian | Docker container based on Debian Stable using 'master'         |✔|✔|✔|✔|
| Debian         | latest      | Docker container based on Debian Stable using latest release   |✔|✔|✔|✔|
| Fedora         | edge-fedora | Docker container based on Fedora 38 using 'master'             |❌|✔|❌|✔|
| Fedora         | fedora      | Docker container based on Fedora 38 using latest release       |❌|✔|❌|✔|

These containers offer a simple monitoring-mode service for the OneDrive Client for Linux.

The instructions below have been validated on:
*   Fedora 38

The instructions below will utilise the 'edge' tag, however this can be substituted for any of the other docker tags such as 'latest' from the table above if desired.

The 'edge' Docker Container will align closer to all documentation and features, where as 'latest' is the release version from a static point in time. The 'latest' tag however may contain bugs and/or issues that will have been fixed, and those fixes are contained in 'edge'.

Additionally there are specific version release tags for each release. Refer to https://hub.docker.com/r/driveone/onedrive/tags for any other Docker tags you may be interested in.

> [!NOTE]
> The below instructions for docker has been tested and validated when logging into the system as an unprivileged user (non 'root' user).

## High Level Configuration Steps
1. Install 'docker' as per your distribution platform's instructions if not already installed.
2. Configure 'docker' to allow non-privileged users to run Docker commands
3. Disable 'SELinux' as per your distribution platform's instructions
4. Test 'docker' by running a test container without using `sudo`
5. Prepare the required docker volumes to store the configuration and data
6. Run the 'onedrive' container and perform authorisation
7. Running the 'onedrive' container under 'docker'

## Configuration Steps

### 1. Install 'docker' on your platform
Install 'docker' as per your distribution platform's instructions if not already installed as per the instructions on https://docs.docker.com/engine/install/

> [!CAUTION]
> If you are using Ubuntu, do not install Docker from your distribution platform's repositories as these contain obsolete and outdated versions. You *must* install Docker from Docker provided packages.

### 2. Configure 'docker' to allow non-privileged users to run Docker commands
Read https://docs.docker.com/engine/install/linux-postinstall/ to configure the 'docker' user group with your user account to allow your non 'root' user to run 'docker' commands.

### 3. Disable SELinux on your platform
In order to run the Docker container, SELinux must be disabled. Without doing this, when the application is authenticated in the steps below, the following error will be presented:
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

### 4. Test 'docker' on your platform
Ensure that 'docker' is running as a system service, and is enabled to be activated on system reboot:
```bash
sudo systemctl enable --now docker
```

Test that 'docker' is operational for your 'non-root' user, as per below:
```bash
[alex@fedora-38-docker-host ~]$ docker run hello-world
Unable to find image 'hello-world:latest' locally
latest: Pulling from library/hello-world
719385e32844: Pull complete 
Digest: sha256:88ec0acaa3ec199d3b7eaf73588f4518c25f9d34f58ce9a0df68429c5af48e8d
Status: Downloaded newer image for hello-world:latest

Hello from Docker!
This message shows that your installation appears to be working correctly.

To generate this message, Docker took the following steps:
 1. The Docker client contacted the Docker daemon.
 2. The Docker daemon pulled the "hello-world" image from the Docker Hub.
    (amd64)
 3. The Docker daemon created a new container from that image which runs the
    executable that produces the output you are currently reading.
 4. The Docker daemon streamed that output to the Docker client, which sent it
    to your terminal.

To try something more ambitious, you can run an Ubuntu container with:
 $ docker run -it ubuntu bash

Share images, automate workflows, and more with a free Docker ID:
 https://hub.docker.com/

For more examples and ideas, visit:
 https://docs.docker.com/get-started/

[alex@fedora-38-docker-host ~]$ 
```

### 5. Configure the required docker volumes
The 'onedrive' Docker container requires 2 docker volumes to operate:
*    Config Volume
*    Data Volume

The first volume is the configuration volume that stores all the applicable application configuration + current runtime state. In a non-containerised environment, this normally resides in `~/.config/onedrive` - in a containerised environment this is stored in the volume tagged as `/onedrive/conf`

The second volume is the data volume, where all your data from Microsoft OneDrive is stored locally. This volume is mapped to an actual directory point on your local filesystem and this is stored in the volume tagged as `/onedrive/data`

#### 5.1 Prepare the 'config' volume
Create the 'config' volume with the following command:
```bash
docker volume create onedrive_conf
```

This will create a docker volume labeled `onedrive_conf`, where all configuration of your onedrive account will be stored. You can add a custom config file in this location at a later point in time if required.

#### 5.2 Prepare the 'data' volume
Create the 'data' volume with the following command:
```bash
docker volume create onedrive_data
```

This will create a docker volume labeled `onedrive_data` and will map to a path on your local filesystem. This is where your data from Microsoft OneDrive will be stored. Keep in mind that:

*   The owner of this specified folder must not be root
*   The owner of this specified folder must have permissions for its parent directory
*   Docker will attempt to change the permissions of the volume to the user the container is configured to run as

> [!IMPORTANT]
> Issues occur when this target folder is a mounted folder of an external system (NAS, SMB mount, USB Drive etc) as the 'mount' itself is owed by 'root'. If this is your use case, you *must* ensure your normal user can mount your desired target without having the target mounted by 'root'. If you do not fix this, your Docker container will fail to start with the following error message:
> ```bash
> ROOT level privileges prohibited!
> ```

### 6. First run of Docker container under docker and performing authorisation
The 'onedrive' client within the container first needs to be authorised with your Microsoft account. This is achieved by initially running docker in interactive mode.

Run the docker image with the commands below and make sure to change the value of `ONEDRIVE_DATA_DIR` to the actual onedrive data directory on your filesystem that you wish to use (e.g. `export ONEDRIVE_DATA_DIR="/home/abraunegg/OneDrive"`).

> [!IMPORTANT]
> The 'target' folder of `ONEDRIVE_DATA_DIR` must exist before running the docker container. The script below will create 'ONEDRIVE_DATA_DIR' so that it exists locally for the docker volume mapping to occur.

It is also a requirement that the container be run using a non-root uid and gid, you must insert a non-root UID and GID (e.g.` export ONEDRIVE_UID=1000` and export `ONEDRIVE_GID=1000`). The script below will use `id` to evaluate your system environment to use the correct values.
```bash
export ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
export ONEDRIVE_UID=`id -u`
export ONEDRIVE_GID=`id -g`
mkdir -p ${ONEDRIVE_DATA_DIR}
docker run -it --name onedrive -v onedrive_conf:/onedrive/conf \
    -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" \
    -e "ONEDRIVE_UID=${ONEDRIVE_UID}" \
    -e "ONEDRIVE_GID=${ONEDRIVE_GID}" \
    driveone/onedrive:edge
```

When the Docker container successfully starts:
*   You will be asked to open a specific link using your web browser 
*   Login to your Microsoft Account and give the application the permission 
*   After giving the permission, you will be redirected to a blank page
*   Copy the URI of the blank page into the application prompt to authorise the application

Once the 'onedrive' application is authorised, the client will automatically start monitoring your `ONEDRIVE_DATA_DIR` for data changes to be uploaded to OneDrive. Files stored on OneDrive will be downloaded to this location.

If the client is working as expected, you can detach from the container with Ctrl+p, Ctrl+q.

### 7. Running the 'onedrive' container under 'docker'

#### 7.1 Check if the monitor service is running
```bash
docker ps -f name=onedrive
```

#### 7.2 Show 'onedrive' runtime logs
```bash
docker logs onedrive
```

#### 7.3 Stop running 'onedrive' container
```bash
docker stop onedrive
```

#### 7.4 Start 'onedrive' container
```bash
docker start onedrive
```

#### 7.5 Remove 'onedrive' container
```bash
docker rm -f onedrive
```

## Advanced Usage

### How to use Docker-compose
You can utilise `docker-compose` if available on your platform if you are able to use docker compose schemas > 3.

In the following example it is assumed you have a `ONEDRIVE_DATA_DIR` environment variable and have already created the `onedrive_conf` volume. 

You can also use docker bind mounts for the configuration folder, e.g. `export ONEDRIVE_CONF="${HOME}/OneDriveConfig"`.

```
version: "3"
services:
    onedrive:
        image: driveone/onedrive:edge
        restart: unless-stopped
        environment:
            - ONEDRIVE_UID=${PUID}
            - ONEDRIVE_GID=${PGID}
        volumes: 
            - onedrive_conf:/onedrive/conf
            - ${ONEDRIVE_DATA_DIR}:/onedrive/data
```

Note that you still have to perform step 3: First Run. 

### Editing the running configuration and using a 'config' file
The 'onedrive' client should run in default configuration, however you can change this default configuration by placing a custom config file in the `onedrive_conf` docker volume. First download the default config from [here](https://raw.githubusercontent.com/abraunegg/onedrive/master/config)  
Then put it into your onedrive_conf volume path, which can be found with:  

```bash
docker volume inspect onedrive_conf
```

Or you can map your own config folder to the config volume. Make sure to copy all files from the docker volume into your mapped folder first.

The detailed document for the config can be found here: [Configuration](https://github.com/abraunegg/onedrive/blob/master/docs/usage.md#configuration)

### Syncing multiple accounts
There are many ways to do this, the easiest is probably to do the following:
1. Create a second docker config volume (replace `Work` with your desired name):  `docker volume create onedrive_conf_Work`
2. And start a second docker monitor container (again replace `Work` with your desired name):
```
export ONEDRIVE_DATA_DIR_WORK="/home/abraunegg/OneDriveWork"
mkdir -p ${ONEDRIVE_DATA_DIR_WORK}
docker run -it --restart unless-stopped --name onedrive_Work -v onedrive_conf_Work:/onedrive/conf -v "${ONEDRIVE_DATA_DIR_WORK}:/onedrive/data" driveone/onedrive:edge
```

### Run or update the Docker container with one script
If you are experienced with docker and onedrive, you can use the following script:

```bash
# Update ONEDRIVE_DATA_DIR with correct OneDrive directory path
ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
# Create directory if non-existant
mkdir -p ${ONEDRIVE_DATA_DIR} 

firstRun='-d'
docker pull driveone/onedrive:edge
docker inspect onedrive_conf > /dev/null 2>&1 || { docker volume create onedrive_conf; firstRun='-it'; }
docker inspect onedrive > /dev/null 2>&1 && docker rm -f onedrive
docker run $firstRun --restart unless-stopped --name onedrive -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:edge
```

## Supported Docker Environment Variables
| Variable | Purpose | Sample Value |
| ---------------- | --------------------------------------------------- |:--------------------------------------------------------------------------------------------------------------------------------:|
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
| <B>ONEDRIVE_AUTHFILES</B> | Controls "--auth-files" option. Default is "" | Please read [CLI Option: --auth-files](./application-config-options.md#cli-option---auth-files) |
| <B>ONEDRIVE_AUTHRESPONSE</B> | Controls "--auth-response" option. Default is "" | Please read [CLI Option: --auth-response](./application-config-options.md#cli-option---auth-response) |
| <B>ONEDRIVE_DISPLAY_CONFIG</B> | Controls "--display-running-config" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_SINGLE_DIRECTORY</B> | Controls "--single-directory" option. Default = "" | "mydir" |
| <B>ONEDRIVE_DRYRUN</B> | Controls "--dry-run" option. Default is 0 | 1 |
| <B>ONEDRIVE_DISABLE_DOWNLOAD_VALIDATION</B> | Controls "--disable-download-validation" option. Default is 0 | 1 |
| <B>ONEDRIVE_DISABLE_UPLOAD_VALIDATION</B> | Controls "--disable-upload-validation" option. Default is 0 | 1 |
| <B>ONEDRIVE_SYNC_SHARED_FILES</B> | Controls "--sync-shared-files" option. Default is 0 | 1 |

### Environment Variables Usage Examples
**Verbose Output:**
```bash
docker container run -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:edge
```
**Debug Output:**
```bash
docker container run -e ONEDRIVE_DEBUG=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:edge
```
**Perform a --resync:**
```bash
docker container run -e ONEDRIVE_RESYNC=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:edge
```
**Perform a --resync and --verbose:**
```bash
docker container run -e ONEDRIVE_RESYNC=1 -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:edge
```
**Perform a --logout and re-authenticate:**
```bash
docker container run -it -e ONEDRIVE_LOGOUT=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:edge
```

## Building a custom Docker image

### Build Environment Requirements
*   Build environment must have at least 1GB of memory & 2GB swap space

You can validate your build environment memory status with the following command:
```text
cat /proc/meminfo | grep -E 'MemFree|Swap'
```
This should result in the following similar output:
```text
MemFree:         3704644 kB
SwapCached:            0 kB
SwapTotal:       8117244 kB
SwapFree:        8117244 kB
```

If you do not have enough swap space, you can use the following script to dynamically allocate a swapfile for building the Docker container:

```bash
cd /var 
sudo fallocate -l 1.5G swapfile
sudo chmod 600 swapfile
sudo mkswap swapfile
sudo swapon swapfile
# make swap permanent
sudo nano /etc/fstab
# add "/swapfile swap swap defaults 0 0" at the end of file
# check it has been assigned
swapon -s
free -h
```

If you are running a Raspberry Pi, you will need to edit your system configuration to increase your swapfile:

*   Modify the file `/etc/dphys-swapfile` and edit the `CONF_SWAPSIZE`, for example: `CONF_SWAPSIZE=2048`. 

> [!IMPORTANT]
> A reboot of your Raspberry Pi is required to make this change effective.

### Building and running a custom Docker image
You can also build your own image instead of pulling the one from [hub.docker.com](https://hub.docker.com/r/driveone/onedrive):
```bash
git clone https://github.com/abraunegg/onedrive
cd onedrive
docker build . -t local-onedrive -f contrib/docker/Dockerfile
docker container run -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" local-onedrive:latest
```

There are alternate, smaller images available by using `Dockerfile-debian` or `Dockerfile-alpine`. These [multi-stage builder pattern](https://docs.docker.com/develop/develop-images/multistage-build/) Dockerfiles require Docker version at least 17.05.

### How to build and run a custom Docker image based on Debian
``` bash
docker build . -t local-ondrive-debian -f contrib/docker/Dockerfile-debian
docker container run -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" local-ondrive-debian:latest
```

### How to build and run a custom Docker image based on Alpine Linux
``` bash
docker build . -t local-ondrive-alpine -f contrib/docker/Dockerfile-alpine
docker container run -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" local-ondrive-alpine:latest
```

### How to build and run a custom Docker image for ARMHF (Raspberry Pi)
Compatible with:
*    Raspberry Pi
*    Raspberry Pi 2
*    Raspberry Pi Zero
*    Raspberry Pi 3
*    Raspberry Pi 4
``` bash
docker build . -t local-onedrive-armhf -f contrib/docker/Dockerfile-debian
docker container run -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" local-onedrive-armhf:latest
```

### How to build and run a custom Docker image for AARCH64 Platforms
``` bash
docker build . -t local-onedrive-aarch64 -f contrib/docker/Dockerfile-debian
docker container run -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" local-onedrive-aarch64:latest
```
### How to support double-byte languages
In some geographic regions, you may need to change and/or update the locale specification of the Docker container to better support the local language used for your local filesystem. To do this, follow the example below:
```
FROM driveone/onedrive

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update
RUN apt-get install -y locales

RUN echo "ja_JP.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen ja_JP.UTF-8 && \
    dpkg-reconfigure locales && \
    /usr/sbin/update-locale LANG=ja_JP.UTF-8

ENV LC_ALL ja_JP.UTF-8
```
The above example changes the Docker container to support Japanese. To support your local language, change `ja_JP.UTF-8` to the required entry.