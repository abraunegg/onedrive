# Show how to access specific Microsoft Azure deployments
In some cases it is a requirement to utilise specific Microsoft Azure cloud deployments to conform with data and security reuqirements that requires data to reside within the geographic borders of that country.
Current national clouds that are supported are:
*   Microsoft Cloud for US Government
*   Microsoft Cloud Germany
*   Azure and Office 365 operated by 21Vianet in China

To configure your client to utilise one of these national cloud deployments, configure your client in the following fashion:

Add to your 'onedrive' configuration file (`~/.config/onedrive/config`)the following:
```text
azure_ad_endpoint = "insert valid entry here"
```

Valid entries are:
*   USL4
*   USL5
*   DE
*   CN

This will configure your client to use the correct Azure AD and Graph endpoints as per [https://docs.microsoft.com/en-us/graph/deployments](https://docs.microsoft.com/en-us/graph/deployments)

Example:
```text
azure_ad_endpoint = "USL4"
```
