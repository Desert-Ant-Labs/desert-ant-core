import assert from "node:assert/strict";
import { test } from "node:test";
import { FfiWriter, FfiReader } from "@desert-ant-labs/core";

import { call } from "../codec.js";

function fakeModel() {
  const calls = [];
  return {
    calls,
    async run(input, options, callOptions) {
      calls.push(callOptions);
      return new FfiReader(new FfiWriter().str("[]").done());
    },
  };
}

test("a call passes its device id to the run, and no device id when it has none", async () => {
  const model = fakeModel();
  await call(model, "faces", {}, null, "device-7");
  await call(model, "faces", {});
  assert.deepEqual(model.calls, [{ deviceId: "device-7" }, { deviceId: undefined }]);
});
