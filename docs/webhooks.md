# How to configure receiving Real-time Changes from Microsoft OneDrive Service

When operating in 'Monitor Mode,' receiving real-time updates to online data can significantly enhance synchronisation efficiency. This is achieved by enabling 'webhooks,' which allows the client to subscribe to remote updates.

With this setup, any remote changes are promptly synchronised to your local file system, eliminating the need to wait for the next scheduled synchronisation cycle.

> [!IMPORTANT]
> In March 2023, Microsoft updated the webhook notification capability in Microsoft Graph to only allow valid HTTPS URLs as the destination for subscription updates.
>
> This change was part of Microsoft's ongoing efforts to enhance security and ensure that all webhooks used with Microsoft Graph comply with modern security standards. The enforcement of this requirement prevents the registration of subscriptions with non-secure (HTTP) endpoints, thereby improving the security of data transmission.
>
> Therefore, as a prerequisite, you must have a valid fully qualified domain name (FQDN) for your system that is externally resolvable, or configure Dynamic DNS (DDNS) using a provider such as:
> * No-IP
> * DynDNS
> * DuckDNS
> * Afraid.ord
> * Cloudflare
> * Google Domains
> * Dynu
> * ChangeIP
>
> This FQDN will allow you to create a valid HTTPS certificate for your system, which can be used by Microsoft Graph for webhook functionality.
>
> Please note that it is beyond the scope of this document to provide guidance on setting up these configurations.

Depending on your environment, a number of steps are required to configure this application functionality. At a very high level these configuration steps are:

1. Application configuration to enable 'webhooks' functionality
2. Install and configure 'nginx' as a reverse proxy for HTTPS traffic
3. Install and configure Let's Encrypt 'certbot' to provide a valid HTTPS certificate for your system using your FQDN
4. Configure your Firewall or Router to forward traffic to your system

> [!NOTE]
> The configuration below was validated on Fedora 39.
>
> The installation of required components (nginx, certbot) for your platform is beyond the scope of this document and it is assumed you know how to install these components. If you are unsure, please seek support from your Linux distribution support channels.



### 1. Application configuration

#### Enable feature
*  In your 'config' file, set `webhook_enabled = "true"` to activate the webhook feature.

#### Configure the public notification URL
*  In your 'config' file, set `webhook_public_url = "http://<your.fully.qualified.domain.name>/webhooks/onedrive"` as the public URL that will receive subscription updates from the Microsoft Graph API platform.

> [!NOTE]
> This URL should utilise your FQDN and be resolvable from the Internet. This URL will also be used within your 'nginx' configuration.

### 2. Install and configure 'nginx'
*   **Setup Nginx as a Reverse Proxy:** Configure Nginx to listen on port 443 for HTTPS traffic. It should proxy incoming webhook notifications to the internal webhook listener running on the client

### 3. Firewall/Router Configuration
*   **Port Forwarding:** Ensure that your firewall or router is configured to forward incoming HTTPS traffic on port 443 to the internal IP address of your Nginx server. This setup allows external webhook notifications from the Microsoft Graph API to reach your Nginx server and subsequently be proxied to the local webhook listener.

When these steps are followed, your environment configuration will be similar to the following diagram:

![webhooks](./puml/webhooks.png)

Refer to [application-config-options.md](application-config-options.md) for further guidance on 'webhook' configuration.
