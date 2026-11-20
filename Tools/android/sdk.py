"""Use the SDK selected by android-sdk and Gradle, on every host platform."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sdk_root(root=ROOT):
    properties = root / 'local.properties'
    if properties.is_file():
        for line in properties.read_text().splitlines():
            key, separator, value = line.partition('=')
            if separator and key.strip() == 'sdk.dir' and value.strip():
                return Path(value.strip())
    for name in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        if os.environ.get(name):
            return Path(os.environ[name])
    raise RuntimeError("Android SDK is not configured; run 'mise run android-sdk'")
