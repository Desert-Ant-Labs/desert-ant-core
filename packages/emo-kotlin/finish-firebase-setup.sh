#!/usr/bin/env bash
# One-shot: activate a Firebase/GCP service-account key, point gcloud at its
# project, enable the Test Lab APIs, and run the Android instrumented test on
# Firebase Test Lab. Everything else (gcloud, the Android SDK, the built APK,
# the runner) is already set up on this box.
#
#   ./finish-firebase-setup.sh /path/to/service-account-key.json
#
# The service account needs (in a Blaze-billed project): role
# "Firebase Test Lab Admin" + "Editor" (or Storage access for the results bucket).
set -euo pipefail

KEY="${1:?usage: finish-firebase-setup.sh /path/to/service-account-key.json}"
[ -f "$KEY" ] || { echo "error: key file not found: $KEY" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

echo "==> Activating service account"
gcloud auth activate-service-account --key-file="$KEY"

PROJECT=$(python3 -c "import json,sys;print(json.load(open('$KEY'))['project_id'])")
echo "==> Using project: $PROJECT"
gcloud config set project "$PROJECT" >/dev/null

echo "==> Enabling Test Lab APIs (one-time; may take a minute)"
gcloud services enable testing.googleapis.com toolresults.googleapis.com

echo "==> Running the Android instrumented test on Firebase Test Lab"
exec "$HERE/run-firebase-test.sh"
