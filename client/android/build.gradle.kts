allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker 11.0.3 (its last 11.x) applies the Kotlin Gradle plugin only when
// AGP is below 9, assuming AGP 9 always means built-in Kotlin. This project keeps
// built-in Kotlin off (see android.builtInKotlin in gradle.properties) because
// share_plus / wakelock_plus / package_info_plus / flutter_foreground_task apply
// KGP unconditionally, which built-in Kotlin refuses to coexist with. So nobody
// compiles file_picker's Kotlin sources and the release build dies on
// `cannot find symbol: com.mr.flutter.plugin.filepicker.FilePickerPlugin` from
// GeneratedPluginRegistrant.
//
// Flutter's own Gradle plugin normally covers this: with built-in Kotlin off it
// applies kotlin-android to every plugin module that does not declare KGP. But it
// decides by regex-scanning the build script text, and file_picker's apply line —
// never executed on AGP 9 — matches, so it is skipped. Applying it here is exactly
// what Flutter would have done. Remove this block when file_picker moves to 12.x,
// whose android_file_picker reads android.builtInKotlin correctly.
subprojects {
    if (name != "file_picker") return@subprojects
    pluginManager.apply("kotlin-android")
    // The plugin's own `kotlinOptions { jvmTarget }` sits in the same skipped
    // branch, and its Java target is 17 — without this the JVM-target
    // consistency check fails instead.
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
