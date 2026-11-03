plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val media3 = "1.9.0"

// The web UI (Vite build output in ../../dist) is bundled into the APK and served to the
// WebView from https://appassets.androidplatform.net/. Run `npm run build` in the repo
// root first (the CI workflow does this).
val webDist = rootProject.file("../dist")
val webAssetsOut = layout.buildDirectory.dir("generated/webAssets")

val copyWebAssets by tasks.registering(Sync::class) {
    from(webDist)
    into(webAssetsOut.map { it.dir("www") })
    doFirst {
        if (!webDist.resolve("index.html").exists()) {
            throw GradleException("Web build not found at $webDist — run `npm run build` in the repo root first.")
        }
    }
}

android {
    namespace = "app.harbor.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.harbor.android"
        minSdk = 24
        targetSdk = 36
        versionCode = (project.findProperty("harborVersionCode") as String?)?.toInt() ?: 1
        versionName = (project.findProperty("harborVersionName") as String?) ?: "0.9.36"
    }

    signingConfigs {
        // Release key: android/keystore/harbor-release.p12 (encrypted; committed) unlocked by
        // the HARBOR_KEYSTORE_PASSWORD secret. Same key every build => updates install over
        // the previous version. Without the password the debug key is used.
        val ksPassword = System.getenv("HARBOR_KEYSTORE_PASSWORD")
        val ksFile = System.getenv("HARBOR_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }?.let { file(it) }
            ?: rootProject.file("keystore/harbor-release.p12")
        if (!ksPassword.isNullOrBlank() && ksFile.exists()) {
            create("release") {
                storeFile = ksFile
                storeType = "pkcs12"
                storePassword = ksPassword
                keyAlias = System.getenv("HARBOR_KEY_ALIAS")?.takeIf { it.isNotBlank() } ?: "harbor"
                keyPassword = System.getenv("HARBOR_KEY_PASSWORD")?.takeIf { it.isNotBlank() } ?: ksPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    sourceSets["main"].apply {
        assets.srcDir(webAssetsOut)
        // Reuse the launcher icons that already live with the Tauri project.
        res.srcDir(rootProject.file("../src-tauri/icons/android"))
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

tasks.named("preBuild") { dependsOn(copyWebAssets) }

dependencies {
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-ktx:1.11.0")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")
    implementation("androidx.media3:media3-exoplayer-dash:$media3")
    implementation("androidx.media3:media3-ui:$media3")
    // FFmpeg audio decoders (AC3, E-AC3, DTS, TrueHD, …) that most phones don't ship.
    implementation("org.jellyfin.media3:media3-ffmpeg-decoder:$media3+1")

    testImplementation("junit:junit:4.13.2")
}
