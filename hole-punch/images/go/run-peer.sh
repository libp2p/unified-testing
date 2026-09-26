#!/usr/bin/env bash
set -e

# Set route to relay subnet (mirrors images/rust/v0.56/run-peer.sh)
echo "Setting route to relay subnet ${WAN_SUBNET} via ${WAN_ROUTER_IP}" >&2
ip route add "${WAN_SUBNET}" via "${WAN_ROUTER_IP}" dev lan0

# Mirror the py peer's DEBUG handling for go-libp2p logs.
if [ "${DEBUG:-false}" = "true" ]; then
  export GOLOG_LOG_LEVEL="debug"
fi

# Execute the go peer, passing through all arguments
exec /app/node "$@"
