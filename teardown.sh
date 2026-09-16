#!/usr/bin/env bash
# Tears down the whole lab cluster. Fastest reliable reset between sessions.
set -euo pipefail
minikube delete
