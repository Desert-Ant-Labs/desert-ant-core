# EmoWasmExample

Node and headless-browser examples for `@desert-ant-labs/emo`.

```bash
npm install
npm run node-example      # API-shape smoke test (LiteRT.js is browser-only)
npm run browser-example   # headless Chromium + LiteRT.js (needs playwright)
```

The browser example suggests emoji for a phrase on device via LiteRT.js.
LiteRT.js needs a DOM, so the Node example only exercises the API shape and the
graceful "runtime absent" path. The browser example downloads the model from the
Hugging Face Hub on first use (the SDK's default) and caches it, then runs fully
on device via LiteRT.js. Pass `modelBaseUrl` to `Emo.load` to self-host the model
files instead.
