allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
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

// 强制所有第三方插件子项目统一使用 compileSdk 36，
// 避免 flutter_plugin_android_lifecycle 等要求较新 API 的依赖报 AAR 元数据错误。
// 必须在子项目评估完成后覆盖（afterEvaluate），否则会被插件自带 compileSdkVersion 34 回盖；
// 但 evaluationDependsOn(":app") 会让 :app 在根项目配置期就被提前评估，
// 对已评估项目注册 afterEvaluate 会抛 "already evaluated"，故按评估状态分流。
subprojects {
    if (state.executed) {
        extensions.findByName("android")?.let { ext ->
            (ext as? com.android.build.gradle.BaseExtension)?.compileSdkVersion(36)
        }
    } else {
        afterEvaluate {
            extensions.findByName("android")?.let { ext ->
                (ext as? com.android.build.gradle.BaseExtension)?.compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
