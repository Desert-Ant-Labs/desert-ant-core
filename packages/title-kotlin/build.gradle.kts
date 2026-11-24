plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device titles and descriptions for passages of text."
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    androidTestImplementation(project(":emo"))
}

abstract class PackageLiteRtLmNotices : DefaultTask() {
    @get:InputDirectory abstract val notices: DirectoryProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        notices.get().asFile.copyRecursively(
            outputDir.get().dir("META-INF/ai.desertant.title/litert-lm").asFile,
            overwrite = true,
        )
    }
}

val liteRtLmNotices = layout.projectDirectory.dir("build/litertLmNotices")
val buildNatives = tasks.named("buildSwiftNatives") {
    outputs.dir(liteRtLmNotices)
}
androidComponents.onVariants { variant ->
    val packageNotices = tasks.register<PackageLiteRtLmNotices>(
        "package${variant.name.replaceFirstChar { it.uppercase() }}LiteRtLmNotices",
    ) {
        dependsOn(buildNatives)
        notices.set(liteRtLmNotices)
    }
    variant.sources.resources?.addGeneratedSourceDirectory(packageNotices, PackageLiteRtLmNotices::outputDir)
}
