#!/usr/bin/env python3
"""Verify Maven publication metadata and run the published-artifact smoke apps."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET
from zipfile import ZIP_DEFLATED, ZipFile


GROUP = "ai.desertant"
NAMESPACE = {"m": "http://maven.apache.org/POM/4.0.0"}
APP = "ai.desertant.consumer.handshake"


def artifact(repo, module, version, extension):
    return repo / "ai/desertant" / module / version / f"{module}-{version}.{extension}"


def verify(repo, version, models, jvm_models):
    expected = {"core", *models}
    namespace = NAMESPACE
    pom = ET.parse(artifact(repo, "bom", version, "pom"))
    assert pom.findtext("m:packaging", namespaces=namespace) == "pom"
    constraints = {
        dependency.findtext("m:artifactId", namespaces=namespace): (
            dependency.findtext("m:groupId", namespaces=namespace),
            dependency.findtext("m:version", namespaces=namespace),
            dependency.findtext("m:type", "jar", namespaces=namespace),
        )
        for dependency in pom.findall("m:dependencyManagement/m:dependencies/m:dependency", namespace)
    }
    assert constraints == {
        name: (GROUP, version, "jar" if name in jvm_models else "aar") for name in expected
    }, constraints

    metadata = json.loads(artifact(repo, "bom", version, "module").read_text())
    for variant in metadata["variants"]:
        constraints = {(entry["group"], entry["module"], entry["version"]["requires"])
                       for entry in variant["dependencyConstraints"]}
        assert constraints == {(GROUP, name, version) for name in expected}, variant["name"]

    for name in expected:
        pom = ET.parse(artifact(repo, name, version, "pom"))
        imports = pom.findall("m:dependencyManagement/m:dependencies/m:dependency", namespace)
        assert any(tuple(entry.findtext(f"m:{key}", namespaces=namespace)
                         for key in ("groupId", "artifactId", "version", "type", "scope"))
                   == (GROUP, "bom", version, "pom", "import") for entry in imports), name
        core = [entry for entry in pom.findall("m:dependencies/m:dependency", namespace)
                if entry.findtext("m:artifactId", namespaces=namespace) == "core"]
        if name == "core" or name in jvm_models:
            assert not core, name
        else:
            assert len(core) == 1 and core[0].findtext("m:type", namespaces=namespace) == "aar", name
        metadata = json.loads(artifact(repo, name, version, "module").read_text())
        for variant in metadata["variants"]:
            if not variant["name"].endswith(("ApiElements", "RuntimeElements", "apiElements", "runtimeElements")):
                continue
            assert any(dep["group"] == GROUP and dep["module"] == "bom"
                       and dep["version"]["requires"] == version
                       and dep["attributes"]["org.gradle.category"] == "platform"
                       for dep in variant["dependencies"]), (name, variant["name"])
    print(f"Verified BOM constraints and imports for {len(expected)} published modules at {version}")


def stale_native(repo, dest, version, legacy):
    # Keep the new Emo classes and Maven metadata but substitute the legacy JNI
    # binaries. An isolated repository keeps this fault out of the normal build.
    for module in ("bom", "core", "emo"):
        shutil.copytree(artifact(repo, module, version, "pom").parent,
                        artifact(dest, module, version, "pom").parent)
    aar = artifact(dest, "emo", version, "aar")
    patched = aar.with_suffix(".tmp")
    with (ZipFile(aar) as current,
          ZipFile(artifact(repo, "emo", legacy, "aar")) as previous,
          ZipFile(patched, "w", ZIP_DEFLATED) as output):
        for entry in current.namelist():
            source = previous if entry.startswith("jni/") and entry.endswith(".so") else current
            output.writestr(entry, source.read(entry))
    patched.replace(aar)

    module = artifact(dest, "emo", version, "module")
    metadata = json.loads(module.read_text())
    contents = aar.read_bytes()
    for variant in metadata["variants"]:
        for entry in variant.get("files", []):
            if entry["url"] == aar.name:
                entry["size"] = len(contents)
                for algorithm in ("sha512", "sha256", "sha1", "md5"):
                    entry[algorithm] = hashlib.new(algorithm, contents).hexdigest()
    module.write_text(json.dumps(metadata) + "\n")


def older_platform(repo, version, older):
    # The first BOM release has no released predecessor with a platform. Clone
    # the published coordinates for the resolution test. These bytes are never run.
    for name in ("bom", "core", "emo"):
        target = artifact(repo, name, older, "pom").parent
        target.mkdir(parents=True)
        for extension in ("pom", "module"):
            source = artifact(repo, name, version, extension)
            artifact(repo, name, older, extension).write_text(source.read_text().replace(version, older))
        if name != "bom":
            source = artifact(repo, name, version, "aar")
            artifact(repo, name, older, "aar").hardlink_to(source)


def run(prepared, serial, results):
    version = (prepared / "version").read_text().strip()
    cases = {
        "matching": None,
        "legacy-core": f"model artifact {version}, core (version unavailable)",
        "stale-native": f"native library (version unavailable), core {version}",
    }
    results.mkdir(parents=True, exist_ok=True)
    adb = [shutil.which("adb") or "adb", "-s", serial]
    for name, expected in cases.items():
        directory = prepared / name
        subprocess.run(adb + ["install", "-r", "-t", str(directory / "app.apk")], check=True, timeout=120)
        subprocess.run(adb + ["install", "-r", "-t", str(directory / "test.apk")], check=True, timeout=120)
        cmd = adb + ["shell", "am", "instrument", "-w"]
        if expected:
            # adb shell reconstructs a remote command from its arguments.
            cmd += ["-e", "expectedMismatch", f"'{expected}'"]
        result = subprocess.run(cmd + [APP + ".test/androidx.test.runner.AndroidJUnitRunner"],
                                capture_output=True, text=True, timeout=120)
        output = result.stdout + result.stderr
        (results / f"consumer-{name}.txt").write_text(output)
        if result.returncode != 0 or "OK (1 test)" not in output:
            raise RuntimeError(f"Consumer handshake failed for {name}:\n{output}")
        print(f"Consumer handshake passed for {name}")


def main():
    parser = argparse.ArgumentParser()
    actions = parser.add_subparsers(dest="action", required=True)
    check = actions.add_parser("verify")
    check.add_argument("repo", type=Path)
    check.add_argument("version")
    check.add_argument("models")
    check.add_argument("jvm_models")
    stale = actions.add_parser("stale-native")
    stale.add_argument("repo", type=Path)
    stale.add_argument("destination", type=Path)
    stale.add_argument("version")
    stale.add_argument("legacy")
    older = actions.add_parser("older-platform")
    older.add_argument("repo", type=Path)
    older.add_argument("version")
    older.add_argument("older")
    device = actions.add_parser("run")
    device.add_argument("prepared", type=Path)
    device.add_argument("serial")
    device.add_argument("results", type=Path)
    args = parser.parse_args()
    if args.action == "verify":
        verify(args.repo, args.version, args.models.split(","), args.jvm_models.split(","))
    elif args.action == "stale-native":
        stale_native(args.repo, args.destination, args.version, args.legacy)
    elif args.action == "older-platform":
        older_platform(args.repo, args.version, args.older)
    else:
        run(args.prepared, args.serial, args.results)


if __name__ == "__main__":
    main()
