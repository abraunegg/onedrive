# Run the OneDrive Client for Linux under Docker
This client can be run as a Docker container, with 3 available options for you to choose from:

| Container Base | Docker Tag  | Description                                                    | x86_64 | ARMHF | AARCH64 |
|----------------|-------------|----------------------------------------------------------------|:------:|:-----:|:-------:|
| Alpine Linux   | edge-alpine | Docker container based on Apline 3.16 using 'master'           |✔|❌|✔|
| Alpine Linux   | alpine      | Docker container based on Apline 3.16 using latest release     |✔|❌|✔|
| Debian         | edge-debian | Docker container based on Debian Bullseye using 'master'       |✔|✔|✔|
| Debian         | debian      | Docker container based on Debian Bullseye using latest release |✔|✔|✔|
| Fedora         | edge        | Docker container based on Fedora 36 using 'master'             |✔|✔|✔|
| Fedora         | latest      | Docker container based on Fedora 36 using latest release       |✔|✔|✔|
| Fedora         | edge-fedora | Docker container based on Fedora 36 using 'master'             |✔|✔|✔|
| Fedora         | fedora      | Docker container based on Fedora 36 using latest release       |✔|✔|✔|

These containers offer a simple monitoring-mode service for the OneDrive Client for Linux.

The instructions below have been validated on:
*   Red Hat Enterprise Linux 8.x 
*   Ubuntu Server 22.04

The instructions below will utilise the 'latest' tag, however this can be substituted for any of the other docker tags from the table above if desired.

Additionally there are specific version release tags for each release. Refer to https://hub.docker.com/r/driveone/onedrive/tags for any other Docker tags you may be interested in.

## Basic Setup
### 0. Install docker using your distribution platform's instructions
1.  Ensure that SELinux has been disabled on your system. A reboot may be required to ensure that this is correctly disabled.
2.  Install Docker as per requried for your platform. Refer to https://docs.docker.com/engine/install/ for assistance.
3.  Obtain your normal, non-root user UID and GID by using the `id` command
4.  As your normal, non-root user, ensure that you can run `docker run hello-world` *without* using `sudo`

Once the above 4 steps are complete and you can successfully run `docker run hello-world` without sudo, only then proceed to 'Pulling and Running the Docker Image'

## Pulling and Running the Docker Image
### 1. Pull the image
```bash
docker pull driveone/onedrive:latest
```

**NOTE:** SELinux context needs to be configured or disabled for Docker to be able to write to OneDrive host directory.

### 2. Prepare config volume
The Docker container requries 2 Docker volumes:
*    Config Volume
*    Data Volume

Create the config volume with the following command:
```bash
docker volume create onedrive_conf
```

This will create a docker volume labeled `onedrive_conf`, where all configuration of your onedrive account will be stored. You can add a custom config file and other things later.

The second docker volume is for your data folder and is created in the next step. This volume needs to be a path to a directory on your local filesystem, and this is where your data will be stored from OneDrive. Keep in mind that:

*   The owner of this specified folder must not be root
*   The owner of this specified folder must have permissions for its parent directory

**NOTE:** Issues occur when this target folder is a mounted folder of an external system (NAS, SMB mount, USB Drive etc) as the 'mount' itself is owed by 'root'. If this is your use case, you *must* ensure your normal user can mount your desired target without having the target mounted by 'root'. If you do not fix this, your Docker container will fail to start with the following error message:
```bash
ROOT level privileges prohibited!
```

### 3. First run
The 'onedrive' client within the Docker container needs to be authorized with your Microsoft account. This is achieved by initially running docker in interactive mode. 

Run the docker image with the commands below and make sure to change `ONEDRIVE_DATA_DIR` to the actual onedrive data directory on your filesystem that you wish to use (e.g. `"/home/abraunegg/OneDrive"`).
```bash
export ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
mkdir -p ${ONEDRIVE_DATA_DIR}
docker run -it --name onedrive -v onedrive_conf:/onedrive/conf \
    -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" \
    -e "ONEDRIVE_UID=${ONEDRIVE_UID}" \
    -e "ONEDRIVE_GID=${ONEDRIVE_GID}" \
    driveone/onedrive:latest
```
**Important:** The 'target' folder of `ONEDRIVE_DATA_DIR` must exist before running the Docker container, otherwise, Docker will create the target folder, and the folder will be given 'root' permissions, which then causes the Docker container to fail upon startup with the following error message:
```bash
ROOT level privileges prohibited!
```
**NOTE:** It is also highly advisable for you to replace `${ONEDRIVE_UID}` and `${ONEDRIVE_GID}` with your actual UID and GID as specified by your `id` command output to avoid any any potential user or group conflicts.

**Example:**
```bash
export ONEDRIVE_UID=`id -u`
export ONEDRIVE_GID=`id -g`
export ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
mkdir -p ${ONEDRIVE_DATA_DIR}
docker run -it --name onedrive -v onedrive_conf:/onedrive/conf \
    -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" \
    -e "ONEDRIVE_UID=${ONEDRIVE_UID}" \
    -e "ONEDRIVE_GID=${ONEDRIVE_GID}" \
    driveone/onedrive:latest
```

When the Docker container successfully starts:
*   You will be asked to open a specific link using your web browser 
*   Login to your Microsoft Account and give the application the permission 
*   After giving the permission, you will be redirected to a blank page
*   Copy the URI of the blank page into the application prompt to authorise the application

Once the 'onedrive' application is authorised, the client will automatically start monitoring your `ONEDRIVE_DATA_DIR` for data changes to be uploaded to OneDrive. Files stored on OneDrive will be downloaded to this location.

If the client is working as expected, you can detach from the container with Ctrl+p, Ctrl+q.

### 4. Docker Container Status, stop, and restart
Check if the monitor service is running

```bash
docker ps -f name=onedrive
```

Show monitor run logs

```bash
docker logs onedrive
```

Stop running monitor

```bash
docker stop onedrive
```

Resume monitor

```bash
docker start onedrive
```

Remove onedrive Docker container

```bash
docker rm -f onedrive
```
## Advanced Setup

### 5. Docker-compose
Also supports docker-compose schemas > 3. 
In the following example it is assumed you have a `ONEDRIVE_DATA_DIR` environment variable and a `onedrive_conf` volume. 
However, you can also use bind mounts for the configuration folder, e.g. `export ONEDRIVE_CONF="${HOME}/OneDriveConfig"`.  

```
version: "3"
services:
    onedrive:
        image: driveone/onedrive:latest
        restart: unless-stopped
        environment:
            - ONEDRIVE_UID=${PUID}
            - ONEDRIVE_GID=${PGID}
        volumes: 
            - onedrive_conf:/onedrive/conf
            - ${ONEDRIVE_DATA_DIR}:/onedrive/data
```

Note that you still have to perform step 3: First Run. 

### 6. Edit the config
The 'onedrive' client should run in default configuration, however you can change this default configuration by placing a custom config file in the `onedrive_conf` docker volume. First download the default config from [here](https://raw.githubusercontent.com/abraunegg/onedrive/master/config)  
Then put it into your onedrive_conf volume path, which can be found with:  

```bash
docker volume inspect onedrive_conf
```

Or you can map your own config folder to the config volume. Make sure to copy all files from the docker volume into your mapped folder first.

The detailed document for the config can be found here: [Configuration](https://github.com/abraunegg/onedrive/blob/master/docs/USAGE.md#configuration)

### 7. Sync multiple accounts
There are many ways to do this, the easiest is probably to
1. Create a second docker config volume (replace `Work` with your desired name):  `docker volume create onedrive_conf_Work`
2. And start a second docker monitor container (again replace `Work` with your desired name):
```
export ONEDRIVE_DATA_DIR_WORK="/home/abraunegg/OneDriveWork"
mkdir -p ${ONEDRIVE_DATA_DIR_WORK}
docker run -it --restart unless-stopped --name onedrive_Work -v onedrive_conf_Work:/onedrive/conf -v "${ONEDRIVE_DATA_DIR_WORK}:/onedrive/data" driveone/onedrive:latest
```

## Run or update with one script
If you are experienced with docker and onedrive, you can use the following script:

```bash
# Update ONEDRIVE_DATA_DIR with correct OneDrive directory path
ONEDRIVE_DATA_DIR="${HOME}/OneDrive"
# Create directory if non-existant
mkdir -p ${ONEDRIVE_DATA_DIR} 

firstRun='-d'
docker pull driveone/onedrive:latest
docker inspect onedrive_conf > /dev/null 2>&1 || { docker volume create onedrive_conf; firstRun='-it'; }
docker inspect onedrive > /dev/null 2>&1 && docker rm -f onedrive
docker run $firstRun --restart unless-stopped --name onedrive -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:latest
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
| <B>ONEDRIVE_UPLOADONLY</B> | Controls "--upload-only" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_LOGOUT</B> | Controls "--logout" switch. Default is 0 | 1 |
| <B>ONEDRIVE_REAUTH</B> | Controls "--reauth" switch. Default is 0 | 1 |
| <B>ONEDRIVE_AUTHFILES</B> | Controls "--auth-files" option. Default is "" | "authUrl:responseUrl" |
| <B>ONEDRIVE_AUTHRESPONSE</B> | Controls "--auth-response" option. Default is "" | See [here](https://github.com/abraunegg/onedrive/blob/master/docs/USAGE.md#authorize-the-application-with-your-onedrive-account) |

### Usage Examples
**Verbose Output:**
```bash
docker container run -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:latest
```
**Debug Output:**
```bash
docker container run -e ONEDRIVE_DEBUG=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:latest
```
**Perform a --resync:**
```bash
docker container run -e ONEDRIVE_RESYNC=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:latest
```
**Perform a --resync and --verbose:**
```bash
docker container run -e ONEDRIVE_RESYNC=1 -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:latest
```

**Perform a --logout and re-authenticate:**
```bash
docker container run -it -e ONEDRIVE_LOGOUT=1 -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" driveone/onedrive:latest
```

## Build instructions
### Build Environment Requirements
*   Build environment must have at least 1GB of memory & 2GB swap space

There are 2 ways to validate this requirement:
*   Modify the file `/etc/dphys-swapfile` and edit the `CONF_SWAPSIZE`, for example: `CONF_SWAPSIZE=2048`. A reboot is required to make this change effective.
*   Dynamically allocate a swapfile for building:
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

### Building a custom Docker image
You can also build your own image instead of pulling the one from [hub.docker.com](https://hub.docker.com/r/driveone/onedrive):
```bash
git clone https://github.com/abraunegg/onedrive
cd onedrive
docker build . -t local-onedrive -f contrib/docker/Dockerfile
```

There are alternate, smaller images available by building
Dockerfile-debian or Dockerfile-alpine.  These [multi-stage builder
pattern](https://docs.docker.com/develop/develop-images/multistage-build/)
Dockerfiles require Docker version at least 17.05.

#### How to build and run a custom Docker image based on Debian
``` bash
docker build . -t local-ondrive-debian -f contrib/docker/Dockerfile-debian
docker container run -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" local-ondrive-debian:latest
```

#### How to build and run a custom Docker image based on Alpine Linux
``` bash
docker build . -t local-ondrive-alpine -f contrib/docker/Dockerfile-alpine
docker container run -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" local-ondrive-alpine:latest
```

#### How to build and run a custom Docker image for ARMHF (Raspberry Pi)
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

#### How to build and run a custom Docker image for AARCH64 Platforms
``` bash
docker build . -t local-onedrive-aarch64 -f contrib/docker/Dockerfile-debian
docker container run -v onedrive_conf:/onedrive/conf -v "${ONEDRIVE_DATA_DIR}:/onedrive/data" local-onedrive-aarch64:latest
```
