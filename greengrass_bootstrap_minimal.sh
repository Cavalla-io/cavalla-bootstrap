#!/usr/bin/env bash
# Deprecated name: use greengrass_bootstrap.sh (same flags and behavior).
# This file remains so old curl URLs and docs keep working.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/greengrass_bootstrap.sh" "$@"
