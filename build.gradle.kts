// Plugin versions come from gradle/libs.versions.toml, which gradle-plugin/ also
// compiles against; the subprojects and the convention plugins apply them
// without a version.
//
// The Kotlin plugin is here although only Tongue applies it: AGP 9 compiles
// Kotlin itself, with whatever Kotlin Gradle plugin is on this classpath, and
// on its own it brings an older one (2.2.10 for AGP 9.5). The subprojects
// inherit this classpath, so without this line the model AARs would build on
// AGP's compiler instead of the catalog's.
plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.maven.publish) apply false
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
