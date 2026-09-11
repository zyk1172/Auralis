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

    val releaseVersionName = providers.gradleProperty("auralisVersionName")
        .orElse(providers.environmentVariable("GITHUB_RUN_NUMBER").map { "0.1.0-ci.$it" })
        .orElse("0.1.0")
        .get()
    val releaseVersionCode = providers.gradleProperty("auralisVersionCode")
        .orElse(providers.environmentVariable("GITHUB_RUN_NUMBER"))
        .orElse("1")
        .get()
        .toIntOrNull()
        ?.also { require(it > 0) { "auralisVersionCode must be a positive integer" } }
        ?: error("auralisVersionCode must be a positive integer")

    val releaseKeystoreFile = providers.environmentVariable("ANDROID_KEYSTORE_FILE").orNull
    val releaseKeystorePassword = providers.environmentVariable("ANDROID_KEYSTORE_PASSWORD").orNull
    val releaseKeyAlias = providers.environmentVariable("ANDROID_KEY_ALIAS").orNull
    val releaseKeyPassword = providers.environmentVariable("ANDROID_KEY_PASSWORD").orNull
    val hasReleaseSigning = listOf(
        releaseKeystoreFile,
        releaseKeystorePassword,
        releaseKeyAlias,
        releaseKeyPassword,
    ).all { !it.isNullOrBlank() }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseKeystoreFile!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    defaultConfig {
        applicationId = "com.auralis.mobile"
        minSdk = 26
        targetSdk = 36
        versionCode = releaseVersionCode
        versionName = releaseVersionName
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
    buildTypes {
        getByName("release") {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
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
