#!/bin/bash
cd "$(dirname "$0")"
source ./script/setup.sh

./build-debug.sh
# Kill any other running copy (installed 'AeroSpace' or a prior dev 'AeroSpaceApp')
# before launching — same bundle id 'bobko.aerospace', different process names, so
# neither killalls the other otherwise → two instances / doubled menu-bar workspaces.
killall AeroSpace AeroSpaceApp 2>/dev/null
./.debug/AeroSpaceApp "$@"
