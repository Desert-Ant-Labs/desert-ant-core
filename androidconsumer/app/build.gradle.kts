// An Android app depending on every SDK, with the README's install lines and
// nothing else: core is not listed, because apps get it through a model.
// Kotlin is AGP's built-in Kotlin, at the version the root build loads.
plugins {
    id("com.android.application")
}

val sdkVersion = rootDir.resolve("../VERSION").readText().trim()

android {
    namespace = "ai.desertant.consumer"
    compileSdk = 37

    defaultConfig {
        applicationId = "ai.desertant.consumer"
        // The README's floor. Manifest merging fails if any AAR asks for more.
        minSdk = 24
        targetSdk = 37
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        abortOnError = true
        checkAllWarnings = true
        checkTestSources = true
        warningsAsErrors = true
        error += "AutoboxingStateCreation"
        // Dependency updates are handled independently of lint.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion")
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.add("-Xwarning-level=DEPRECATION:error")
    }
}

// Every SDK, as check:android-consumer lists them (dal_models_with kotlin), so
// a new model is covered without editing this file. The check also requires a
// source file for it.
val models = providers.gradleProperty("dalConsumerModels").orNull
    ?: error("pass -PdalConsumerModels=<model,...>, or run `mise run check:android-consumer`")

dependencies {
    lintChecks(libs.androidx.compose.runtime.lint)

    models.split(',').filter { it.isNotEmpty() }
        .forEach { implementation("ai.desertant:$it:$sdkVersion") }
}
