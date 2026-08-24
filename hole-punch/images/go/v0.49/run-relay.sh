#!/usr/bin/env bash
set -e

# Set route to dialer subnet
echo "Setting route to dialer subnet ${DIALER_LAN_SUBNET} via ${DIALER_ROUTER_IP}" >&2
ip route add "${DIALER_LAN_SUBNET}" via "${DIALER_ROUTER_IP}" dev wan0

# Set route to listener subnet
echo "Setting route to listener subnet ${LISTENER_LAN_SUBNET} via ${LISTENER_ROUTER_IP}" >&2
ip route add "${LISTENER_LAN_SUBNET}" via "${LISTENER_ROUTER_IP}" dev wan0

# The harness sets DEBUG when run with --debug. go-libp2p reads GOLOG_LOG_LEVEL
# when its packages initialise, which happens before the binary reaches main,
# so the level is set here rather than in Go.
if [ "${DEBUG}" = "true" ]; then
  export GOLOG_LOG_LEVEL="${GOLOG_LOG_LEVEL:-error,p2p-holepunch=debug,net/identify=debug,basichost=debug,autorelay=debug,relay=debug}"
fi

# Execute the relay binary, passing through all arguments
exec /usr/local/bin/relay "$@"
