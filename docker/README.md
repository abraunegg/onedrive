# onedrive docker image

Thats right folks onedrive is now dockerized ;)

This container offers simple monitoring-mode service for 'Free Client for OneDrive on Linux'.

## Usage instructions
```
docker pull driveone/onedrive
```
**NOTE:** SELinux context needs to be configured or disabled for Docker, to be able to write to OneDrive host directory.

1.  Run or update onedrive container
```bash
# Update onedriveDir with correct existing OneDrive directory path
onedriveDir="${HOME}/OneDrive"

firstRun='-d'
docker pull driveone/onedrive
docker inspect onedrive_conf > /dev/null || { docker volume create onedrive_conf; firstRun='-it'; }
docker inspect onedrive > /dev/null && docker rm -f onedrive
docker run $firstRun --restart unless-stopped --name onedrive -v onedrive_conf:/onedrive/conf -v "${onedriveDir}:/onedrive/data" driveone/onedrive
```
## Poweruser section
1.  Check if monitor service is running
```bash
docker ps -f name=onedrive
```
2.  Show monitor run logs
```bash
docker logs onedrive
```
3.  Stop running monitor
```bash
docker stop onedrive
```
4.  Resume monitor
```bash
docker start onedrive
```
5.  Unregister onedrive monitor
```bash
docker rm -f onedrive
```
## Build instructions
```bash
cd docker
git clone https://github.com/abraunegg/onedrive
docker build . -t driveone/onedrive
```
