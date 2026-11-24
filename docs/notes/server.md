# Run on a server

On a server, one process runs a model for many end-user devices. The license counts one device for each of them, so the SDK needs to know which device each call serves. Set a secret once, and pass a device id with every call. The license requires both on a server.

## Set it up

Set the API key and a device id secret before the first model loads. A model that runs before `configure` asks for one license for the server itself, with no key. Use a key of the Server platform from [platform.desertant.com](https://platform.desertant.com).

```js
import { DesertAnt, Emo } from "@desert-ant-labs/emo/native";

DesertAnt.configure({
  apiKey: process.env.DAL_API_KEY,
  deviceIdSecret: process.env.DAL_DEVICE_ID_SECRET,
});
const emo = await Emo.load();
```

```swift
import DesertAnt
import Emo

DesertAnt.configure(apiKey: apiKey, deviceIdSecret: deviceIdSecret)
let emo = Emo()
```

In Node, import a model from its `/native` entry, as here. The default entry is the browser build. Voz and Tongue have one entry for both. The variable names are yours: the SDK does not read them.

Then pass the device id of the end user's device with each call:

```js
const suggestions = await emo.suggestions(text, { deviceId: request.deviceId });
```

```swift
let suggestions = try await InferenceContext.$deviceId.withValue(request.deviceId) {
    try await emo.suggestions(for: text)
}
```

## The device id

A device id is any text that stays the same for one end-user device or browser, and differs between devices. Your app or web page makes a random id once, stores it, and sends it with each request to your server. A user account does not qualify, because one person can use two devices.

The device id never leaves your server. The SDK turns it into an install id with the secret (HMAC-SHA256) and sends only the install id. Only someone who has the secret can link an install id to a device id.

## The secret

`deviceIdSecret` is 32 or more random bytes as text, for example from `openssl rand -hex 32`. Keep it on your servers, give every server the same one, and do not change it. A new secret gives every device a new install id, so each device counts again that month.

The install id also includes the app id, which is the process name by default, such as `node`. Set `DAL_APP_ID` to the app ID you added to your Server key on [platform.desertant.com](https://platform.desertant.com), the same on all your servers. Each application on a server uses its own app ID, so that its install ids differ from every other app's and stay the same across your servers.

Without a secret, the SDK still counts each device, with a plain hash of the device id and your API key. A new API key then gives every device a new install id, so each device counts again that month. Someone who can guess a device id can then match it to its install id. The SDK logs a warning once.

## What the SDK sends

The SDK asks for licenses in the background, and a model never waits for one. It sends the devices that need a license together: when 100 wait, or 10 seconds after the first. While a request is on its way, new devices wait for the next one. When many devices wait, the SDK sends one request after another, so a device at the back of the queue waits longer. Without a key of the Server platform, each device is one request. It keeps each license in memory until it expires, so later calls for that device send nothing. The license server sets the expiry, one month after it first issued the license.

At most 10,000 devices wait at a time. Past that, the SDK leaves new devices out and logs a warning once. Those devices get their license the next time they call your server. If you see the warning, check that your server can reach the license server.

A request that fails is sent again later. The SDK logs one warning when a request fails, with the kind of failure, and again only after a request succeeded and a later one fails. The model keeps running.

Before your process exits, send what waits. One call sends what waits for every model loaded in the process, so call it on any one model. The call starts no device request after 10 seconds. A request that is already on its way can take 10 more seconds, so the call ends within about 20 seconds. It resolves `true` when nothing is left in the queue, and `false` when devices still wait. Devices that still wait, and devices the SDK left out of a full queue, get their license the next time they call your server:

```js
await emo.flushLicenses();
```

```swift
await DesertAnt.flushLicenses()
```

The device id must be text, and the license requires one with every call on a server. With a secret set, the SDK asks for no license for the server itself, so a call without a device id gets no license, and the SDK logs a warning once for such a call. Without a secret, a call without a device id counts as the server itself.

Every model follows the device id, in Swift and in JavaScript.

All of this is for servers. An app on a phone or in a browser is one device, and a `deviceId` there changes nothing.
