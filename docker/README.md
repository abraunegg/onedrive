# onedrive docker image

Thats right folks onedrive is now dockerized ;)

This container offers simple monitoring-mode service for OneDrive.

## Build instructions
```
cd docker
git clone https://github.com/abraunegg/onedrive
docker build . -t onedrive
```

## Usage instructions
NOTE:
> SELinux context needs to be configured or disabled for Docker, to be able to write to OneDrive host directory.

Replace /home/user/OneDrive with your actual OneDrive host directory
Replace onedrive_container_name with meaningful name (like onedrive_user_hotmail)

1. Register new onedrive monitor
Follow instructions on terminal.  
For reguler usage this should be only command needed.
```
docker run -it --restart unless-stopped --name onedrive_container_name -v /home/user/OneDrive:/onedrive/data onedrive
# you can close terminal, docker will continue its work in background
```
## Poweruser section
1. Check if monitor service is running
```
docker ps -f name=onedrive_container_name
```
2. Show monitor run logs
```
docker logs onedrive_container_name
```
3. Stop running monitor
```
docker stop onedrive_container_name
```
4. Resume monitor
```
docker start onedrive_container_name
```
5. Unregister onedrive monitor
```
docker rm -f onedrive_container_name
```

