#!/usr/bin/env bash
set -u

link_name=""
local_inside=""
remote_inside=""
mark=""
route_metric=""
remote_cidr=""
local_cidr=""

while [[ $# -gt 1 ]]; do
  case "$1" in
    --link-name) link_name="$2" ;;
    --local-inside) local_inside="$2" ;;
    --remote-inside) remote_inside="$2" ;;
    --mark) mark="$2" ;;
    --metric) route_metric="$2" ;;
    --remote-cidr) remote_cidr="$2" ;;
    --local-cidr) local_cidr="$2" ;;
    *) logger -t aws-vti-updown "Ignoring unknown argument: $1" ;;
  esac
  shift 2
done

physical_interface="${PLUTO_INTERFACE:-$(ip route show default | awk 'NR == 1 {print $5}')}"
local_endpoint="${PLUTO_ME:-}"
remote_endpoint="${PLUTO_PEER:-}"

require_value() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || { logger -t aws-vti-updown "Missing required value: $name"; exit 1; }
}

for pair in \
  "link_name:$link_name" \
  "local_inside:$local_inside" \
  "remote_inside:$remote_inside" \
  "mark:$mark" \
  "route_metric:$route_metric" \
  "remote_cidr:$remote_cidr" \
  "local_cidr:$local_cidr" \
  "physical_interface:$physical_interface" \
  "local_endpoint:$local_endpoint" \
  "remote_endpoint:$remote_endpoint"; do
  require_value "${pair%%:*}" "${pair#*:}"
done

iptables_add() {
  local table="$1"
  shift
  iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
}

iptables_delete() {
  local table="$1"
  shift
  iptables -t "$table" -C "$@" 2>/dev/null && iptables -t "$table" -D "$@" || true
}

bring_up() {
  if ! ip link show "$link_name" >/dev/null 2>&1; then
    ip link add "$link_name" type vti local "$local_endpoint" remote "$remote_endpoint" key "$mark"
  fi

  ip addr replace "$local_inside/30" peer "$remote_inside/30" dev "$link_name"
  ip link set "$link_name" up mtu 1422
  sysctl -q -w net.ipv4.ip_forward=1
  sysctl -q -w "net.ipv4.conf.$link_name.rp_filter=2"
  sysctl -q -w "net.ipv4.conf.$link_name.disable_policy=1"
  sysctl -q -w "net.ipv4.conf.$physical_interface.disable_xfrm=1"
  sysctl -q -w "net.ipv4.conf.$physical_interface.disable_policy=1"

  ip route replace "$remote_cidr" dev "$link_name" metric "$route_metric"
  iptables_add filter FORWARD -i "$physical_interface" -o "$link_name" -s "$local_cidr" -d "$remote_cidr" -j ACCEPT
  iptables_add filter FORWARD -i "$link_name" -o "$physical_interface" -s "$remote_cidr" -d "$local_cidr" -j ACCEPT
  iptables_add mangle FORWARD -o "$link_name" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1382
  iptables_add mangle INPUT -p esp -s "$remote_endpoint" -d "$local_endpoint" -j MARK --set-xmark "$mark"
  ip route flush table 220 || true
  netfilter-persistent save >/dev/null 2>&1 || true
}

bring_down() {
  iptables_delete filter FORWARD -i "$physical_interface" -o "$link_name" -s "$local_cidr" -d "$remote_cidr" -j ACCEPT
  iptables_delete filter FORWARD -i "$link_name" -o "$physical_interface" -s "$remote_cidr" -d "$local_cidr" -j ACCEPT
  iptables_delete mangle FORWARD -o "$link_name" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1382
  iptables_delete mangle INPUT -p esp -s "$remote_endpoint" -d "$local_endpoint" -j MARK --set-xmark "$mark"
  ip route del "$remote_cidr" dev "$link_name" metric "$route_metric" 2>/dev/null || true
  ip link del "$link_name" 2>/dev/null || true
  netfilter-persistent save >/dev/null 2>&1 || true
}

case "${PLUTO_VERB:-}" in
  up-client) bring_up ;;
  down-client) bring_down ;;
  *) logger -t aws-vti-updown "No action for PLUTO_VERB=${PLUTO_VERB:-unset}" ;;
esac
