pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Auralis"

// ---- App shells -------------------------------------------------------------
include(":app-mobile")
include(":app-tv")

// ---- Core -------------------------------------------------------------------
include(":core:common")
include(":core:domain")
include(":core:opensubsonic")
include(":core:data")
include(":core:playback")
include(":core:offline")
include(":core:designsystem")
include(":core:image")
include(":core:lyrics")
include(":core:security")
include(":core:ai")

// ---- Feature ----------------------------------------------------------------
include(":feature:home")
include(":feature:library")
include(":feature:player")
include(":feature:search")
include(":feature:assistant")
include(":feature:settings")
include(":feature:server")
