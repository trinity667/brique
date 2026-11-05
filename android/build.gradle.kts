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

subprojects {
    if (name == "camera_android_camerax") {
        pluginManager.withPlugin("com.android.library") {
            dependencies.add("implementation", "androidx.concurrent:concurrent-futures:1.3.0")
        }
    }
}

// file_picker 11.x n'applique plus le plugin Kotlin quand AGP >= 9 (il compte sur le « Kotlin intégré »).
// Or ce projet garde android.builtInKotlin=false (camera_android_camerax et share_plus appliquent
// encore kotlin-android) : sans ce bloc, ses sources Kotlin ne sont pas compilées et le build échoue
// sur « cannot find symbol FilePickerPlugin » dans GeneratedPluginRegistrant.java.
subprojects {
    if (name == "file_picker") {
        pluginManager.withPlugin("com.android.library") {
            if (!pluginManager.hasPlugin("org.jetbrains.kotlin.android")) {
                apply(plugin = "org.jetbrains.kotlin.android")
            }
            extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
    }
}

// L'analyse « lint vital » des plugins manque de mémoire sur un PC de 8 Go (OutOfMemoryError,
// build de 11 min qui échoue à la fin). Elle ne sert qu'à signaler des problèmes de code
// des bibliothèques : on la désactive pour construire l'APK.
subprojects {
    tasks.matching { it.name.contains("lintVital", ignoreCase = true) }.configureEach {
        enabled = false
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
