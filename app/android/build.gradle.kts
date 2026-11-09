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
    if (name == "integration_test") {
        configurations.configureEach {
            resolutionStrategy.eachDependency {
                if (requested.group == "androidx.test" && requested.name == "runner" && requested.version == "1.2+") {
                    // Keep Flutter's test plugin on the runner used by our verified builds.
                    useVersion("1.3.0")
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
