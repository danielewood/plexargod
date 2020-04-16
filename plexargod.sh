#! /bin/bash
if [[ $EUID -ne 0 ]]; then
   echo "$0 must be run as root to touch the config files"
   exit 1
fi

plexargod_path="/etc/plexargod"
plexargod_conf="${plexargod_path}/plexargod.conf"

# Get Plex and Metrics addresses from cloudflared, otherwise we'll pull or set after we import the plexargod.conf
if [ -f /etc/cloudflared/config.yml ]; then
    PlexServerURL=$(grep -oP '^url: \Khttp[^$]+' /etc/cloudflared/config.yml)
    ArgoMetrics=$(grep -oP '^metrics: \K[^$]+' /etc/cloudflared/config.yml)
fi

# give a warning if cloudflared cant open its port to Plex, it probably means that Plex isnt running or is unreachable
ArgoOriginDown=$(journalctl -t ${0##*/} -n20 | grep -oP 'msg="unable to connect to the origin[^}]+')
if [ ${ArgoOriginDown} ]; then
    systemd-cat -t ${0##*/} -p warning <<<"cloudflared was unable to contact the origin, is Plex running?"
fi

# If plexargod config directory does not exist, create it
if [ ! -d ${plexargod_path} ]; then
    mkdir -p ${plexargod_path}
else
    echo "${plexargod_path} exists"
fi

# If plexargod config exists
#   load variables from it
# else
#   create the conf with a comment line at the top
if [ -f ${plexargod_conf} ]; then
    . ${plexargod_conf}
    echo "Imported ${plexargod_conf}"
else
    echo "# ${plexargod_conf}" > ${plexargod_conf}
fi

# Set plexargod version string
[ -z ${XPlexVersion} ] && XPlexVersion='20.04.15.1000'
echo "XPlexVersion = ${XPlexVersion}"

# Pull Plex/Matrix from the config, if its absent there and in the config.yml, use defaults
[ -z ${PlexServerURL} ] && PlexServerURL='http://localhost:32400'
echo "PlexServerURL = ${PlexServerURL}"
[ ! -z ${ArgoMetrics} ] && ArgoMetricsURL="http://${ArgoMetrics}"
[ -z ${ArgoMetricsURL} ] && ArgoMetricsURL='http://localhost:33400'
echo "ArgoMetricsURL = ${ArgoMetricsURL}"

# if VARIABLE is empty/malformed, set and overwrite it in the config
if [ -z ${PlexServerURL} ]; then
    echo 'Setting PlexServerURL'
    PlexServerURL='http://localhost:32400'
    sed -e "/^PlexServerURL=/ c\\PlexServerURL\=${PlexServerURL}" \
        -e "\$aPlexServerURL=${PlexServerURL}" \
        -i ${plexargod_conf}
fi
echo "PlexServerURL = ${PlexServerURL}"

# if VARIABLE is empty/malformed, set and overwrite it in the config
if [ -z ${XPlexProduct} ]; then
    echo 'Setting XPlexProduct'
    XPlexProduct='plexargod'
    sed -e "/^XPlexProduct=/ c\\XPlexProduct\=${XPlexProduct}" \
        -e "\$aXPlexProduct=${XPlexProduct}" \
        -i ${plexargod_conf}
fi
echo "XPlexProduct = ${XPlexProduct}"

# if VARIABLE is empty/malformed, set and overwrite it in the config
if [ -z ${XPlexClientIdentifier} ]; then
    echo 'Setting XPlexClientIdentifier'
    XPlexClientIdentifier=$(cat /proc/sys/kernel/random/uuid)
    sed -e "/^XPlexClientIdentifier=/ c\\XPlexClientIdentifier=${XPlexClientIdentifier}" \
        -e "\$aXPlexClientIdentifier=${XPlexClientIdentifier}" \
        -i ${plexargod_conf}
fi
echo "XPlexClientIdentifier = ${XPlexClientIdentifier}"

function Get-XPlexToken {
    CURL_CONTENT=$(curl -X "POST" -s -i "https://plex.tv/pins.xml" \
        -H "X-Plex-Version: ${XPlexVersion}" \
        -H "X-Plex-Product: ${XPlexProduct}" \
        -H "X-Plex-Client-Identifier: ${XPlexClientIdentifier}")
    PlexPinLink=$(grep -oP 'Location:\ \K.+' <<<${CURL_CONTENT} | tr -dc '[[:print:]]')
    PlexPinCode=$(grep -oP '\<code\>\K[A-Z0-9]{4}' <<<${CURL_CONTENT})

    if [ ${RUN_BY_SYSTEMD} ]; then
        systemd-cat -t cloudflared -p emerg <<<"$(printf '%s\n' "${0##*/}"): You are running plexargod in non-interactive and you do not have a X-Plex-Token set in /etc/plexargod/plexargod.conf"
        systemd-cat -t cloudflared -p emerg <<<"$(printf '%s\n' "${0##*/}"): Run $0 in interactive mode, or go to https://plex.tv/link and enter the code ${PlexPinCode}"
    else
        echo "Go to $(tput setaf 2)https://plex.tv/link$(tput sgr 0) and enter $(tput setaf 2)${PlexPinCode}$(tput sgr 0)"
    fi

    echo -n "Waiting for code entry on the Plex API.."

    declare -i i; i=0
    unset XPlexToken
    while [ -z $XPlexToken ]
    do
        echo -n '.'
        sleep 2
        XPlexToken=$(curl -X "GET" -s ${PlexPinLink} \
            -H "X-Plex-Version: ${XPlexVersion}" \
            -H "X-Plex-Product: ${XPlexProduct}" \
            -H "X-Plex-Client-Identifier: ${XPlexClientIdentifier}" |
            grep -oP '\"auth_token":"\K[^",}]+')

        if [ $i -ge 120 ]; then
            echo ""
            echo "Code ${PlexPinCode} has expired after 4 minutes, generating new code."
            Get-XPlexToken
        fi
        i=i+1
    done
    echo ""
    # overwrite XPlexToken in the config
    sed -e "/^XPlexToken=/ c\\XPlexToken\=${XPlexToken}" \
        -e "\$aXPlexToken=${XPlexToken}" \
        -i ${plexargod_conf}
    echo "XPlexToken set in ${plexargod_conf}"
}


function Get-PlexUserInfo {
    PlexUserInfo=$(curl -s -X "POST" "https://plex.tv/users/sign_in.json" \
        -H "X-Plex-Version: ${XPlexVersion}" \
        -H "X-Plex-Product: ${XPlexProduct}" \
        -H "X-Plex-Client-Identifier: ${XPlexClientIdentifier}" \
        -H "X-Plex-Token: ${XPlexToken}")
}


function Get-ArgoURL {
    ArgoURL=$(curl -s "${ArgoMetricsURL}/metrics" | grep -oP 'userHostname="https://\K[^"]*\.trycloudflare\.com' | head -n1)
    if [ "$ArgoURL" ]; then
        echo "ArgoURL = ${ArgoURL}"
    else
        echo "Failed to get ArgoURL from cloudflared"
        exit 1
    fi
}

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
        if [ ! "${PlexServerProcessedMachineIdentifier}" ]; then
           systemd-cat -t ${0##*/} -p err <<<"Plex Server instance did not return an identifier, is it down?"
           echo "curl output for ${PlexServerURL}"
           curl -vs "${PlexServerURL}" -H "X-Plex-Token: ${XPlexToken}"
           exit 1
        else
            echo "PlexServerProcessedMachineIdentifier = ${PlexServerProcessedMachineIdentifier}"
        fi
        PlexAPIcustomConnections=$(curl -s "https://plex.tv/api/resources?X-Plex-Token=${XPlexToken}" |
            sed -n "/${PlexServerProcessedMachineIdentifier}/{n;p;n;p;n;p;}" |
            grep -oP 'address="\K[^"]*\.trycloudflare\.com' |
            head -n1)
        if [ $i -ge 15 ]; then
            systemd-cat -t ${0##*/} -p err <<<"Plex API does not match cloudflared URLs after 30 seconds."
            exit 1
        fi
        i=i+1
        sleep 2
    done
}


[ -z ${XPlexToken} ] && Get-PlexToken
if [ "$(Get-PlexUserInfo)" == '{"error":"Invalid authentication token."}' ]; then
    echo "X-Plex-Token is invalid, requesting new token"
    Get-XPlexToken
else
    echo "X-Plex-Token is valid"
fi

Get-ArgoURL
Set-PlexServerPrefs
Validate-PlexAPIcustomConnections
echo "Plex API is updated with the current Argo Tunnel Address."
exit 0
