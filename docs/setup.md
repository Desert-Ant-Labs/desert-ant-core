# SDK setup

Add a Desert Ant model to your app, with an API key from the console. The steps cover Swift, Kotlin, the web, and Node, with Emo as the example. For another model, use the package, class, and call from the model's page, such as [Redact](models/redact.md).

## API key

The models run without a key, so you can build and test first. An app in production needs an API key.

1. Sign in at [platform.desertant.com](https://platform.desertant.com) with GitHub, Hugging Face, or your email.
2. Choose an ID for your team. If your company already uses Desert Ant Labs models, ask an owner to invite you instead.
3. Click **New API key**, and choose where the key will be used: iOS or desktop, Android app, Web app, or Server.
4. Click **Create API key**, and copy the key. The console shows the full key only once.
5. For a Server key, set the app ID. Each app on a server needs its own ID, listed on your account. For the other keys, you can limit the key to one app with its bundle ID, package name, or allowed sites. That step is optional.

Create a key for each app and platform.

An app that ships the models credits Desert Ant Labs. The [attribution guide](https://license.desertant.com/attribution) shows how.

## Install

**Swift**

The Swift package requires iOS 18+ or macOS 15+, and Xcode 26. In Xcode, choose File > Add Package Dependencies, enter `https://github.com/Desert-Ant-Labs/desert-ant-core.git`, and add the `Emo` and `DesertAnt` products to your app target. In a `Package.swift`, add:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "6.0.0")
```

**Kotlin**

The Android SDK requires API 24+ and Kotlin 2.3+. The packages are on Maven Central. Add the model's package to `app/build.gradle.kts`:

```kotlin
dependencies {
    implementation("ai.desertant:emo:6.0.0")
}
```

**Web**

The browser build runs on WebAssembly with LiteRT.js:

```bash
npm i @desert-ant-labs/emo@6.0.0 @litertjs/core
```

**Node**

The `/native` build ships prebuilt for linux-x64, linux-arm64, and darwin-arm64. Voz has no `/native` build: in Node, pass `onnxruntime-node` to Voz's `load()`. Tongue has no `/native` build either: import it as `@desert-ant-labs/tongue`.

```bash
npm i @desert-ant-labs/emo@6.0.0
```

## Key setup

Each platform reads the key from a file that stays out of git, so a fresh clone builds without a key. In Kotlin, an app that uses only Tongue imports `DesertAnt` from `ai.desertant.tongue`. An app with another model sets the key once, on `ai.desertant.core.DesertAnt`, and Tongue reads it.

**Swift**

1. Create `Secrets.xcconfig` next to the `.xcodeproj`, with your key, and add `Secrets.xcconfig` to `.gitignore`:

   ```text
   DAL_API_KEY=dal_...
   ```

2. Create `Config.xcconfig` next to the `.xcodeproj`, and commit it. `#include?` skips `Secrets.xcconfig` when the file is missing.

   ```text
   DAL_API_KEY =
   #include? "Secrets.xcconfig"
   ```

3. Set `Config.xcconfig` as the configuration file of your app target. In the project's Info tab, choose `Config.xcconfig` for Debug and Release. If the target already has a configuration file, add the two lines from step 2 to that file instead.

4. Add `DAL_API_KEY` to `Info.plist`. Xcode fills in the value from the build setting, so the app can read the key at run time.

   ```xml
   <key>DAL_API_KEY</key>
   <string>$(DAL_API_KEY)</string>
   ```

   New Xcode projects have no `Info.plist` file, and Xcode drops custom `INFOPLIST_KEY_` settings. In that case, create `Info.plist` with only this key next to the `.xcodeproj`, not in the app's source folder. Then add `INFOPLIST_FILE = Info.plist` to `Config.xcconfig`, and keep `GENERATE_INFOPLIST_FILE = YES`. Xcode adds the keys it generates to the file.

5. Call `DesertAnt.configure` at launch, before the first model loads:

   ```swift
   import DesertAnt
   import SwiftUI

   @main
   struct MyApp: App {
       init() {
           if let apiKey = Bundle.main.object(forInfoDictionaryKey: "DAL_API_KEY") as? String, !apiKey.isEmpty {
               DesertAnt.configure(apiKey: apiKey)
           }
       }

       var body: some Scene {
           WindowGroup {
               ContentView()
           }
       }
   }
   ```

To run a model on a server in Swift, see [Run on a server](notes/server.md).

**Kotlin**

1. Add your key to `local.properties`. New Android projects already list `local.properties` in `.gitignore`. On CI, set the Gradle property `DAL_API_KEY` instead, for example with the `ORG_GRADLE_PROJECT_DAL_API_KEY` environment variable.

   ```text
   DAL_API_KEY=dal_...
   ```

2. Add `DAL_API_KEY` to `BuildConfig`, in `app/build.gradle.kts`. The import goes at the top of the file.

   ```kotlin
   import java.util.Properties

   val localProperties = Properties().apply {
       rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
   }
   val dalApiKey = localProperties.getProperty("DAL_API_KEY")
       ?: providers.gradleProperty("DAL_API_KEY").orNull
       ?: ""

   android {
       buildFeatures {
           buildConfig = true
       }
       defaultConfig {
           buildConfigField("String", "DAL_API_KEY", "\"$dalApiKey\"")
       }
   }
   ```

3. Call `DesertAnt.configure` in `Application.onCreate`, and register the class with `android:name` in `AndroidManifest.xml`:

   ```kotlin
   import ai.desertant.core.DesertAnt
   import android.app.Application

   class App : Application() {
       override fun onCreate() {
           super.onCreate()
           if (BuildConfig.DAL_API_KEY.isNotEmpty()) DesertAnt.configure(apiKey = BuildConfig.DAL_API_KEY)
       }
   }
   ```

**Web**

1. Add your key to `.env.local`. A browser bundle only gets variables with the bundler's public prefix. Vite uses `VITE_`. In Next.js, name the variable `NEXT_PUBLIC_DAL_API_KEY`.

   ```bash
   VITE_DAL_API_KEY=dal_...
   ```

2. Call `DesertAnt.configure` before the first model loads. In Next.js, read `process.env.NEXT_PUBLIC_DAL_API_KEY`.

   ```ts
   import { DesertAnt } from "@desert-ant-labs/emo";

   DesertAnt.configure({ apiKey: import.meta.env.VITE_DAL_API_KEY ?? "" });
   ```

**Node**

On a server, one process runs models for many end-user devices, so you also set a device id secret and pass a device id with each call.

1. Add your key and your app ID to `.env` locally, and add `.env` to `.gitignore`. For deploys, put them in your secrets manager or CI. Use a Server key, and the app ID you entered for it. Node loads the file with `node --env-file=.env`.

   ```bash
   DAL_API_KEY=dal_...
   DAL_APP_ID=...
   ```

2. Add a device id secret to `.env`. Make the secret once with `openssl rand -hex 32`, give every server the same one, and don't change it.

   ```bash
   DAL_DEVICE_ID_SECRET=...
   ```

3. Call `DesertAnt.configure` with the key and the secret, before the first model loads. Import the `/native` build in server code. Tongue has no `/native` build: import it as `@desert-ant-labs/tongue`.

   ```js
   import { DesertAnt } from "@desert-ant-labs/emo/native";

   DesertAnt.configure({
     apiKey: process.env.DAL_API_KEY ?? "",
     deviceIdSecret: process.env.DAL_DEVICE_ID_SECRET,
   });
   ```

[Run on a server](notes/server.md) explains the device id and the secret.

## Usage

**Swift**

Create one `Emo` and reuse it. The SDK downloads the model on first use.

```swift
import Emo

let emo = Emo()
let suggestions = try await emo.suggestions(for: "Pay my bills")
```

**Kotlin**

`suggestions` is a suspending function, and `use` closes the model when the block ends.

```kotlin
import ai.desertant.emo.Emo

Emo(context).use { emo ->
    val suggestions = emo.suggestions("Pay my bills")
}
```

**Web**

The SDK downloads the model on first use and caches it in the browser.

```ts
import { Emo } from "@desert-ant-labs/emo";

const emo = await Emo.load();
const suggestions = await emo.suggestions("Pay my bills");
```

**Node**

Pass the id of the end user's device with each call. A device id is any text that stays the same for one device or browser, such as a random id your app makes once and sends with each request.

```js
import { Emo } from "@desert-ant-labs/emo/native";

const emo = await Emo.load();
const suggestions = await emo.suggestions("Pay my bills", { deviceId: request.deviceId });
```
