# onedrive docker image

Thats right folks onedrive is now dockerized ;)

This container offers simple monitoring-mode service for 'Free Client for OneDrive on Linux'.

## Basic Setup

### 0. Install docker under your own platform's instructions

### 1. Pull the image

```bash
docker pull driveone/onedrive
```

**NOTE:** SELinux context needs to be configured or disabled for Docker, to be able to write to OneDrive host directory.

### 2. Prepare config volume

Onedrive needs two volumes. One of them is the config volume. Create it with:

```bash
docker volume create onedrive_conf
```

This will create a docker volume labeled `onedrive_conf`, where all configuration of your onedrive account will be stored. You can add a custom config file and other things later.

The second docker volume is for your data folder and is created in the next step. It needs the path to a folder on your filesystem that you want to keep in sync with OneDrive. Keep in mind that:

-   The owner of your specified folder must not be root

-   The owner of your specified folder must have permissions for its parent directory

### 3. First run

Onedrive needs to be authorized with your Microsoft account. This is achieved by running docker in interactive mode. Run the docker image with the two commands below and **make sure to change `onedriveDir` to the onedrive data directory on your filesystem (e.g. `"/home/abraunegg/OneDrive"`)**

```bash
onedriveDir="${HOME}/OneDrive"
docker run -it --restart unless-stopped --name onedrive -v onedrive_conf:/onedrive/conf -v "${onedriveDir}:/onedrive/data" driveone/onedrive
```

-   You will be asked to open a specific link using your web browser 
-   Login to your Microsoft Account and give the application the permission 
-   After giving the permission, you will be redirected to a blank page.  
-   Copy the URI of the blank page into the application.

The onedrive monitor is configured to start with your host system. If your onedrive is working as expected, you can detach from the container with Ctrl+p, Ctrl+q.

### 4. Status, stop, and restart

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

Remove onedrive monitor

```bash
docker rm -f onedrive
```
## Advanced Setup

### 5. Edit the config

Onedrive should run in default configuration, however you can change your configuration by placing a custom config file in the `onedrive_conf` docker volume. First download the default config from [here](https://raw.githubusercontent.com/abraunegg/onedrive/master/config)  
Then put it into your onedrive_conf volume path, which can be found with:  

```bash
docker volume inspect onedrive_conf
```

Or you can map your own config folder to the config volume. Make sure to copy all files from the docker volume into your mapped folder first.

The detailed document for the config can be found here: [additional-configuration](https://github.com/abraunegg/onedrive#additional-configuration)

### 6. Sync multiple accounts

There are many ways to do this, the easiest is probably to
1. Create a second docker config volume (replace `Work` with your desired name):  `docker volume create onedrive_conf_Work`
2. And start a second docker monitor container (again replace `Work` with your desired name):
```
onedriveDirWork="/home/abraunegg/OneDriveWork"
docker run -it --restart unless-stopped --name onedrive_Work -v onedrive_conf_Work:/onedrive/conf -v "${onedriveDirWork}:/onedrive/data" driveone/onedrive
```

## Run or update with one script

If you are experienced with docker and onedrive, you can use the following script:

```bash
# Update onedriveDir with correct existing OneDrive directory path
onedriveDir="${HOME}/OneDrive"

firstRun='-d'
docker pull driveone/onedrive
docker inspect onedrive_conf > /dev/null || { docker volume create onedrive_conf; firstRun='-it'; }
docker inspect onedrive > /dev/null && docker rm -f onedrive
docker run $firstRun --restart unless-stopped --name onedrive -v onedrive_conf:/onedrive/conf -v "${onedriveDir}:/onedrive/data" driveone/onedrive
```


## Environment Variables


| Variable | Purpose | Sample Value  |
| ---------------- | --------------------------------------------------- |:-------------:|
| <B>ONEDRIVE_UID</B> | UserID (UID) to run as  | 1000 |
| <B>ONEDRIVE_GID</B> | GroupID (GID) to run as | 1000 |
| <B>ONEDRIVE_VERBOSE</B> | Controls "--verbose" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_DEBUG</B> | Controls "--verbose --verbose" switch on onedrive sync. Default is 0 | 1 |
| <B>ONEDRIVE_RESYNC</B> | Controls "--resync" switch on onedrive sync. Default is 0 | 1 |

### Usage Examples
**Verbose Output:**
```bash
docker container run -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf -v "${onedriveDir}:/onedrive/data" driveone/onedrive
```
**Debug Output:**
```bash
docker container run -e ONEDRIVE_DEBUG=1 -v onedrive_conf:/onedrive/conf -v "${onedriveDir}:/onedrive/data" driveone/onedrive
```
**Perform a --resync:**
```bash
docker container run -e ONEDRIVE_RESYNC=1 -v onedrive_conf:/onedrive/conf -v "${onedriveDir}:/onedrive/data" driveone/onedrive
```
**Perform a --resync and --verbose:**
```bash
docker container run -e ONEDRIVE_RESYNC=1 -e ONEDRIVE_VERBOSE=1 -v onedrive_conf:/onedrive/conf -v "${onedriveDir}:/onedrive/data" driveone/onedrive
```

## Build instructions
You can also build your own image instead of pulling the one from dockerhub:
```bash
git clone https://github.com/abraunegg/onedrive
cd onedrive
docker build . -t local-onedrive -f contrib/docker/Dockerfile
```

There are alternate, smaller images available by building
Dockerfile-stretch or Dockerfile-alpine.  These [multi-stage builder
pattern](https://docs.docker.com/develop/develop-images/multistage-build/)
Dockerfiles require Docker version at least 17.05.

``` bash
docker build . -t local-ondrive-stretch -f contrib/docker/Dockerfile-stretch
```
or

``` bash
docker build . -t local-ondrive-alpine -f contrib/docker/Dockerfile-alpine
```
