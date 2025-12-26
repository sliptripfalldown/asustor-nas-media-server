#!/bin/bash
# Start FlareSolverr with non-snap Chromium
export CHROME_EXE_PATH=/usr/bin/chromium
export LOG_LEVEL=info
exec /usr/bin/python3 /opt/FlareSolverr/src/flaresolverr.py
