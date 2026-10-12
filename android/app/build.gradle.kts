plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val androidSigningStoreFile = providers.environmentVariable("ANDROID_SIGNING_STORE_FILE")
val androidSigningStorePassword = providers.environmentVariable("ANDROID_SIGNING_STORE_PASSWORD")
val androidSigningKeyAlias = providers.environmentVariable("ANDROID_SIGNING_KEY_ALIAS")
val androidSigningKeyPassword = providers.environmentVariable("ANDROID_SIGNING_KEY_PASSWORD")
val hasAndroidSigningConfig = listOf(
    androidSigningStoreFile,
    androidSigningStorePassword,
    androidSigningKeyAlias,
    androidSigningKeyPassword,
).all { it.isPresent }
val woonaServerBaseUrl = providers.gradleProperty("woonaServerBaseUrl")
    .orElse("https://cool-trams.digital")
val woonaServerToken = providers.gradleProperty("woonaServerToken")
    .orElse("")
fun String.asBuildConfigString(): String = "\"${replace("\\", "\\\\").replace("\"", "\\\"")}\""

android {
    sourceSets.getByName("androidTest").assets.srcDir(rootProject.file("../shared/testdata"))
    namespace = "com.example.myapplication"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }

    defaultConfig {
        applicationId = "com.woona.drivetest"
        minSdk = 31
        targetSdk = 36
        versionCode = 10
        versionName = "1.3.7"

        buildConfigField("String", "WOONA_SERVER_BASE_URL", woonaServerBaseUrl.get().asBuildConfigString())
        buildConfigField("String", "WOONA_SERVER_TOKEN", woonaServerToken.get().asBuildConfigString())

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (hasAndroidSigningConfig) {
            create("release") {
                storeFile = file(androidSigningStoreFile.get())
                storePassword = androidSigningStorePassword.get()
                keyAlias = androidSigningKeyAlias.get()
                keyPassword = androidSigningKeyPassword.get()
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasAndroidSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    testOptions {
        managedDevices {
            localDevices {
                create("woonaApi31") {
                    device = "Pixel 2"
                    apiLevel = 31
                    systemImageSource = "google"
                    testedAbi = "x86_64"
                }
            }
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    bundle {
        language {
            enableSplit = false
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation("androidx.compose.material:material-icons-extended")


    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)

}
