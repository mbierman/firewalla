#!/bin/bash

shopt -s lastpipe

UNAME=$(uname -m)
ROUTER_MANAGED='yes'
case "$UNAME" in
  "x86_64")
    PLATFORM='gold'
    ;;
  "aarch64")
    if [[ -e /etc/firewalla-release ]]; then
      PLATFORM=$( . /etc/firewalla-release 2>/dev/null && echo $BOARD || cat /etc/firewalla-release )
      if [[ $PLATFORM == "blue" || $PLATFORM == "navy" ]]; then
        ROUTER_MANAGED='no'
      fi
    else
      PLATFORM='unknown'
    fi
    ;;
  "armv7l")
    PLATFORM='red'
    ROUTER_MANAGED='no'
    ;;
  *)
    PLATFORM='unknown'
    ;;
esac

# no idea what version of column were used before, but -n tells it not to ommit empty cells
# while it's for something totally different in offical build now
echo | column -n 2>/dev/null && COLUMN_OPT='column -n' || COLUMN_OPT='column'

# reads redis hash with key $2 into associative array $1
read_hash() {
  # make an alias of $1, https://unix.stackexchange.com/a/462089
  declare -n hash="$1"
  local i=0
  local key
  # as hash value might contain \n, have to use a non-standard delimiter here
  # use \x03 as delimiter as redis-cli doesn't seems to operate with \x00
  # bash 4.3 doesn't support readarray -d
  (redis-cli -d $'\3' hgetall "$2"; printf $'\3') | while read -r -d $'\3' entry; do
    ((i++))
    if ((i % 2)); then
      key="$entry"
    else
      hash["$key"]="$entry"
    fi
  done
}

# https://stackoverflow.com/questions/73742856/printing-and-padding-strings-with-bash-printf
# this doesn't work for chinese or japanese but deals with emoji pretty well
#
# Space pad align string to width
# @params
# $1: The alignment width
# $2: The string to align
# @stdout
# aligned string
align::right() {
  local -i width=$1 # Mandatory column width
  local -- str=$2 # Mandatory input string
  local -i length
  if (( ${#str} > width )); then
    length=$width
    str="${str:0:width-3}..."
  else
    length=${#str}
  fi
  local -i pad_left=$((width - length))
  printf '%*s%s' $pad_left '' "$str"
}

declare -A NETWORK_UUID_NAME
frcc_done=0
frcc() {
    if [[ $ROUTER_MANAGED == "no" ]]; then
        NETWORK_UUID_NAME['00000000-0000-0000-0000-000000000000']='primary'
        NETWORK_UUID_NAME['11111111-1111-1111-1111-111111111111']='overlay'
    elif [ "$frcc_done" -eq "0" ]; then
        curl localhost:8837/v1/config/active -s -o /tmp/scc_config

        jq -r '.interface | to_entries[].value | to_entries[].value.meta | .uuid, .name' /tmp/scc_config |
        while mapfile -t -n 2 ARY && ((${#ARY[@]})); do
            NETWORK_UUID_NAME[${ARY[0]}]=${ARY[1]}
        done

        frcc_done=1
    fi
}

declare -A TAG_UID_NAME
get_tag_name() {
    if [ ! -v "TAG_UID_NAME[$1]" ]; then
        TAG_UID_NAME["$1"]=$(redis-cli hget tag:uid:$1 name)
    fi
    echo "${TAG_UID_NAME["$1"]}"
}

check_wan_conn_log() {
  if [[ $ROUTER_MANAGED == "no" ]]; then
    return 0
  fi
  echo "---------------------------- WAN Connectivity Check Failures ----------------------------"
  cat ~/.forever/router*.log  | grep "WanConnCheckSensor" | grep -e "all ping test \| DNS \| Wan connectivity test failed" | sort | tail -n 50
  echo ""
  echo ""
}

check_cloud() {
    echo -n "  checking cloud access ... "
    curl_result=$(curl -w '%{http_code}' -Lks --connect-timeout 5 https://firewalla.encipher.io)
    test $curl_result == '200' && echo OK || {
        echo "fail($curl_result)"
        return 1
    }
    return 0
}

check_process() {
    echo -n "  checking process $1 ... "
    ps -ef | grep -w $1 | grep -qv grep && echo OK || {
        echo fail
        return 1
    }
    return 0
}

check_partition() {
    echo -n "  checking partition $1 ... "
    mount | grep -qw $1 && echo OK || {
        echo fail
        return 1
    }
    return 0
}

check_zram() {
    echo -n "  checking zram ... "
    test $(swapon -s | wc -l) -eq 5 && echo OK || {
        echo fail
        return 1
    }
    return 0
}

check_file() {
    echo -n "  check file $1 ... "
    if [[ -n "$2" ]]; then
        grep -q "$2" $1 && echo OK || {
            echo fail
            return 1
        }
    else
        test -f $1 && echo OK || {
            echo fail
            return 1
        }
    fi
    return 0
}

check_dmesg_ethernet() {
    echo "----------------------- Ethernet Link Up/Down in dmesg ----------------------------"

    sudo dmesg --time-format iso | grep '1c30000.ethernet' | grep 'Link is Down' -C 3 || echo "Nothing Found"

    echo ""
    echo ""
}

check_each_system_service() {
    local SERVICE_NAME=$1
    local EXPECTED_STATUS=$2
    local RESTART_TIMES=$(systemctl show "$1" -p NRestarts | awk -F= '{print $2}')
    local ACTUAL_STATUS=$(systemctl status "$1" | grep 'Active: ' | sed 's=Active: ==')
    printf "%20s %10s %5s %s\n" "$SERVICE_NAME" "$EXPECTED_STATUS" "$RESTART_TIMES" "$ACTUAL_STATUS"
}

check_systemctl_services() {
    echo "----------------------- System Services ----------------------------"
    printf "%20s %10s %5s %s\n" "Service Name" "Expect" "RestartedTimes" "Actual"

    check_each_system_service fireapi "running"
    check_each_system_service firemain "running"
    check_each_system_service firemon "running"
    check_each_system_service firekick "dead"
    check_each_system_service redis-server "running"
    check_each_system_service brofish "running"
    check_each_system_service firewalla "dead"
    check_each_system_service fireupgrade "dead"
    check_each_system_service fireboot "dead"

    if redis-cli hget policy:system vpn | fgrep -q '"state":true'
    then
      vpn_run_state='running'
    else
      vpn_run_state='dead'
    fi
    check_each_system_service openvpn@server $vpn_run_state

    if [[ $ROUTER_MANAGED == 'no' ]]; then
        check_each_system_service firemasq "running"
        check_each_system_service watchdog "running"
    else
        check_each_system_service firerouter "running"
        check_each_system_service firerouter_dns "running"
        check_each_system_service firerouter_dhcp "running"
    fi

    echo ""
    echo ""
}

check_rejection() {
    echo "----------------------- Node Rejections ----------------------------"

    find /home/pi/logs/ -type f -mtime -2 -exec bash -c 'grep -a "Possibly Unhandled Rejection" -A 10 -B 2 {} | tail -n 300' \;

    echo ""
    echo ""
}

check_exception() {
    echo "----------------------- Node Exceptions ----------------------------"

    find /home/pi/logs/ -type f -mtime -2 -exec bash -c "egrep -a -H -i '##### CRASH #####' -A 20 {} | tail -n 300" \;

    echo ""
    echo ""
}

check_reboot() {
    echo "----------------------- Reboot Record ------------------------------"

    sudo grep -a REBOOT /var/log/syslog

    echo ""
    echo ""
}

check_each_system_config() {
    local VALUE=${2%$'\r'} # remove tailing \r
    if [[ $VALUE == "" ]]; then
        VALUE="false"
    elif [[ $VALUE == "1" ]]; then
        VALUE="true"
    elif [[ $VALUE == "0" ]]; then
        VALUE="false"
    fi
    if [ -z "$3" ]; then
        printf "%30s  %-30s\n" "$1" "$VALUE"
    else
        printf "%40s  %30s  %-30s\n" "$1" "$3" "$VALUE"
    fi
}

get_redis_key_with_no_ttl() {
    local OUTPUT=$(redis-cli info keyspace | grep db0 | awk -F: '{print $2}')
    local TOTAL=$(echo "$OUTPUT" | sed 's/keys=//' | sed 's/,.*$//')
    local EXPIRES=$(echo "$OUTPUT" | sed 's/.*expires=//' | sed 's/,.*$//')
    local NOTTL=$((TOTAL - EXPIRES))

    local COLOR=""
    local UNCOLOR="\e[0m"
    if [[ $NOTTL -gt 1000 ]]; then
        COLOR="\e[91m"
    fi

    echo -e "$COLOR$NOTTL$UNCOLOR"
}

get_mode() {
    MODE=$(redis-cli get mode)
    frcc
    if [ "$MODE" = "spoof" ] && [ "$(redis-cli hget policy:system enhancedSpoof)" = "true" ]; then
        echo "enhancedSpoof"
    elif [ "$MODE" = "dhcp" ] && [ $ROUTER_MANAGED = "yes" ] && \
        [[ $(jq -c '.interface.bridge[] | select(.meta.type=="wan")' /tmp/scc_config | wc -c ) -ne 0 ]]; then
        echo "bridge"
    else
        echo "$MODE"
    fi
}

get_auto_upgrade() {
    local UPGRADE=
    local COLOR=
    local UNCOLOR="\e[0m"
    if [ -f $1 ]; then
      COLOR="\e[91m"
      UPGRADE="false"
    else
      UPGRADE="true"
    fi

    echo -e "$COLOR$UPGRADE$UNCOLOR"
}

check_system_config() {
    echo "----------------------- System Config ------------------------------"
    declare -A c
    read_hash c sys:config

    for hkey in "${!c[@]}"; do
        check_each_system_config "$hkey" "${c[$hkey]}"
    done
    check_each_system_config 'version' "$(jq -c .version /home/pi/firewalla/net2/config.json)"

    echo ""

    declare -A p
    read_hash p policy:system

    check_each_system_config "Mode" "$(get_mode)"
    check_each_system_config "Adblock" "${p[adblock]}"
    check_each_system_config "Family" "${p[family]}"
    check_each_system_config "Monitor" "${p[monitor]}"
    check_each_system_config "Emergency Access" "${p[acl]}"
    check_each_system_config "vpnAvailable" "${p[vpnAvailable]}"
    check_each_system_config "vpn" "${p[vpn]}"
    check_each_system_config "Redis Usage" "$(redis-cli info | grep used_memory_human | awk -F: '{print $2}')"
    check_each_system_config "Redis Total Key" "$(redis-cli dbsize)"
    check_each_system_config "Redis key without ttl" "$(get_redis_key_with_no_ttl)"

    echo ""

    check_each_system_config 'Firewalla Autoupgrade' "$(get_auto_upgrade "/home/pi/.firewalla/config/.no_auto_upgrade")"
    check_each_system_config 'Firerouter Autoupgrade' "$(get_auto_upgrade "/home/pi/.router/config/.no_auto_upgrade")"
    check_each_system_config 'License Prefix' "$(jq -r .DATA.SUUID ~/.firewalla/license)"

    echo ""

    check_each_system_config 'default MSP' "$(redis-cli get ext.guardian.socketio.server)"
    redis-cli zrange guardian:alias:list 0 -1 | while read -r alias; do printf '%30s  %s\n' "$alias" "$(redis-cli get "ext.guardian.socketio.server.$alias")"; done

    echo ""
}

check_tc_classes() {
    echo "------------------------- TC Classes -------------------------------"
    local RULES=$(redis-cli hkeys policy_qos_handler_map | grep "^policy_" | sort -t_ -n -k 2)
    for RULE in $RULES; do
        local RULE_ID=${RULE/policy_/""}
        local QOS_HANDLER=$(redis-cli hget policy_qos_handler_map $RULE)
        local QOS_HANDLER_ID=$(printf '%x' ${QOS_HANDLER/qos_/""})
        local TRAFFIC_DIRECTION=$(redis-cli hget policy:${RULE_ID} trafficDirection)
        local RATE_LIMIT=$(redis-cli hget policy:${RULE_ID} rateLimit)
        local PRIORITY=$(redis-cli hget policy:${RULE_ID} priority)
        local DISABLED=$(redis-cli hget policy:${RULE_ID} disabled)
        echo "PID: ${RULE_ID}, traffic direction: ${TRAFFIC_DIRECTION}, rate limit: ${RATE_LIMIT}, priority: ${PRIORITY}, disabled: ${DISABLED}"
        if [[ $TRAFFIC_DIRECTION == "upload" ]]; then
          tc class show dev ifb0 classid 1:0x${QOS_HANDLER_ID}
        else
          tc class show dev ifb1 classid 1:0x${QOS_HANDLER_ID}
        fi
        echo ""
    done
    echo ""
    echo ""
}

check_policies() {
    echo "--------------------------- Rules ----------------------------------"
    local RULES=$(redis-cli keys 'policy:*' | egrep "policy:[0-9]+$" | sort -t: -n -k 2)
    frcc

    echo "Rule|Target|Type|Scope|Expire|Scheduler|Proto|TosDir|RateLmt|Pri|Dis">/tmp/qos_csv
    echo "Rule|Target|Type|Scope|Expire|Scheduler|Proto|Dir|wanUUID|Type|Dis">/tmp/route_csv
    printf "%7s %52s %11s %18s %10s %25s %5s %8s %5s %9s %9s %3s %8s\n" "Rule" "Target" "Type" "Scope" "Expire" "Scheduler" "Dir" "Action" "Proto" "LPort" "RPort" "Dis" "Hit"
    for RULE in $RULES; do
        local RULE_ID=${RULE/policy:/""}
        declare -A p
        read_hash p "$RULE"

        local TYPE=${p["type"]}
        if [[ $TYPE == "dns" || $TYPE == 'domain' ]]; then
          if [[ ${p[dnsmasq_only]} != 'true' && ${p[dnsmasq_only]} != '1'  ]]; then
            TYPE=$TYPE'+ip'
          fi
        fi
        local ACTION=${p[action]}
        local TRAFFIC_DIRECTION=${p[trafficDirection]}
        TRAFFIC_DIRECTION=${TRAFFIC_DIRECTION%load} # remove 'load' from end of string
        local DISABLED=${p[disabled]}

        local COLOR=""
        local UNCOLOR="\e[0m"

        if [ "$ACTION" = "" ]; then
            ACTION="block"
        elif [ "$ACTION" = "allow" ]; then
            COLOR="\e[38;5;28m"
        fi

        if [[ $DISABLED == "1" ]]; then
            DISABLED='T'
            COLOR="\e[2m" #dim
        else
            DISABLED=
        fi

        local DIRECTION=${p[direction]}
        if [ "$DIRECTION" = "" ] || [ "$DIRECTION" = "bidirection" ]; then
            DIRECTION="both"
        else
            DIRECTION=${DIRECTION%bound} # remove 'bound' from end of string
        fi

        local SCOPE=${p[scope]:2:-2}
        local TAG=${p[tag]}
        if [[ -n $TAG ]]; then
            TAG="${TAG:2:-2}"
            if [[ "$TAG" == "intf:"* ]]; then
                SCOPE="net:${NETWORK_UUID_NAME[${TAG:5}]}"
            else
                SCOPE="tag:$(get_tag_name "${TAG:4}")"
            fi
        elif [[ ! -n $SCOPE ]]; then
            SCOPE="All Devices"
        fi

        local TARGET="${p[target]}"
        if [[ $TYPE == "network" ]]; then
            TARGET="net:${NETWORK_UUID_NAME[$TARGET]}"
        fi

        local EXPIRE=${p[expire]}
        local CRONTIME=${p[cronTime]}

        local ALARM_ID=${p[aid]}
        if [[ -n $ALARM_ID ]]; then
            RULE_ID="* $RULE_ID"
        elif [[ -n ${p[flowDescription]} ]]; then
            RULE_ID="** $RULE_ID"
        fi
        if [[ $ACTION == 'qos' ]]; then
          echo -e "$RULE_ID|$TARGET|$TYPE|$SCOPE|$EXPIRE|$CRONTIME|${p[protocol]}|$TRAFFIC_DIRECTION|${p[rateLimit]}|${p[priority]}|$DISABLED">>/tmp/qos_csv
        elif [[ $ACTION == 'route' ]]; then
          local WAN="${NETWORK_UUID_NAME[${p[wanUUID]}]}"
          if [ -z "$WAN" ]; then
              WAN=${p[wanUUID]}
          fi
          echo -e "$RULE_ID|$TARGET|$TYPE|$SCOPE|$EXPIRE|$CRONTIME|${p[protocol]}|$DIRECTION|$WAN|${p[routeType]}|$DISABLED">>/tmp/route_csv
        else
          printf "$COLOR%7s %52s %11s %18s %10s %25s %5s %8s %5s %9s %9s %3s %8s$UNCOLOR\n" "$RULE_ID" "$TARGET" "$TYPE" "$SCOPE" "$EXPIRE" "$CRONTIME" "$DIRECTION" "$ACTION" "${p[protocol]}" "${p[localPort]}" "${p[remotePort]}" "$DISABLED" "${p[hitCount]}"
        fi;

        unset p
    done

    echo ""
    echo "Note: * - created from alarm, ** - created from network flow"

    echo ""
    echo "QoS Rules:"
    $COLUMN_OPT -t -s'|' /tmp/qos_csv | sed 's=\ "\([^"]*\)\"= \1  =g'

    echo ""
    echo "Route Rules:"
    $COLUMN_OPT -t -s'|' /tmp/route_csv | sed 's=\ "\([^"]*\)\"= \1  =g'

    echo ""
    echo ""
}

is_router() {
    local GW=$(/sbin/ip route show | awk '/default via/ {print $3}')
    if [[ $GW == $1 ]]; then
        return 0
    else
        return 1
    fi
}

is_simple_mode() {
    local MODE=$(redis-cli get mode)
    if [[ $MODE == "spoof" ]]; then
        echo T
    fi

    echo F
}

check_hosts() {
    echo "----------------------- Devices ------------------------------"

    local SIMPLE_MODE=$(is_simple_mode)
    # read all enabled newDeviceTag tags
    declare -a NEW_DEVICE_TAGS
    if [[ "$(redis-cli hget sys:features new_device_tag)" == "1" ]]; then
      NEW_DEVICE_TAGS=( $(redis-cli hget policy:system newDeviceTag | jq "select(.state == true) | .tag") )
      while read -r POLICY_KEY; do
        test -n "$POLICY_KEY" && NEW_DEVICE_TAGS+=( $(redis-cli hget $POLICY_KEY newDeviceTag | jq "select(.state == true) | .tag") );
      done < <(redis-cli keys 'policy:network:*')
    else
      NEW_DEVICE_TAGS=( )
    fi

    local DEVICES=$(redis-cli keys 'host:mac:*')
    printf "%35s %15s %28s %15s %18s %3s %2s %2s %11s %7s %6s %3s %2s %3s %3s %3s %3s %3s\n" \
      "Host" "Network" "Name" "IP" "MAC" "Mon" "B7" "Ol" "vpnClient" "FlowOut" "FlowIn" "Grp" "EA" "DNS" "AdB" "Fam" "DoH" "ubn"
    NOW=$(date +%s)
    frcc


    local FIREWALLA_MAC="$(ip link list | awk '/ether/ {print $2}' | sort | uniq)"

    for DEVICE in $DEVICES; do
        local MAC=${DEVICE/host:mac:/""}
        # hide vpn_profile:*
        if [[ ${MAC,,} == "vpn_profile:"* ]]; then
            continue
        fi

        local IS_FIREWALLA
        if echo "$FIREWALLA_MAC" | grep -wiq "$MAC"; then
          IS_FIREWALLA=1 # true
        else
          IS_FIREWALLA=0 # false
        fi

        declare -A h
        read_hash h $DEVICE

        local ONLINE_TS=${h[lastActiveTimestamp]}
        ONLINE_TS=${ONLINE_TS%.*}
        if [[ ! -n $ONLINE_TS ]]; then
            local ONLINE="NA"
        elif (($ONLINE_TS < $NOW - 2592000)); then # 30days ago, hide entry
            unset h
            continue
        elif (($ONLINE_TS > $NOW - 1800)); then
            local ONLINE="T"
        else
            local ONLINE=
        fi

        local NAME=$( ((${#h[detect]} > 2)) && jq -re 'select(has("name")) | .name' <<< "${h[detect]}" || echo -n "${h[bname]}")

        local NETWORK_NAME=
        if [[ -n ${h[intf]} ]]; then NETWORK_NAME=${NETWORK_UUID_NAME[${h[intf]}]}; fi
        local IP=${h[ipv4Addr]}
        local MAC_VENDOR=${h[macVendor]}
        local POLICY_MAC="policy:mac:${MAC}"

        declare -A p
        read_hash p $POLICY_MAC

        local MONITORING=
        if ((IS_FIREWALLA)) || is_router $IP; then
            MONITORING="NA"
        elif [[ ${p[monitor]} == "true" ]]; then
            MONITORING=""
        else
            MONITORING="F"
        fi
        if [[ $SIMPLE_MODE == "T" ]]; then
          local B7_MONITORING_FLAG=$(redis-cli sismember monitored_hosts "$IP")
          local B7_MONITORING=""
          if [[ $B7_MONITORING_FLAG == "1" ]]; then
            B7_MONITORING="T"
          else
            B7_MONITORING="F"
          fi
        fi

        # local policy=()
        # local output=$(redis-cli -d $'\3' hmget $POLICY_MAC vpnClient tags acl)
        # readarray -d $'\3' -t policy < <(echo -n "$output")

        local VPN=$( ((${#p[vpnClient]} > 2)) && jq -re 'select(.state == true) | .profileId' <<< "${p[vpnClient]}" || echo -n "")
        local EMERGENCY_ACCESS=""
        if [[ "${p[acl]}" == "false" ]]; then
            EMERGENCY_ACCESS="T"
        fi

        local FLOWINCOUNT=$(redis-cli zcount flow:conn:in:$MAC -inf +inf)
        # if [[ $FLOWINCOUNT == "0" ]]; then FLOWINCOUNT=""; fi
        local FLOWOUTCOUNT=$(redis-cli zcount flow:conn:out:$MAC -inf +inf)
        # if [[ $FLOWOUTCOUNT == "0" ]]; then FLOWOUTCOUNT=""; fi

        # local DNS_BOOST=$(jq -r 'select(.dnsCaching == false) | "F"' <<< "${p[dnsmasq]}")
        local DNS_BOOST=$(if [[ ${p[dnsmasq]} == *"false"* ]]; then echo "F"; fi)
        local ADBLOCK=""
        if [[ "${p[adblock]}" == "true" ]]; then ADBLOCK="T"; fi
        local FAMILY_PROTECT=""
        if [[ "${p[family]}" == "true" ]]; then FAMILY_PROTECT="T"; fi

        local DOH=$(if [[ ${p[doh]} == *"true"* ]]; then echo "T"; fi)
        local UNBOUND=$(if [[ ${p[unbound]} == *"true"* ]]; then echo "T"; fi)

        local TAGS=$( sed "s=[][\" ]==g" <<< ${p[tags]} )
        # TAGNAMES=""
        # for tag in $TAGS; do
        #     TAGNAMES="$(redis-cli hget tag:uid:$tag name | tr -d '\n')[$tag],"
        # done
        # TAGNAMES=$(echo $TAGNAMES | sed 's=,$==')

        # === COLOURING ===
        local COLOR="\e[39m"
        local UNCOLOR="\e[0m"
        local BGCOLOR="\e[49m"
        local BGUNCOLOR="\e[49m"
        if [[ $SIMPLE_MODE == "T" && -n $ONLINE && -z $MONITORING && $B7_MONITORING == "F" ]] &&
          ((! IS_FIREWALLA)) && ! is_router $IP; then
            COLOR="\e[91m"
        elif [ $FLOWINCOUNT -gt 2000 ] || [ $FLOWOUTCOUNT -gt 2000 ]; then
            COLOR="\e[33m" #yellow
        fi
        if [[ ${NAME,,} == "circle"* || ${MAC_VENDOR,,} == "circle"* ]]; then
            BGCOLOR="\e[41m"
        fi

        local MAC_COLOR="$COLOR"
        if [[ $MAC =~ ^.[26AEae].*$ ]] && ((! IS_FIREWALLA)); then
          MAC_COLOR="\e[35m"
        fi

        TAG_COLOR="$COLOR"
        if [[ " ${NEW_DEVICE_TAGS[*]} " =~ " ${TAGS} " ]]; then
          TAG_COLOR="\e[31m"
        fi

        if [ -z $ONLINE ]; then
            COLOR=$COLOR"\e[2m" #dim
        fi

        printf "$BGCOLOR$COLOR%35s %15s %28s %15s $MAC_COLOR%18s$COLOR %3s %2s %2s %11s %7s %6s $TAG_COLOR%3s$COLOR %2s %3s %3s %3s %3s %3s$UNCOLOR$BGUNCOLOR\n" \
          "$(align::right 35 "$NAME")" "$(align::right 15 "$NETWORK_NAME")" "$(align::right 28 "${h[name]}")" "$IP" "$MAC" "$MONITORING" "$B7_MONITORING" "$ONLINE" "$VPN" "$FLOWINCOUNT" \
          "$FLOWOUTCOUNT" "$TAGS" "$EMERGENCY_ACCESS" "$DNS_BOOST" "$ADBLOCK" "$FAMILY_PROTECT" "$DOH" "$UNBOUND"

        unset h
        unset p
    done

    echo ""
    echo ""
}

check_ipset() {
    echo "---------------------- Active IPset ------------------"
    printf "%25s %10s\n" "IPSET" "NUM"
    local IPSETS=$(sudo iptables -w -L -n | egrep -o "match-set [^ ]*" | sed 's=match-set ==' | sort | uniq)
    for IPSET in $IPSETS $(sudo ipset list -name | grep bd_default_c); do
        local NUM=$(($(sudo ipset -S $IPSET | wc -l)-1))
        local COLOR=""
        local UNCOLOR="\e[0m"
        if [[ $NUM -gt 0 ]]; then
            COLOR="\e[91m"
        fi
        printf "%25s $COLOR%10s$UNCOLOR\n" $IPSET $NUM
    done

    echo ""
    echo ""
}

check_sys_features() {
    echo "---------------------- System Features ------------------"
    declare -A FEATURES
    local FILE="$FIREWALLA_HOME/net2/config.json"
    local USERFILE="$HOME/.firewalla/config/config.json"

    # use jq where available
    if [[ "$PLATFORM" != 'red' && "$PLATFORM" != 'blue' ]]; then
      if [[ -f "$FILE" ]]; then
        jq -r '.userFeatures // {} | to_entries[] | "\(.key) \(.value)"' "$FILE" |
        while read key value; do
          FEATURES["$key"]="$value"
        done
      fi

      if [[ -f "$USERFILE" ]]; then
        jq -r '.userFeatures // {} | to_entries[] | "\(.key) \(.value)"' "$USERFILE" |
        while read key value; do
          FEATURES["$key"]="$value"
        done
      fi
    else
      # lagacy python 2.7 solution
      if [[ -f "$FILE" ]]; then
        local JSON=$(python -c "import json; obj=json.load(open('$FILE')); obj2='\n'.join([key + '=' + str(value) for key,value in obj['userFeatures'].items()]); print obj2;")
        while IFS="=" read -r key value; do
          FEATURES["$key"]="$value"
        done <<<"$JSON"
      fi

      if [[ -f "$USERFILE" ]]; then
        local JSON=$(python -c "import json; obj=json.load(open('$USERFILE')); obj2='\n'.join([key + '=' + str(value) for key,value in obj['userFeatures'].items()]) if obj.has_key('userFeatures') else ''; print obj2;")
        if [[ "$JSON" != "" ]]; then
          while IFS="=" read -r key value; do
            FEATURES["$key"]="$value"
          done <<<"$JSON"
        fi
      fi
    fi

    read_hash FEATURES sys:features

    keyList=( "ipv6" "local_domain" "family_protect" "adblock" "doh" "unbound" "dns_proxy" "safe_search" "external_scan" "device_online" "device_offline" "dual_wan" "single_wan_conn_check" "video" "porn" "game" "vpn" "cyber_security" "cyber_security.autoBlock" "cyber_security.autoUnblock" "large_upload" "large_upload_2" "abnormal_bandwidth_usage" "vulnerability" "new_device" "new_device_tag" "new_device_block" "alarm_subnet" "alarm_upnp" "alarm_openport" "acl_alarm" "vpn_client_connection" "vpn_disconnect" "vpn_restore" "spoofing_device" "sys_patch" "device_service_scan" "acl_audit" "dnsmasq_log_allow" "data_plan" "data_plan_alarm" "country" "category_filter" "fast_intel" "network_monitor" "network_monitor_alarm" "network_stats" "network_status" "network_speed_test" "network_metrics" "link_stats" "rekey" "rule_stats" "internal_scan" "accounting" "wireguard" "pcap_zeek" "pcap_suricata" "compress_flows" "event_collect" "mesh_vpn" "redirect_httpd" "upstream_dns" )

    declare -A nameMap
    nameMap[ipv6]="Simple mode IPv6 Support"
    nameMap[local_domain]="Local Domain"
    nameMap[family_protect]="Family Protect"
    nameMap[adblock]="AD Block"
    nameMap[doh]="DNS over HTTPS"
    nameMap[unbound]="Unbound"
    nameMap[dns_proxy]="DNS Proxy"
    nameMap[safe_search]="Safe Search"
    nameMap[external_scan]="External Scan"
    nameMap[device_online]="Device Online Alarm"
    nameMap[device_offline]="Device Offline Alarm"
    nameMap[dual_wan]="Internet Connectivity Alarm Dual WAN"
    nameMap[single_wan_conn_check]="Internet Connectivity Alarm Single WAN"
    nameMap[video]="Auido/Video Alarm"
    nameMap[porn]="Porn Alarm"
    nameMap[game]="Gaming Alarm"
    nameMap[vpn]="VPN Traffic Alarm"
    nameMap[cyber_security]="Security Alarm"
    nameMap[cyber_security.autoBlock]="Malicious Traffic Autoblock"
    nameMap[cyber_security.autoUnblock]="Malicious Traffic Autoblock Validation"
    nameMap[large_upload]="Abnormal Upload Alarm"
    nameMap[large_upload_2]="Large Upload Alarm"
    nameMap[abnormal_bandwidth_usage]="Abnormal Bandwidth Alarm"
    nameMap[vulnerability]="Vulnerability Alarm"
    nameMap[new_device]="New Device Alarm"
    nameMap[new_device_tag]="Quarantine"
    nameMap[new_device_block]="New Device Alarm Auto Block"
    nameMap[alarm_subnet]="Subnet Alarm"
    nameMap[alarm_upnp]="uPnP Alarm"
    nameMap[alarm_openport]="Open Port Alarm"
    nameMap[acl_alarm]="Customized Alarm"
    nameMap[vpn_client_connection]="VPN Activity Alarm"
    nameMap[vpn_disconnect]="VPN Connectivity Disconnection Alarm"
    nameMap[vpn_restore]="VPN Connectivity Restoration Alarm"
    nameMap[spoofing_device]="Spoofing Device Alarm"
    nameMap[sys_patch]="System Patch"
    nameMap[device_service_scan]="Device Service Scan"
    nameMap[acl_audit]="Blocked Flows"
    nameMap[dnsmasq_log_allow]="Nonblock DNS Flows"
    nameMap[data_plan]="Data Plan"
    nameMap[data_plan_alarm]="Data Plan Alarm"
    nameMap[country]="Country Data Update"
    nameMap[category_filter]="Category Bloomfilter"
    nameMap[fast_intel]="Intel Bloomfilter"
    nameMap[network_monitor]="Internet Quality Test"
    nameMap[network_monitor_alarm]="Internet Quality Alarm"
    nameMap[network_stats]="Network Ping Test"
    nameMap[network_status]="DNS Server Ping Test"
    nameMap[network_speed_test]="Auto Speed Test"
    nameMap[network_metrics]="Network Traffic Metrics"
    nameMap[link_stats]="dmesg LinkDown Check"
    nameMap[rekey]="Renew Group Key"
    nameMap[rule_stats]="Rule Stats"
    nameMap[internal_scan]="Internal Scan"
    nameMap[accounting]="Screen Time"
    nameMap[wireguard]="WireGuard"
    nameMap[pcap_zeek]="Zeek"
    nameMap[pcap_suricata]="Suricate"
    nameMap[compress_flows]="Compress Flow"
    nameMap[event_collect]="Events"
    nameMap[mesh_vpn]="Mesh VPN"
    nameMap[redirect_httpd]="Legacy API service"
    nameMap[upstream_dns]="Legacy DNS -should be off-"

    for key in "${keyList[@]}"; do
        if [ -v "nameMap[$key]" ] && [ -v "FEATURES[$key]" ]; then
            check_each_system_config "${nameMap[$key]}" "${FEATURES[$key]}" "$key"
            unset "FEATURES[$key]"
        fi
    done

    for key in ${!FEATURES[*]}; do
        check_each_system_config "" "${FEATURES[$key]}" "$key"
    done

    echo ""
    echo ""
}

check_speed() {
    echo "---------------------- Speed ------------------"
    UNAME=$(uname -m)
    test "$UNAME" == "x86_64" && curl --connect-timeout 10 -L https://github.com/firewalla/firewalla/releases/download/v1.963/fast_linux_amd64 -o /tmp/fast 2>/dev/null && chmod +x /tmp/fast && /tmp/fast
    test "$UNAME" == "aarch64" && curl --connect-timeout 10 -L https://github.com/firewalla/firewalla/releases/download/v1.963/fast_linux_arm64 -o /tmp/fast 2>/dev/null && chmod +x /tmp/fast && /tmp/fast
    test "$UNAME" == "armv7l" && curl --connect-timeout 10 -L https://github.com/firewalla/firewalla/releases/download/v1.963/fast_linux_arm -o /tmp/fast 2>/dev/null && chmod +x /tmp/fast && /tmp/fast
}

check_conntrack() {
    echo "---------------------- Conntrack Count------------------"

    cat /proc/sys/net/netfilter/nf_conntrack_count

    echo ""
    echo ""
}

check_network() {
    if [[ $ROUTER_MANAGED == "no" ]]; then
        return
    fi

    echo "---------------------- Network ------------------"
    curl localhost:8837/v1/config/interfaces -s -o /tmp/scc_interfaces
    INTFS=$(jq -r 'keys | .[]' /tmp/scc_interfaces)
    frcc
    DNS=$(jq '.dns' /tmp/scc_config)
    # read LAN DNS as '|' seperated string into associative array DNS_CONFIG
    declare -A DNS_CONFIG
    jq '.dns | to_entries | map(select(.value.nameservers))[] | .key, (.value.nameservers | join("|"))' /tmp/scc_config |
      while mapfile -t -n 2 ARY && ((${#ARY[@]})); do
        DNS_CONFIG[${ARY[0]}]=${ARY[1]}
      done

    >/tmp/scc_csv
    for INTF in $INTFS; do
      jq -rj ".[\"$INTF\"] | if (.state.ip6 | length) == 0 then .state.ip6 |= [] else . end | [\"$INTF\", .config.meta.name, .config.meta.uuid, .state.ip4, .state.gateway, (.state.ip6 | join(\"|\")), .state.gateway6, (.state.dns // [] | join(\";\"))] | @tsv" /tmp/scc_interfaces >>/tmp/scc_csv
      echo "" >> /tmp/scc_csv
    done

    printf "Interface\tName\tUUID\tIPv4\tGateway\tIPv6\tGateway6\tDNS\tvpnClient\tAdB\tFam\tDoH\tubn\n" >/tmp/scc_csv_multline
    while read -r LINE; do
      mapfile -td $'\t' COL < <(printf "$LINE")
      # read multi line fields into array
      mapfile -td '|' IP6 < <(printf "${COL[5]}")
      # column 7 is the last column, which carries a line feed
      if [[ ${#COL[7]} -gt 1 ]]; then
        mapfile -td ';' DNS < <(printf "%s" "${COL[7]}")
      else
        mapfile -td '|' DNS < <(printf "%s" "${DNS_CONFIG["${COL[0]}"]}")
      fi
      # echo ${COL[0]}
      # echo "ip${#IP6[@]} dns${#DNS[@]}"
      # echo ${DNS_CONFIG["${COL[0]}"]}
      # echo ${IP6[@]}
      # echo ${DNS[@]}

      declare -A p
      read_hash p "policy:network:${COL[2]}"

      local VPN=$( ((${#p[vpnClient]} > 2)) && jq -re 'select(.state == true) | .profileId' <<< "${p[vpnClient]}" || echo -n "")

      local ADBLOCK=
      if [[ "${p[adblock]}" == "true" ]]; then ADBLOCK="T"; fi
      local FAMILY_PROTECT=
      if [[ "${p[family]}" == "true" ]]; then FAMILY_PROTECT="T"; fi

      local DOH=$(if [[ ${p[doh]} == *"true"* ]]; then echo "T"; fi)
      local UNBOUND=$(if [[ ${p[unbound]} == *"true"* ]]; then echo "T"; fi)


      local LINE_COUNT=$(( "${#IP6[@]}" > "${#DNS[@]}" ? "${#IP6[@]}" : "${#DNS[@]}" ));
      [[ $LINE_COUNT -eq 0 ]] && LINE_COUNT=1
      for (( IDX=0; IDX < $LINE_COUNT; IDX++ )); do
        # echo $IDX
        local IP=
        if [[ ${#IP6[@]} -gt $IDX ]]; then
          IP=${IP6[$IDX]}
        fi

        if [[ $IDX -eq 0 ]]; then
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "${COL[0]}" "${COL[1]}" "${COL[2]:0:7}" "${COL[3]}" "${COL[4]}" "$IP" "${COL[6]}" "${DNS[$IDX]}" \
            "$VPN" "$ADBLOCK" "$FAMILY_PROTECT" "$DOH" "$UNBOUND" >> /tmp/scc_csv_multline
        else
          printf "\t\t\t\t\t%s\t\t%s\n" "$IP" "${DNS[$IDX]}" >> /tmp/scc_csv_multline
        fi
      done

      unset p
    done < /tmp/scc_csv
    $COLUMN_OPT -t -s$'\t' /tmp/scc_csv_multline
    echo ""

    #check source NAT
    mapfile -t WANS < <(jq -r ". | to_entries | .[] | select(.value.config.meta.type == \"wan\") | .key" /tmp/scc_interfaces)
    mapfile -t SOURCE_NAT < <(jq -r ".nat | keys | .[]" /tmp/scc_config | cut -d - -f 2 | sort | uniq)
    echo "WAN Interfaces:"
    for WAN in "${WANS[@]}"; do
      if [[ " ${SOURCE_NAT[*]} " =~ " ${WAN} " ]]; then
        printf "%10s: Source NAT ON\n" $WAN
      else
        printf "\e[31m%10s: Source NAT OFF\e[0m\n" $WAN
      fi
    done
    echo ""
    echo ""
}

check_tag() {
    echo "---------------------- Tag ------------------"
    local TAGS=$(redis-cli --scan --pattern 'tag:uid:*' | sort)
    NOW=$(date +%s)

    printf "ID\tName\tvpnClient\tAdB\tFam\tDoH\tubn\n" >/tmp/tag_csv
    for TAG in $TAGS; do
      declare -A t p
      read_hash t "$TAG"
      read_hash p "policy:tag:${t[uid]}"
      local VPN=$( ((${#p[vpnClient]} > 2)) && jq -re 'select(.state == true) | .profileId' <<< "${p[vpnClient]}" || echo -n "")

      local ADBLOCK=""
      if [[ "${p[adblock]}" == "true" ]]; then ADBLOCK="T"; fi
      local FAMILY_PROTECT=""
      if [[ "${p[family]}" == "true" ]]; then FAMILY_PROTECT="T"; fi

      local DOH=$(if [[ ${p[doh]} == *"true"* ]]; then echo "T"; fi)
      local UNBOUND=$(if [[ ${p[unbound]} == *"true"* ]]; then echo "T"; fi)

      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "${t[uid]}" "${t[name]}" "$VPN" "$ADBLOCK" "$FAMILY_PROTECT" "$DOH" "$UNBOUND" >>/tmp/tag_csv
      unset t p
    done

    $COLUMN_OPT -t -s$'\t' /tmp/tag_csv

    echo ""
    echo ""
}

check_portmapping() {
  echo "------------------ Port Forwarding ------------------"

  (
    echo "type,active,Proto,ExtPort,toIP,toPort,toMac,fw,description"
    redis-cli get extension.portforward.config |
      jq -r '.maps[] | select(.state == true) | "\"\(._type // "Forward")\",\"\(.active)\",\"\(.protocol)\",\"\(.dport)\",\"\(.toIP)\",\"\(.toPort)\",\"\(.toMac)\",\"\(.autoFirewall)\",\"\(.description)\""'
    redis-cli hget sys:scan:nat upnp |
      jq -r '.[] | "\"UPnP\",\"\(.expire)\",\"\(.protocol)\",\"\(.public.port)\",\"\(.private.host)\",\"\(.private.port)\",\"N\/A\",\"N\/A\",\"\(.description)\""'
  ) |
    $COLUMN_OPT -t -s, | sed 's=\"\([^"]*\)\"=\1  =g'
  echo ""
  echo ""
}

check_dhcp() {
    echo "---------------------- DHCP ------------------"
    find /log/blog/ -mmin -120 -name "dhcp*log.gz" |
      sort | xargs zcat -f |
      jq -r '.msg_types=(.msg_types|join("|"))|[."ts", ."server_addr", ."mac", ."host_name", ."requested_addr", ."assigned_addr", ."lease_time", ."msg_types"]|@csv' |
      sed 's="==g' | grep -v "INFORM|ACK" |
      awk -F, 'BEGIN { OFS = "," } { cmd="date -d @"$1; cmd | getline d;$1=d;print;close(cmd)}' |
      $COLUMN_OPT -s "," -t
    echo ""
    echo ""
}

check_redis() {
    echo "---------------------- Redis ----------------------"
    local INTEL_IP=$(redis-cli --scan --pattern intel:ip:*|wc -l)
    local INTEL_IP_COLOR=""
    if [ $INTEL_IP -gt 20000 ]; then
        INTEL_IP_COLOR="\e[31m"
    elif [ $INTEL_IP -gt 10000 ]; then
        INTEL_IP_COLOR="\e[33m"
    fi
    printf "%20s $INTEL_IP_COLOR%10s\e[0m\n" "intel:ip:*" $INTEL_IP
    echo ""
    echo ""
}

check_docker() {
  echo "---------------------- Docker ----------------------"
  sudo systemctl -q is-active docker && sudo docker ps
  echo ""
  echo ""
}

run_ifconfig() {
  echo "---------------------- ifconfig ----------------------"
  ifconfig
  echo ""
  echo ""
}

run_lsusb() {
  echo "---------------------- lsusb ----------------------"
  lsusb
  echo ""
  echo ""
}

check_eth_count() {
  ports=$(ls -l /sys/class/net | grep -c "eth[0-3] ")

  if [[ ("$PLATFORM" == 'gold' || "$PLATFORM" == 'gold-se') && $ports -ne 4 ||
    ("$PLATFORM" == 'purple' || "$PLATFORM" == 'purple-se') && $ports -ne 2 ||
    ("$PLATFORM" == 'blue' || "$PLATFORM" == 'red' || "$PLATFORM" == 'navy' ) && $ports -ne 1 ]]; then
      printf "\e[41m >>>>>> eth interface number mismatch: %s <<<<<< \e[0m\n" "$ports"
    else
      echo "all good: $ports eth interfaces"
  fi
  echo ""
  echo ""
}

check_events() {
  redis-cli zrange event:log 0 -1 | jq -c '.ts |= (. / 1000 | strftime("%Y-%m-%d %H:%M")) | del(.event_type, .ts0, .labels.wan_intf_uuid) | del(.labels|..|select(type=="object")|.wan_intf_uuid)'
  # hint on stderr so won't impact stuff being piped
  >&2 echo '  >> Keep in mind the timestamps above are all UTC <<'
}

usage() {
    echo "Options:"
    echo "  -s  | --service"
    echo "  -sc | --config"
    echo "  -sf | --feature"
    echo "  -r  | --rule"
    echo "  -i  | --ipset"
    echo "  -d  | --dhcp"
    echo "  -re | --redis"
    echo "        --docker"
    echo "  -n  | --network"
    echo "  -t  | --tag"
    echo "  -e  | --events"
    echo "  -f  | --fast | --host"
    echo "  -h  | --help"
    return
}

FAST=false
while [ "$1" != "" ]; do
    case $1 in
    -s | --service)
        shift
        FAST=true
        check_systemctl_services
        ;;
    -sc | --config)
        shift
        FAST=true
        check_system_config
        ;;
    -sf | --feature)
        shift
        FAST=true
        check_sys_features
        ;;
    -r | --rule)
        shift
        FAST=true
        check_policies
        check_tc_classes
        ;;
    -i | --ipset)
        shift
        FAST=true
        check_ipset
        ;;
    -d | --dhcp)
        shift
        FAST=true
        check_dhcp
        ;;
    -re | --redis)
        shift
        FAST=true
        check_redis
        ;;
    -n | --network)
        shift
        FAST=true
        check_network
        ;;
    -t | --tag)
        shift
        FAST=true
        check_tag
        ;;
    -f | --fast | --host)
        shift
        FAST=true
        check_hosts
        ;;
    -p | --port)
        shift
        FAST=true
        check_portmapping
        ;;
    --docker)
        shift
        FAST=true
        check_docker
        ;;
    -e | --events)
        shift
        FAST=true
        check_events
        ;;
    -h | --help)
        usage
        exit
        ;;
    *)
        usage
        exit 1
        ;;
    esac
done

if [ "$FAST" == false ]; then
    check_systemctl_services
    check_rejection
    check_exception
    check_dmesg_ethernet
    check_wan_conn_log
    check_reboot
    check_system_config
    check_sys_features
    check_policies
    check_tc_classes
    check_ipset
    check_conntrack
    check_dhcp
    check_redis
    run_ifconfig
    check_network
    check_portmapping
    check_tag
    check_hosts
    check_docker
    run_lsusb
    check_eth_count
    test -z $SPEED || check_speed
fi
