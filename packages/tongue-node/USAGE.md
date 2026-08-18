# Usage reporting

How the usage turnstile works in this SDK, and — since this is the first Desert
Ant model that could not get it for free — how to add it to the next model built
the same way.

## What is reported

`load` events, POSTed to `https://platform.desertant.ai/api/v1/ingest`:

```json
{
  "platform": "android",
  "app": { "id": "com.acme.app" },
  "sdk": { "name": "tongue-kotlin", "version": "0.1.0" },
  "sentAt": "2026-07-27T19:40:00.000Z",
  "events": [{ "name": "load", "deviceId": "9f1c…", "callCount": 12 }]
}
```

- **`deviceId`** is a v4 UUID generated on the device on first use and persisted.
  It is not a hardware identifier, not an advertising id, and not derived from
  anything about the user or the machine.
- **`app.id`** is the bundle id or package name — the app, not the person.
- **`callCount`** is how many detections happened, summed server-side.
- **No text is ever sent.** Nothing that was detected, no language results, no
  input length. The pipeline never touches the network; only the turnstile does.

### How often

One device is *counted* at most once a day, but that is not the same as one
request a day, and it is worth being precise because the difference is visible in
a network log:

- The **turnstile** — the billed event — opens once per window: a day on Apple,
  Android and Node, **30 minutes in a browser**, because a tab is ephemeral and
  core uses a session-shaped window there.
- After it opens, further detections in that session ride **delta events**, which
  flush on a 3-second debounce. A burst of typing is one request, but a session
  that keeps detecting keeps sending small ones.

Extra events cannot over-bill: the server counts `COUNT(DISTINCT deviceId)` per
month and sums `callCount`, so the number of requests changes nothing about what
is charged. It does mean a busy browser tab can post more than once an hour.

This is billing metering, not product analytics: the licence is free below a
threshold and commercial above it, and monthly active devices is the measure.

## Turning it off

Set `DAL_USAGE_DISABLED=1` (env var, or a JVM system property on Kotlin, or
`globalThis.__dalUsageDisabled` in a browser). No client is constructed at all, so
nothing is stored and no request is made.

Every task in this repository sets it — see `mise.toml` and `.github/workflows/ci.yml`.
A CI runner is not a billable device, and without the guard each push would count
as one.

## Why this SDK had to implement it

In emo, redact and shapes nobody writes usage code. Those SDKs depend on
desert-ant-core's `Inference`, `Inference` depends on `Usage`, and its session
factory wraps every session in a `TrackedSession` — the concrete backends are
non-public, so an SDK can only obtain a tracked session. Their Kotlin and
JavaScript packages then inherit it too, because both are bridges (JNI, and a
native/wasm binding) over that same Swift core.

Tongue has neither half of that:

|  | emo / redact / shapes | tongue |
|---|---|---|
| Inference runtime | Core ML / LiteRT session | none — a detection is an int8 gather, a sum, one 59×32 matmul and a masked softmax |
| Swift | `Inference` → `Usage`, automatic | no `Inference` dependency; wires `Usage` directly |
| Kotlin | JNI bridge over Swift | independent port — no Swift underneath |
| JavaScript | native/wasm bridge over Swift | independent port — no Swift underneath |

So there is no session to wrap, and two of the three platforms have no Swift to
inherit from. The result is three implementations of one state machine.

## How it is wired here

| Platform | Client | Storage | Transport |
|---|---|---|---|
| Swift | core's `Usage` module, unchanged | core's (UserDefaults / SharedPreferences via host bridge) | core's |
| Kotlin | `usage/UsageClient.kt`, a port | SharedPreferences via a `Context`, else `java.util.prefs`, else memory | `HttpURLConnection` on one daemon thread |
| JavaScript | `usage.ts`, a port | `__dalUsageStore` → `localStorage` → a JSON file under `~/.desert-ant` on Node → memory | `fetch(keepalive)`, `sendBeacon` on unload |

Each opens the turnstile when the model is constructed, records a call per
`detect`, and flushes on a 3-second debounce so a burst of keystrokes becomes one
send. That mirrors core's `TrackedSession`.

Two constraints shaped the ports:

- **The Kotlin artifact is a plain jar declaring nothing but kotlin-stdlib**, and must keep
  running on a bare JVM, so it cannot compile against the Android SDK. An Android
  caller passes its `Context` to `Tongue.bundled(context)` and it is used
  reflectively. Without a `Context` on Android there is nowhere durable to keep
  the device id, and every process would look like a new device — so pass it.
- **JSON is written by hand** in Kotlin for the same reason. The shape is six
  fields; a JSON library would add a transitive dependency to every consumer.

## The transport is exercised, not just the state machine

Every turnstile test injects `send`, so for a while nothing proved a body ever
left the process. All three now drive their real HTTP client at a local server
and assert what arrives:

| Port | client | test |
|---|---|---|
| Swift | core's `makeSend`, unmodified | verified manually against a local server; nothing here can regress it |
| Kotlin | `HttpURLConnection` | `UsageVectorTest.transportActuallyPostsTheBodyOverHttp` |
| JavaScript | `fetch(keepalive)` | "the transport actually posts the body over HTTP" |

One difference worth knowing before anyone diffs packet captures: Swift serializes
through Foundation's `JSONEncoder` and emits **alphabetical** key order, while the
two ports emit core's declaration order. JSON object order carries no meaning and
the server parses either, but the bytes are not identical across all three — only
Kotlin and JavaScript are, and that pair is asserted byte for byte.

The one thing still unproven is delivery to the production endpoint itself. It
resolves and completes a TLS handshake, but no event has been sent from here:
doing so would put a development machine into real billing data.

## Keeping the three honest

`usage_vectors.json` is the contract, replayed by the Kotlin and JavaScript ports
against their own clients — the same approach as the model's normalizer, hasher
and router vectors. It covers the window, the carry, the delta load and
double-start. The file is deliberately flat parallel arrays so both ports read it
with their existing minimal readers rather than taking a JSON dependency.

This matters more than it looks. A wrong turnstile does not produce a visible bug:
detection keeps working perfectly and the billing number is quietly wrong. The
vectors are the only thing that would catch a port drifting.

## Adding this to the next model

If the next SDK has an inference runtime, do nothing — depend on `Inference` and
it is handled. If it looks like this one (no runtime, direct ports rather than
bridges):

1. Add `.product(name: "Usage", package: "desert-ant-core")` to the Swift target
   and open a client where the model is constructed. Core does the rest.
2. Port `UsageClient` to each non-Swift platform. It is ~120 lines: the window
   check, the pending event, the carry, and the delta path.
3. Match core's storage keys exactly — `ai.desertant.usage.deviceId`, and
   `ai.desertant.usage.<appKey>.<deviceId>.state` holding
   `"<lastActiveAt>,<carryCallCount>"`. An app embedding two Desert Ant SDKs must
   count as one device, and it only does if both read the same key.
4. Copy `usage_vectors.json` and wire the replay test before trusting the port.
5. Set `DAL_USAGE_DISABLED=1` across the repo's own tasks and CI, first, so no
   build ever bills.
