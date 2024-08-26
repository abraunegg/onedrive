# How to configure receiving Real-time Changes from Microsoft OneDrive Service

When operating in 'Monitor Mode,' receiving real-time updates to online data can significantly enhance synchronisation efficiency. This is achieved by enabling 'webhooks,' which allows the client to subscribe to remote updates.

With this setup, any remote changes are promptly synchronised to your local file system, eliminating the need to wait for the next scheduled synchronisation cycle.

> [!IMPORTANT]
> Microsoft changed the webhook notification capability to only allow valid HTTPS URL's as the URL that will receive subscription updates from Microsoft.
>
> A prerequsite requirement is that you either have a valid fully qualified domain name (FQDN) for your system available that is resolvable externally, or you configure Dynamic DNS for your system using providers such as:
> * No-IP
> * DynDNS
> * DuckDNS
> * Afraid.ord
> * Cloudflare
> * Google Domains
> * Dynu
> * ChangeIP
>
> It is beyond the scope of this document to assist with setting this up for you.

Depending on your environment, a number of steps are required to configure this capability. At a high level these configuration steps are:

1. Application configuration to enable functionality
2. Install and configure 'nginx' as a reverse proxy for HTTPS traffic
3. Install and configure Let's Encrypt 'certbot' to provide a valid HTTPS certificate for your system using your FQDN
3. Configure your Firewall or Router to forward traffic to your system



#### 1. Application configuration
*   **Enable Webhooks:** In your 'config' file, set `webhook_enabled = "true"` to activate the webhook feature.
*   **Configure Webhook URL:** In your 'config' file, set `webhook_public_url = "http://<your_host_ip>:8888/"` to provide the public URL that will receive subscription updates from the remote server. This URL should be accessible from the internet and typically points to your Nginx configuration.

#### 2. Install and configure 'nginx'
*   **Setup Nginx as a Reverse Proxy:** Configure Nginx to listen on port 443 for HTTPS traffic. It should proxy incoming webhook notifications to the internal webhook listener running on the client

#### 3. Firewall/Router Configuration
*   **Port Forwarding:** Ensure that your firewall or router is configured to forward incoming HTTPS traffic on port 443 to the internal IP address of your Nginx server. This setup allows external webhook notifications from the Microsoft Graph API to reach your Nginx server and subsequently be proxied to the local webhook listener.

When these steps are followed, your environment configuration will be similar to the following diagram:

![webhooks](./puml/webhooks.png)

Refer to [application-config-options.md](application-config-options.md) for further guidance on 'webhook' configuration.
