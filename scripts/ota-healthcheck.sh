#!/usr/bin/env bash
exec "$(dirname "$0")/qos-ota.sh" healthcheck "$@"
