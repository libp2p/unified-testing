#!/usr/bin/env bash
set -e

# Set routes to peer subnets (mirrors images/rust/v0.56/run-relay.sh)
echo "Setting route to dialer subnet ${DIALER_LAN_SUBNET} via ${DIALER_ROUTER_IP}" >&2
ip route add "${DIALER_LAN_SUBNET}" via "${DIALER_ROUTER_IP}" dev wan0
echo "Setting route to listener subnet ${LISTENER_LAN_SUBNET} via ${LISTENER_ROUTER_IP}" >&2
ip route add "${LISTENER_LAN_SUBNET}" via "${LISTENER_ROUTER_IP}" dev wan0

# Execute the relay, passing through all arguments
exec python /app/relay.py "$@"
