# Show how to access a Sharepoint group drive in Office 365 business or education
## Obtaining the Sharepoint Site Details
1.  Login to OneDrive and under 'Shared Libraries' obtain the shared library name
2.  Run the following command using the 'onedrive' client
```bash
onedrive --get-O365-drive-id '<your library name>'
```
3. This will return the following:
```bash
Initializing the Synchronization Engine ...
Office 365 Library Name: ab-github-odtest
drive_id: b!6H.....l7vVxU5
```

## Configuring the onedrive client
Once you have obtained the 'drive_id' above, add to your 'onedrive' configuration file (`~/.config/onedrive/config`)the following:
```
drive_id = "insert the drive id from above here"
```

The OneDrive client will now sync this SharePoint shared library to your local system.
