#!/bin/bash

plexargodVersion='0.1.0'
INTERACTIVE=false
[ -t 0 ] && INTERACTIVE=true

case "$1" in
    --interactive) INTERACTIVE=true ;;
    --install)
        if [[ $EUID -ne 0 ]]; then
            echo "$0 --install must be run as root"
            exit 1
        fi
        INSTALL_PATH="/usr/local/bin/plexargod"
        if [ ! -f "${INSTALL_PATH}" ] || [ "$(readlink -f "$0" 2>/dev/null)" != "$(readlink -f "${INSTALL_PATH}" 2>/dev/null)" ]; then
            curl -fsSL "https://raw.githubusercontent.com/danielewood/plexargod/main/plexargod.sh" -o "${INSTALL_PATH}"
            chmod 755 "${INSTALL_PATH}"
            echo "Installed plexargod to ${INSTALL_PATH}"
        fi
        PLEX_URL="${2:-http://localhost:32400}"
        cat <<UNIT > /etc/systemd/system/plexargod.service
[Unit]
Description=Plex Argo Daemon
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url ${PLEX_URL} --metrics localhost:33400
ExecStartPost=/usr/local/bin/plexargod
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable plexargod
        echo "plexargod.service installed and enabled."
        echo "Run '$0 --interactive' to set up your Plex token, then 'systemctl start plexargod'."
        exit 0
        ;;
esac

if [[ $EUID -ne 0 ]]; then
   echo "$0 must be run as root to modify the config files"
   exit 1
fi

if command -v prlimit >/dev/null 2>&1 && pidof cloudflared >/dev/null 2>&1; then
    LimitNOFILE=524288
    # If the prlimit command is available, we'll use it to modify the cloudflared process to increase the maximum number of open files
    #   This is because eventually cloudflared uses too many file handles and hangs,
    #   the metricsWatchdog function will poll for this eventuality and cause the process to exit, systemd will the restart the process.
    prlimit --nofile=${LimitNOFILE} --pid="$(pidof cloudflared)" && systemd-cat -t "${0##*/}" -p info <<<"cloudflared was successfully modified with a LimitNOFILE of ${LimitNOFILE}"
    # check current limits with:
    # sudo cat /proc/$(pidof cloudflared)/limits
fi

### Variable Setup

# Write a key=value pair to the config file (update if exists, append if not)
conf_set() {
    if grep -q "^$1=" "${plexargod_conf}" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "${plexargod_conf}"
    else
        echo "$1=$2" >> "${plexargod_conf}"
    fi
}

[ -z "${plexargod_path}" ] && plexargod_path="/etc/plexargod"
[ -z "${plexargod_conf}" ] && plexargod_conf="${plexargod_path}/plexargod.conf"

# give a warning if cloudflared cant open its port to Plex, it probably means that Plex isnt running or is unreachable
ArgoOriginDown=$(journalctl -t cloudflared -n20 | grep -oP 'msg="unable to connect to the origin[^}]+')
if [ "${ArgoOriginDown}" ]; then
    systemd-cat -t "${0##*/}" -p warning <<<"cloudflared was unable to contact the origin, is Plex running?"
fi

# If plexargod config directory does not exist, create it
if [ ! -d "${plexargod_path}" ]; then
    mkdir -p "${plexargod_path}"
else
    echo "Using config path of ${plexargod_path}"
fi

# If plexargod config exists
#   load variables from it
# else
#   create the conf with a comment line at the top
if [ -f "${plexargod_conf}" ]; then
    # shellcheck source=/dev/null
    source "${plexargod_conf}"
    echo "Sourced ${plexargod_conf}"
else
    echo "# ${plexargod_conf}" > "${plexargod_conf}"
fi

# if VARIABLE is empty/malformed, use defaults
[ -z "${XPlexVersion}" ] && XPlexVersion="${plexargodVersion}"
echo "XPlexVersion = ${XPlexVersion}"

# if VARIABLE is empty/malformed, use defaults
[ -z "${PlexServerURL}" ] && PlexServerURL='http://localhost:32400'
echo "PlexServerURL = ${PlexServerURL}"

# if VARIABLE is empty/malformed, use defaults
[ -z "${ArgoMetricsURL}" ] && ArgoMetricsURL='http://localhost:33400'
echo "ArgoMetricsURL = ${ArgoMetricsURL}"

# if VARIABLE is empty/malformed, set and overwrite it in the config
if [ -z "${XPlexProduct}" ]; then
    echo 'Setting XPlexProduct'
    XPlexProduct='plexargod'
    conf_set XPlexProduct "${XPlexProduct}"
fi
echo "XPlexProduct = ${XPlexProduct}"

# if VARIABLE is empty/malformed, set and overwrite it in the config
if [ -z "${XPlexClientIdentifier}" ]; then
    echo 'Setting XPlexClientIdentifier'
    XPlexClientIdentifier=$(cat /proc/sys/kernel/random/uuid)
    conf_set XPlexClientIdentifier "${XPlexClientIdentifier}"
fi
echo "XPlexClientIdentifier = ${XPlexClientIdentifier}"

### Function Creation

function Get-XPlexToken {
    if ! $INTERACTIVE; then
        systemd-cat -t "${0##*/}" -p err <<<"No X-Plex-Token set in ${plexargod_conf}. Run '$0' interactively to perform first-time setup."
        exit 1
    fi

    while true; do
        CURL_CONTENT=$(curl -X "POST" -s -i "https://plex.tv/pins.xml" \
            -H "X-Plex-Version: ${XPlexVersion}" \
            -H "X-Plex-Product: ${XPlexProduct}" \
            -H "X-Plex-Client-Identifier: ${XPlexClientIdentifier}")
        PlexPinLink=$(grep -oP '^[Ll]ocation:\ \K.+' <<<"${CURL_CONTENT}" | tr -dc '[:print:]')
        PlexPinCode=$(grep -oP '\<code\>\K[A-Z0-9]{4}' <<<"${CURL_CONTENT}")

        echo "Go to $(tput setaf 2)https://plex.tv/link$(tput sgr 0) and enter $(tput setaf 2)${PlexPinCode}$(tput sgr 0)"
        echo -n "Waiting for code entry on the Plex API.."

        local i=0
        unset XPlexToken
        while [ -z "$XPlexToken" ] && [ $i -lt 120 ]; do
            echo -n '.'
            sleep 2
            XPlexToken=$(curl -X "GET" -s "${PlexPinLink}" \
                -H "X-Plex-Version: ${XPlexVersion}" \
                -H "X-Plex-Product: ${XPlexProduct}" \
                -H "X-Plex-Client-Identifier: ${XPlexClientIdentifier}" |
                grep -oP '\"auth_token":"\K[^",}]+')
            i=$((i + 1))
        done
        echo ""

        if [ -n "$XPlexToken" ]; then
            break
        fi
        echo "Code ${PlexPinCode} has expired after 4 minutes, generating new code."
    done
    conf_set XPlexToken "${XPlexToken}"
    echo "XPlexToken set in ${plexargod_conf}"
}

function Get-PlexUserInfo {
    curl -s -X "POST" "https://plex.tv/users/sign_in.json" \
        -H "X-Plex-Version: ${XPlexVersion}" \
        -H "X-Plex-Product: ${XPlexProduct}" \
        -H "X-Plex-Client-Identifier: ${XPlexClientIdentifier}" \
        -H "X-Plex-Token: ${XPlexToken}"
}

function Get-ArgoURL {
    ArgoURL=$(curl -s -m5 "${ArgoMetricsURL}/metrics" | grep -oP 'userHostname="https://\K[^"]*\.trycloudflare\.com' | head -n1)
    if [ "$ArgoURL" ]; then
        echo "ArgoURL = ${ArgoURL}"
    else
        echo "Failed to get ArgoURL from cloudflared"
        exit 1
    fi
}

# shellcheck disable=SC2317
function Get-PlexServerPrefs {
    curl -s "${PlexServerURL}/:/prefs" \
        -H "X-Plex-Version: ${XPlexVersion}" \
        -H "X-Plex-Product: ${XPlexProduct}" \
        -H "X-Plex-Client-Identifier: ${XPlexClientIdentifier}" \
        -H "X-Plex-Token: ${XPlexToken}"
}

function Set-PlexServerPrefs {
    # add if/then for secure only switch later (if secure, "https://${ArgoURL}:443")
    customConnections="https://${ArgoURL}:443,http://${ArgoURL}:80"
    curl -s -X "PUT" "${PlexServerURL}/:/prefs?customConnections=${customConnections}&RelayEnabled=0&PublishServerOnPlexOnlineKey=0" \
        -H "X-Plex-Version: ${XPlexVersion}" \
        -H "X-Plex-Product: ${XPlexProduct}" \
        -H "X-Plex-Client-Identifier: ${XPlexClientIdentifier}" \
        -H "X-Plex-Token: ${XPlexToken}"
}

function Validate-PlexAPIcustomConnections {
    declare -i i; i=0
    while [[ "$ArgoURL" != "$PlexAPIcustomConnections" ]]
    do
        PlexServerProcessedMachineIdentifier=$(curl -s "${PlexServerURL}" -H "X-Plex-Token: ${XPlexToken}" | grep -oP 'machineIdentifier\=\"\K[^"]*')
        if [ -z "${PlexServerProcessedMachineIdentifier}" ]; then
            systemd-cat -t "${0##*/}" -p err <<<"Plex Server instance did not return an identifier, is it down?"
            echo "curl output for ${PlexServerURL}"
            curl -vs "${PlexServerURL}" -H "X-Plex-Token: ${XPlexToken}"
            exit 1
        else
            echo "PlexServerProcessedMachineIdentifier = ${PlexServerProcessedMachineIdentifier}"
        fi
        # Extract the entire Device block for the machine identifier
        device_block=$(curl -s "https://plex.tv/api/resources?X-Plex-Token=${XPlexToken}" |
            sed -n '/clientIdentifier="'"${PlexServerProcessedMachineIdentifier}"'"/,/<\/Device>/p')
        # Extract the Argo URL from the device block
        PlexAPIcustomConnections=$(echo "$device_block" |
            grep -oP 'address="\K[^"]*\.trycloudflare\.com' |
            head -n1)
        if [ $i -ge 15 ]; then
            systemd-cat -t "${0##*/}" -p err <<<"Plex API does not match cloudflared URLs after 30 seconds."
            exit 1
        fi
        i=$((i + 1))
        sleep 2
    done
}

function metricsWatchdog() {
    while true; do
        sleep 30
        curl -s -m15 "${ArgoMetricsURL}" >/dev/null 2>&1
        metricsReturnCode=$?
        if [[ $metricsReturnCode -ne 0 ]]; then
           systemd-cat -t "${0##*/}" -p emerg <<<"cloudflared metrics server was unresponsive: (curl return code = ${metricsReturnCode}); restarting "
           kill -9 "$(pgrep -f cloudflared)"
        fi
    done
}

### Execution Section

[ -z "${XPlexToken}" ] && Get-XPlexToken
if [ "$(Get-PlexUserInfo)" == '{"error":"Invalid authentication token."}' ]; then
    echo "X-Plex-Token is invalid, requesting new token"
    Get-XPlexToken
else
    echo "X-Plex-Token is valid"
fi

if $INTERACTIVE; then
    echo "Token setup complete. Start the plexargod service to activate the tunnel."
    exit 0
fi

Get-ArgoURL
Set-PlexServerPrefs
Validate-PlexAPIcustomConnections
echo "Plex API is updated with the current Argo Tunnel Address."

metricsWatchdog > /dev/null 2>&1 & disown

exit 0
