// Loaded with --import before every Node test file in the repo, and by the child processes those tests spawn.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";

// Usage goes to a closed local port whatever the shell sets; a test with a capture server sets its own after this.
process.env.DAL_INGEST_ENDPOINT = "http://127.0.0.1:1/ingest";

// A usage namespace of this process's own, whatever the shell sets; a test that needs its own id derives it from this one.
const namespace = `ai.desertant.test.${process.pid}.${randomUUID()}`;
process.env.DAL_APP_ID = namespace;
delete process.env.DAL_API_KEY;
delete process.env.DAL_DEVICE_ID;

// A throwaway home, inherited by children; the downloaded models stay shared through a link to the real cache folder.
const realHome = os.homedir();
const home = fs.mkdtempSync(path.join(os.tmpdir(), `dal-test-home-${process.pid}-`));
const caches = process.platform === "darwin" ? path.join("Library", "Caches") : ".cache";
if (process.platform === "darwin" || !process.env.XDG_CACHE_HOME) {
  const models = path.join(realHome, caches, "desert-ant-models");
  fs.mkdirSync(models, { recursive: true });
  fs.mkdirSync(path.join(home, caches), { recursive: true });
  // A junction on Windows, which needs no admin rights; the type is ignored elsewhere.
  fs.symlinkSync(models, path.join(home, caches, "desert-ant-models"), "junction");
}
process.env.HOME = home;
process.env.USERPROFILE = home;
process.env.XDG_CONFIG_HOME = path.join(home, ".config");
process.env.CFFIXED_USER_HOME = home;
process.on("exit", () => fs.rmSync(home, { recursive: true, force: true }));

// Whether a test process is still running; a run killed before its exit cleanup leaves state that names its pid.
function running(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

// Throwaway homes left by killed runs.
for (const entry of fs.readdirSync(os.tmpdir())) {
  const match = /^dal-test-home-(\d+)-/.exec(entry);
  if (match && !running(Number(match[1]))) fs.rmSync(path.join(os.tmpdir(), entry), { recursive: true, force: true });
}

// macOS UserDefaults writes the real "node" domain whatever the home: this deletes, at startup, the keys of test processes that no
// longer run, and at exit the keys under this process's namespace, and nothing else.
if (process.platform === "darwin") {
  const env = { ...process.env, HOME: realHome };
  delete env.CFFIXED_USER_HOME;
  const usageKeys = () => {
    const exported = spawnSync("defaults", ["export", "node", "-"], { encoding: "utf8", env, maxBuffer: 64 * 1024 * 1024 });
    return exported.status === 0 ? [...exported.stdout.matchAll(/<key>([^<]*)<\/key>/g)].map((match) => match[1]) : [];
  };
  const remove = (keys) => {
    for (const key of keys) spawnSync("defaults", ["delete", "node", key], { stdio: "ignore", env });
  };
  remove(
    usageKeys().filter((key) => {
      const match = /^ai\.desertant\.usage\.ai\.desertant\.test\.(\d+)\./.exec(key);
      return match !== null && !running(Number(match[1]));
    }),
  );
  process.on("exit", () => {
    const prefix = `ai.desertant.usage.${namespace}`;
    remove(usageKeys().filter((key) => key === prefix || key.startsWith(`${prefix}.`)));
  });
}
