// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.auralis.tv"
    compileSdk = 34

    val buildVersionName = providers.gradleProperty("auralisVersionName")
        .orElse(providers.environmentVariable("GITHUB_RUN_NUMBER").map { "0.1.0-ci.$it" })
        .orElse("0.1.0")
        .get()
    val buildVersionCode = providers.gradleProperty("auralisVersionCode")
        .orElse(providers.environmentVariable("GITHUB_RUN_NUMBER"))
        .orElse("1")
        .get()
        .toIntOrNull()
        ?.also { require(it > 0) { "auralisVersionCode must be a positive integer" } }
        ?: error("auralisVersionCode must be a positive integer")

    defaultConfig {
        applicationId = "com.auralis.tv"
        minSdk = 26
        targetSdk = 34
        // CI artifacts are handed directly to physical TV testers. A monotonically increasing
        // versionCode lets Android treat the next artifact as an update instead of a reinstall.
        versionCode = buildVersionCode
        versionName = buildVersionName
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += "-opt-in=androidx.compose.ui.ExperimentalComposeUiApi"
    }
    buildFeatures { compose = true }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    /**
     * 与 `app-mobile` 保持同一套变体职责：`debug` 用于开发，`release` 为正式产物，
     * `perf` 为 CI 交付给真机 TV 测试者的「非 debuggable + 已 R8 优化」可安装产物。
     */
    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
        }
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "$rootDir/proguard-rules.pro",
            )
        }
        create("perf") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
            isDebuggable = false
        }
    }
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(project(":core:common"))
    implementation(project(":core:domain"))
    implementation(project(":core:opensubsonic"))
    implementation(project(":core:data"))
    implementation(project(":core:playback"))
    implementation(project(":core:offline"))
    implementation(project(":core:designsystem"))
    implementation(project(":core:image"))
    implementation(project(":core:lyrics"))
    implementation(project(":core:security"))
    implementation(project(":feature:home"))
    implementation(project(":feature:library"))
    implementation(project(":feature:player"))
    implementation(project(":feature:search"))
    implementation(project(":feature:assistant"))
    implementation(project(":feature:settings"))
    implementation(project(":feature:server"))
}
