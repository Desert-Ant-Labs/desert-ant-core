#!/usr/bin/env bash
# Build the self-instrumenting Android instrumented-test APK and run it on
# Firebase Test Lab (real/virtual devices in Google's cloud), so this box can
# validate the Android on-device path without local hardware.
#
# One-time setup (your Google account; see the notes this script prints):
#   gcloud auth login              # or: gcloud auth activate-service-account --key-file=KEY.json
#   gcloud config set project <FIREBASE_PROJECT_ID>
#   gcloud services enable testing.googleapis.com toolresults.googleapis.com
#
# Then just run this script. Override the devices with FTL_DEVICES=... .
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/share/mise/installs/java/temurin-21}"
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

# The library's androidTest APK is self-instrumenting (its <instrumentation>
# targetPackage is its own package), so it is both the app-under-test and the
# test on Firebase Test Lab. The native libs (jniLibs) and the bundled model
# (the emo-tflite-resources androidTest dependency) are inside it.
TEST_APK="build/outputs/apk/androidTest/debug/emo-debug-androidTest.apk"

echo "==> Building the instrumented-test APK (native libs already staged in jniLibs)"
./gradlew :assembleDebugAndroidTest -x buildSwiftNatives --no-daemon
[ -f "$TEST_APK" ] || { echo "error: $TEST_APK not found" >&2; exit 1; }
echo "    $TEST_APK ($(du -h "$TEST_APK" | cut -f1))"

# Choose devices. Prefer real arm64 hardware (production-representative XNNPACK);
# fall back to a virtual arm device. Auto-discovered from the live catalog so a
# stale model name can't fail the run. Override with FTL_DEVICES="--device ...".
if [ -n "${FTL_DEVICES:-}" ]; then
  DEVICES="$FTL_DEVICES"
else
  MODEL=$(gcloud firebase test android models list --filter="form=PHYSICAL AND tags:default" --format="value(id)" 2>/dev/null | head -1)
  [ -n "$MODEL" ] || MODEL=$(gcloud firebase test android models list --filter="form=PHYSICAL" --format="value(id)" 2>/dev/null | head -1)
  if [ -n "$MODEL" ]; then
    VER=$(gcloud firebase test android models describe "$MODEL" --format="value(supportedVersionIds)" 2>/dev/null | tr ',;[] ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1)
    DEVICES="--device model=$MODEL,version=${VER:-34},locale=en,orientation=portrait"
  else
    DEVICES="--device model=MediumPhone.arm,version=34,locale=en,orientation=portrait"
  fi
  echo "    devices: $DEVICES"
fi

echo "==> Submitting to Firebase Test Lab"
# shellcheck disable=SC2086
gcloud firebase test android run \
  --type instrumentation \
  --app "$TEST_APK" \
  --test "$TEST_APK" \
  --timeout 5m \
  --use-orchestrator=false \
  $DEVICES
