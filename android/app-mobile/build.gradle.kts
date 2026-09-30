// SPDX-License-Identifier: GPL-3.0-only
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.auralis.mobile"
    compileSdk = 36

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
        applicationId = "com.auralis.mobile"
        minSdk = 26
        targetSdk = 36
        versionCode = buildVersionCode
        versionName = buildVersionName
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    /**
     * 变体职责：
     * - `debug`：开发用，保持 debuggable + 不开启 R8，便于断点与 Compose 工具；
     * - `release`：正式产物，R8 全量收缩/优化 + 资源收缩；
     * - `perf`：**交给测试者安装的性能验证产物**。它与 `release` 完全同构（非 debuggable +
     *   已 R8 优化），但用默认 debug 签名，因此 CI 无需配置正式签名即可产出可安装 APK。
     *   测试者拿到的流畅性/崩溃结论应基于该变体，而不是 `debug`。
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
            // 无正式签名时也能产出可安装 APK；不引入 applicationIdSuffix，避免测试者丢失已存服务器状态。
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
    implementation(project(":core:ai"))
    implementation(project(":feature:home"))
    implementation(project(":feature:library"))
    implementation(project(":feature:player"))
    implementation(project(":feature:search"))
    implementation(project(":feature:assistant"))
    implementation(project(":feature:settings"))
    implementation(project(":feature:server"))

    testImplementation(libs.junit)
    testImplementation(libs.truth)
}
