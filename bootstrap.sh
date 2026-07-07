#!/bin/bash
# Bootstrap the mu2edaq-phone-notification-system Python environment.
# Creates venv/, installs/updates dependencies, and installs the package
# in editable mode. Safe to re-run. Works on Linux (AL9 / Python 3.9+)
# and macOS; on Windows 11 use "py -m venv venv" and venv\Scripts\pip.
set -euo pipefail
cd "$(dirname "$0")"

PYTHON=${PYTHON:-python3}

if [ ! -d venv ]; then
    echo "Creating virtual environment in venv/ ..."
    "$PYTHON" -m venv venv
fi

venv/bin/pip install --upgrade pip >/dev/null
venv/bin/pip install -r requirements.txt
venv/bin/pip install -e .

# Install the discovery sibling if it is checked out next to us, so the
# server announces itself and publishers can find it.
if [ -d ../mu2edaq-discovery ]; then
    venv/bin/pip install -e ../mu2edaq-discovery
fi

mkdir -p data core

echo
echo "Bootstrap complete."
echo "  Run the server:  ./start-mu2edaq-notify-server.sh"
echo "  Run the tests:   venv/bin/pytest"
echo "  Build the C++ library:  cmake -S . -B build && cmake --build build"
