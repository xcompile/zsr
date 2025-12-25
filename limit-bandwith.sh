#!/usr/bin/env bash
set -euo pipefail
#set -x

# Check if correct parameters are passed
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 <interface> <target_url> <limit_rate> [remove]"
    echo "Example: $0 eth0 example.com 512kbit"
    echo "To remove throttling rules: $0 eth0 example.com <limit_rate> remove"
    exit 1
fi

show_status() {
  local dev="$1"
  tc qdisc show dev "$dev"
  tc class show dev "$dev"
  tc filter show dev "$dev"
}

remove_rules() {

    # Optionally remove the root qdisc if no other classes exist
    if ! tc -s class show dev "$DEVICE" | grep -q "classid 1:1"; then
         tc qdisc del dev "$DEVICE" root || true
    fi
    # Remove previous rules and classes related to the target IP
     tc filter del dev "$DEVICE" protocol ip parent 1: prio 1 u32 match ip dst "$DEST_IP" flowid "$CLASS_ID" 2>/dev/null || true
     tc class del dev "$DEVICE" classid "$CLASS_ID" 2>/dev/null || true

    echo "Throttling rules removed for $TARGET_URL (IP: $DEST_IP) on interface $DEVICE."
}

verify_device() {
  local dev="$1"
  # Verify the network interface
  if ! ip link show "$dev" > /dev/null 2>&1; then
      echo "Error: Network interface $dev does not exist."
      exit 1
  fi
}

DEVICE="$1"
TARGET_URL="$2"
LIMIT_RATE="$3"
LIMIT_RATE="$3"
DEFAULT_CLASS_ID="30"
CLASS_ID="1:1"
REMOVE="${4:-}"

verify_device $DEVICE

# Resolve the target URL to an IP address
DEST_IP=$(dig +short "$TARGET_URL")

if [ -z "$DEST_IP" ]; then
    echo "Could not resolve $TARGET_URL to an IP address."
    exit 1
fi


# Remove previous rules and classes related to the target IP
# tc filter del dev "$DEVICE" protocol ip parent 1: prio 1 u32 match ip dst "$DEST_IP" flowid "$CLASS_ID" 2>/dev/null
#tc class del dev "$DEVICE" classid "$CLASS_ID" 2>/dev/null
remove_rules
if [ "$REMOVE" = "remove" ]; then
  ethtool -K enp5s0 tso on
  exit 0
fi
ethtool -K enp5s0 tso off
# Add a new root qdisc using HTB if it doesn't exist
if ! tc qdisc show dev "$DEVICE" | grep -q "htb"; then
     tc qdisc add dev "$DEVICE" root handle 1: htb default "$DEFAULT_CLASS_ID"
fi

# Add the class for the bandwidth limitation
 tc class add dev "$DEVICE" parent 1: classid "$CLASS_ID" htb rate "$LIMIT_RATE" burst "$LIMIT_RATE"
 #tc qdisc add dev eth0 parent 1:$CLASS_ID handle $CLASS_ID: sfq perturb 10
 #tc qdisc add dev eth0 parent 1:$DEFAULT_CLASS_ID handle $DEFAULT_CLASS_ID: sfq perturb 10

# Add the filter for the specified destination IP
 tc filter add dev "$DEVICE" protocol ip parent 1: prio 1 u32 match ip dst "$DEST_IP" flowid "$CLASS_ID"

echo "Bandwidth limit of $LIMIT_RATE set for $TARGET_URL (IP: $DEST_IP) on interface $DEVICE."
show_status $DEVICE
