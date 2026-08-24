#!/usr/bin/env bash
set -e

# Set route to relay subnet
echo "Setting route to relay subnet ${WAN_SUBNET} via ${WAN_ROUTER_IP}" >&2
ip route add "${WAN_SUBNET}" via "${WAN_ROUTER_IP}" dev lan0

# The harness sets DEBUG when run with --debug. go-libp2p reads GOLOG_LOG_LEVEL
# when its packages initialise, which happens before the binary reaches main,
# so the level is set here rather than in Go.
if [ "${DEBUG}" = "true" ]; then
  export GOLOG_LOG_LEVEL="${GOLOG_LOG_LEVEL:-error,p2p-holepunch=debug,net/identify=debug,basichost=debug,autorelay=debug,relay=debug}"
fi

# Execute the peer binary, passing through all arguments
exec /usr/local/bin/peer "$@"
