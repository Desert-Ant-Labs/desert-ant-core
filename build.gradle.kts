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
