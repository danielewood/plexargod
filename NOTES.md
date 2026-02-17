# Session Notes - 2026-02-16

## Issue Triage (10 open issues)

### Already resolved / answered - close with comment

| Issue | Title | Resolution |
|-------|-------|------------|
| #9 | Systemd service stuck on activating | Fixed by PR #12 (commit bb8a67a) |
| #6 | Adding Service lines | Answered in comments with full example |
| #4 | Installing on a raspberry pi? | Answered - use arm binary from GitHub releases |
| #15 | Failed to get ArgoURL from cloudflared | cloudflared wasn't running; answered in comments |

### Support questions - close with brief response

| Issue | Title | Response |
|-------|-------|----------|
| #14 | Certs | TryCloudflare tunnels handle TLS transparently, no cert.pem needed |
| #13 | How to restart tunnel? | `systemctl restart plexargod` should work; if stuck, `systemctl stop plexargod && sleep 2 && systemctl start plexargod` |
| #8 | Regarding stats and cert.pem | cert.pem not needed for TryCloudflare; metrics available at configured metrics URL |

### Addressed by README update

| Issue | Title | Notes |
|-------|-------|-------|
| #17 | Cannot create cloudflare service without TUNNEL-UUID | Old `cloudflared service install` doesn't work for quick tunnels. README now shows manual systemd unit with `cloudflared tunnel --url` |

### External / third-party - close as won't fix

| Issue | Title | Notes |
|-------|-------|-------|
| #18 | Media doesn't play, "stream cancelled" errors | cloudflared stream cancellation - upstream issue, not plexargod |
| #16 | Docker image doesn't work | References unofficial third-party Docker image (sequ3ster/plexargod) |

## Cloudflared Modernization Research

Key findings from researching cloudflared 2025-2026:

1. **Quick tunnels** (`cloudflared tunnel --url`) don't need config.yml, cert.pem, or a Cloudflare account
2. **`cloudflared service install`** is only for named tunnels (requires account + tunnel UUID + credentials)
3. **Installation** now via official apt repo at `pkg.cloudflare.com` (GPG key rotated recently)
4. **Metrics endpoint** still exposes `userHostname` in Prometheus format - plexargod's `Get-ArgoURL` function still works
5. **`--no-autoupdate`** still supported
6. **Config files are incompatible** with quick tunnels - must use CLI flags
7. **Quick tunnel limits**: 200 concurrent requests, no SSE support

## What needs testing on a live Plex machine

1. Install cloudflared via apt repo
2. Create systemd service with new `ExecStart` line (`cloudflared tunnel --url`)
3. Run plexargod interactively for first-run auth (plex.tv/link flow)
4. Verify `Get-ArgoURL` correctly extracts tunnel hostname from metrics
5. Verify `Set-PlexServerPrefs` updates Plex with tunnel addresses
6. Verify `Validate-PlexAPIcustomConnections` sees the published URL
7. Test remote playback through the tunnel
8. Verify `metricsWatchdog` works correctly under systemd
9. Test the `prlimit` file handle increase on the cloudflared process

## Architecture Notes

- **plexargod.sh** (229 lines) - Single bash script, runs as root
- **Config**: `/etc/plexargod/plexargod.conf` stores XPlexToken, XPlexClientIdentifier, XPlexProduct
- **Flow**: Load config → validate Plex token → get ArgoURL from metrics → update Plex prefs → validate via Plex API → start watchdog
- **config.yml reading** (lines 27-30): Optional - reads PlexServerURL and ArgoMetricsURL from cloudflared config if it exists, falls back to defaults (localhost:32400 / localhost:33400)
- **metricsWatchdog**: Polls cloudflared metrics every 30s, kills cloudflared if unresponsive (systemd restarts it)
