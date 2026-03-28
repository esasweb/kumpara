plugins {
    id("com.google.gms.google-services") version "4.4.4" apply false
}
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library") || plugins.hasPlugin("com.android.application")) {

            extensions.findByName("android")?.let { androidExt ->
                val clazz = androidExt.javaClass

                try {
                    val namespaceField = clazz.getMethod("getNamespace")
                    val namespace = namespaceField.invoke(androidExt)

                    if (namespace == null) {
                        clazz.getMethod("setNamespace", String::class.java)
                            .invoke(androidExt, project.group.toString())
                    }
                } catch (e: Exception) {
                }
            }
        }
    }
}