// Plugin versions are declared once for the whole build; the subprojects and the
// ai.desertant.model-sdk convention plugin apply them without a version.
plugins {
    id("com.android.library") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.1.21" apply false
    id("com.vanniktech.maven.publish") version "0.34.0" apply false
}

// Every artifact in this repo ships one version, single-sourced in VERSION, so
// no build script carries a version literal that could drift. `mise run
// set-version X.Y.Z` writes it; `mise run check:version` proves the formats that
// cannot read a file (package.json, Catalog.swift) still agree.
allprojects {
    group = "ai.desertant"
    version = rootDir.resolve("VERSION").readText().trim()
}

// The NDK is single-sourced the same way, in ANDROID_NDK_VERSION, which the
// mise tasks also build the Swift natives with (dal_android_ndk_version). AGP
// compiles nothing native here, but it strips every packaged .so with this
// NDK's llvm-strip; unset, it falls back to its own default NDK.
val androidNdkVersion = rootDir.resolve("ANDROID_NDK_VERSION").readText().trim()
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension> { ndkVersion = androidNdkVersion }
    }
}
