#!/bin/bash
# Runs the unit tests. With only the Command Line Tools installed, SwiftPM does not always pass the
# swift-testing macro plugin path to the compiler; add it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
