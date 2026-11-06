// The host's side of the SDK's log (src/log.js), and how the native loader
// applies it to a core (installLogging), against a fake core.
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { DesertAnt, hostLogLevel, hostLogHandler, LOG_LEVELS } from "../src/log.js";
import { installLogging } from "../src/native.js";

afterEach(() => {
  delete globalThis.__dalLogLevel;
  delete globalThis.__dalLog;
  delete globalThis[Symbol.for("desert-ant-labs.log-installers")];
});

// A core with the two symbols, recording what it was told.
function fakeCore(calls, { withLogger = true } = {}) {
  return {
    func(proto, ret, args) {
      if (proto === "int dal_set_log_level(int)") return (level) => (calls.push(["level", level]), 0);
      if (proto === "dal_set_logger" && withLogger) {
        assert.equal(ret, "int");
        assert.equal(args.length, 1);
        return (fn) => (calls.push(["logger", fn]), 0);
      }
      throw new Error(`symbol not found: ${proto}`);
    },
  };
}

const fakeKoffi = {
  version: "2.16.3",
  pointer: (p) => p,
  proto: (ret, args) => ({ ret, args }),
  register: (fn) => ({ registered: fn }),
  unregister() {},
};

test("the level names are the core's raw values in order", () => {
  assert.deepEqual(LOG_LEVELS, ["debug", "info", "warning", "error", "off"]);
});

test("DesertAnt.logLevel writes the global and rejects an unknown name", () => {
  assert.equal(DesertAnt.logLevel, "warning");
  DesertAnt.logLevel = "Info ";
  assert.equal(globalThis.__dalLogLevel, "info");
  assert.equal(hostLogLevel(), "info");
  assert.equal(DesertAnt.logLevel, "info");
  assert.throws(() => { DesertAnt.logLevel = "loud"; }, /expected one of debug, info, warning, error, off/);
});

test("aliases a host may have copied from another tool are read", () => {
  globalThis.__dalLogLevel = "WARN";
  assert.equal(hostLogLevel(), "warning");
  globalThis.__dalLogLevel = "silent";
  assert.equal(hostLogLevel(), "off");
  globalThis.__dalLogLevel = 3;
  assert.equal(hostLogLevel(), null);
});

test("DesertAnt.logger writes the global and null clears it", () => {
  const handler = () => {};
  DesertAnt.logger = handler;
  assert.equal(hostLogHandler(), handler);
  assert.equal(DesertAnt.logger, handler);
  DesertAnt.logger = null;
  assert.equal(hostLogHandler(), null);
  assert.throws(() => { DesertAnt.logger = "nope"; }, /expected a function or null/);
});

test("a core loaded after the host set a level and a handler gets both", () => {
  const seen = [];
  DesertAnt.logLevel = "debug";
  DesertAnt.logger = (level, source, message) => seen.push([level, source, message]);
  const calls = [];
  installLogging(fakeCore(calls), fakeKoffi);
  assert.deepEqual(calls[0], ["level", 0]);
  assert.equal(calls[1][0], "logger");
  // The registered callback hands the core's raw level to the host as a name.
  calls[1][1].registered(2, "litert", "GPU accelerator could not be loaded");
  assert.deepEqual(seen, [["warning", "litert", "GPU accelerator could not be loaded"]]);
});

test("a change after load reaches a core already loaded", () => {
  const calls = [];
  installLogging(fakeCore(calls), fakeKoffi);
  assert.deepEqual(calls, []);
  DesertAnt.logLevel = "off";
  assert.deepEqual(calls, [["level", 4]]);
});

test("a core without a logger symbol still takes the level", () => {
  DesertAnt.logLevel = "error";
  const calls = [];
  installLogging(fakeCore(calls, { withLogger: false }), fakeKoffi);
  assert.deepEqual(calls, [["level", 3]]);
});

test("a koffi that cannot take callbacks from core threads gets the level only", () => {
  DesertAnt.logLevel = "info";
  DesertAnt.logger = () => {};
  const calls = [];
  installLogging(fakeCore(calls), { ...fakeKoffi, version: "2.15.0" });
  assert.deepEqual(calls, [["level", 1]]);
});

test("a core built before the symbols existed is left alone", () => {
  DesertAnt.logLevel = "info";
  installLogging({ func() { throw new Error("symbol not found"); } }, fakeKoffi);
});
