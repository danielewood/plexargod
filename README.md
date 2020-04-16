# plexargod
 A systemd script to update the Plex API to use the current cloudflared tunnel address for remote access

# this is a work in progress
## setup - rough notes
- Have cloudflared already installed and running as a service with a metrics server (see https://github.com/danielewood/misc/tree/master/plex-argo)
- Place plexargod in /usr/loca/bin/
- chmod 755 /usr/loca/bin/plexargod
- run plexargod, follow onscreen instructions
  - Open browser signed in to your Plex Account to https://plex.tv/link
  - Enter the four digit code in the console
- Process will exit.
- If your plex server is not at `http://localhost:32400`, edit your 
`/etc/argoplexd/argoplexd.conf` (the first run will automatically generate it) and update PlexServerURL
- If your already have cloudflared setup as a service, edit your service definition to make `plexargod` fully automatic.
- Example:
```bash
cat<<'EOF'>/etc/systemd/system/cloudflared.service
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
EOF

systemctl daemon-reload
systemctl restart cloudflared
```
