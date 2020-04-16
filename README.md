# plexargod
Plex Argo Daemon - A systemd script to update the Plex API to use the current cloudflared tunnel address for remote access

## Create a **free** Cloudflare Argo Tunnel to your Plex Media Server

Enables fast remote access to your Plex Media Server, even behind a carrier grade NAT or VPN with no port-forwarding ability.

**NOTE:** Do not add `localhost, 127.0.0.1, or ::1` to the `Settings/Network/List of IP addresses and networks that are allowed without auth` box. That will allow anyone with your Plex Argo URL (anyone that is a member of your server) to access the Admin WebUI with no access controls.

## What is CloudFlare Argo?

Read the [The Cloudflare Blog - A free Argo Tunnel for your next project](https://blog.cloudflare.com/a-free-argo-tunnel-for-your-next-project/).

TL;DR - **Free TryCloudFlare** Argo Tunnel features:
 - Operate much like a Reverse SSH tunnel + nginx on a remote VPS
 - A golang cross-platform tunneling daemon ([cloudflared](https://developers.cloudflare.com/argo-tunnel/downloads/))
 - Unique URLs per session (i.e. apple-bali-matters-local.trycloudflare.com)
 - Support for http:80 & https:443
 - Free to use and no bandwidth restrictions
 - No account or authentication requirements
 - Simplier setup with _much_ less overhead

# this is a work in progress

## Plex API Endpoints

When you specify a custom connection URL in your Plex Media Server, it will publish that URL in the Plex API. This allows all your clients to discover alternative paths to your server. 

There are four Plex API endpoints that are used to facilitate plexargod:
All Plex API endpoints require a valid X-Plex-Token (Header or Embedded in the URL)
 - `${PlexServerURL}/:/prefs`
   - `GET` to read the current preferences
   - `PUT` to change any of the preferences
 - `${PlexServerURL}/:/prefs`
   - `GET` machineIdentifier

- (fill in more later)
- add screenshots of authorized apps

This published information can be seen for your server by going to `https://plex.tv/api/resources?X-Plex-Token=YOUR_API_TOKEN`

## setup - rough notes

- Have cloudflared already installed and running as a service with a metrics server (see https://github.com/danielewood/misc/tree/master/plex-argo)
- Place plexargod in /usr/local/bin/
- chmod 755 /usr/local/bin/plexargod
- run plexargod, follow onscreen instructions
  - Open browser signed in to your Plex Account to https://plex.tv/link
  - Enter the four digit code in the console
- Process will exit.
- If your plex server is not at `http://localhost:32400`, edit your 
`/etc/argoplexd/argoplexd.conf` (the first run will automatically generate it) and update PlexServerURL
- If your already have cloudflared setup as a service, edit your service definition to make `plexargod` fully automatic.

## Remote Access Tunnel Setup

You will need [cloudflared](https://developers.cloudflare.com/argo-tunnel/downloads/) installed and running as a service

```bash
sudo mkdir -p /etc/cloudflared
sudo bash -c "cat<<'EOF'>/etc/cloudflared/config.yml
url: http://localhost:32400
metrics: localhost:33400
EOF"
sudo cloudflared service install
```

Next, update the service file with hooks for plexargod:
```bash
ExecStartPost=/usr/local/bin/plexargod
Environment=RUN_BY_SYSTEMD=1
```

```bash
sudo bash -c "cat<<'EOF'>/etc/systemd/system/cloudflared.service
[Unit]
Description=Argo Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/local/bin/cloudflared --config /etc/cloudflared/config.yml --origincert /etc/cloudflared/cert.pem --no-autoupdate
ExecStartPost=/usr/local/bin/plexargod
Environment=RUN_BY_SYSTEMD=1
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl restart cloudflared
```
