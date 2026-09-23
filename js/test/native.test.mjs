// The libcurl probe in src/native.js, against fake cores: a host without
// libcurl must get an ordinary error from load(), not an abort later.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkLibcurl } from "../src/native.js";

const core = (probe) => ({
  func(proto) {
    assert.equal(proto, "int dal_curl_available()");
    if (!probe) throw new Error("symbol not found");
    return probe;
  },
});

test("a Linux core that cannot open libcurl throws the install hint", () => {
  assert.throws(() => checkLibcurl(core(() => 0), "@desert-ant-labs/align", "linux"), {
    message: /^@desert-ant-labs\/align: libcurl is required \(downloads and usage reporting\).*Install libcurl4/,
  });
});

test("a Linux core that opened libcurl passes", () => {
  checkLibcurl(core(() => 1), "pkg", "linux");
});

test("a core built before the probe existed is not checked", () => {
  checkLibcurl(core(null), "pkg", "linux");
});

test("other platforms never ask", () => {
  checkLibcurl({ func: () => assert.fail("probed off Linux") }, "pkg", "darwin");
});
