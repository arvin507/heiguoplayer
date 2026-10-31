pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // 网络不稳时用 curl 预先下载的大包放这里（见 README），优先于远程仓库。
        maven {
            url = uri("localrepo")
            content { includeGroup("com.google.devtools.ksp") }
        }
        google()
        mavenCentral()
    }
}
rootProject.name = "HeiguoPlayer"
include(":app")
