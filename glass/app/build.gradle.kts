plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "au.interstellr.glassbridge"
    compileSdk = 35

    defaultConfig {
        applicationId = "au.interstellr.glassbridge"
        // XE24 only ever runs API 19. targetSdk 19 keeps newer exported/foreground-service
        // rules out of the way and lets Notification.Builder / PendingIntent work as on KitKat.
        minSdk = 19
        targetSdk = 19
        versionCode = 2
        versionName = "2.0"
    }

    signingConfigs {
        // Shared debug key committed at glass/debug.keystore (CLAUDE.md owner decision 5),
        // so debug APKs built on any machine install over each other. Debug key only.
        getByName("debug") {
            storeFile = rootProject.file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        getByName("debug") {
            signingConfig = signingConfigs.getByName("debug")
        }
        getByName("release") {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        // Remaining lint errors are deliberate (targetSdk 19, mock-location permission,
        // Criteria constants). lintDebug must still show no NewApi issues.
        abortOnError = false
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // No runtime dependencies at all (AndroidX needs minSdk > 19). Android ships org.json,
    // so the JVM tests use the reference org.json in its place.
    testImplementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
}

// LiveLinkTest talks to `python3 tools/fake_phone.py --selftest --port N` when
// GLASSBRIDGE_TEST_PORT=N is set, and skips otherwise. The variable is forwarded explicitly
// (and declared as an input) so a warm Gradle daemon or an up-to-date check can't hide it.
val glassbridgeTestPort: String = providers.environmentVariable("GLASSBRIDGE_TEST_PORT").orElse("").get()
val glassbridgeTestHost: String = providers.environmentVariable("GLASSBRIDGE_TEST_HOST").orElse("127.0.0.1").get()
val glassbridgeRepoRoot: String = rootProject.projectDir.parentFile.absolutePath

tasks.withType<Test>().configureEach {
    inputs.property("glassbridgeTestPort", glassbridgeTestPort)
    inputs.property("glassbridgeTestHost", glassbridgeTestHost)
    environment("GLASSBRIDGE_TEST_PORT", glassbridgeTestPort)
    environment("GLASSBRIDGE_TEST_HOST", glassbridgeTestHost)
    systemProperty("glassbridge.testPort", glassbridgeTestPort)
    systemProperty("glassbridge.testHost", glassbridgeTestHost)
    systemProperty("glassbridge.repoRoot", glassbridgeRepoRoot)
    if (glassbridgeTestPort.isNotEmpty()) {
        // A live run must really talk to fake_phone every time, never be "up to date".
        outputs.upToDateWhen { false }
    }
    testLogging {
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showStandardStreams = false
    }
}

tasks.withType<JavaCompile>().configureEach {
    // Silence JDK 17/21's "source/target value 8 is obsolete" (Java 8 is required for Dalvik).
    options.compilerArgs.add("-Xlint:-options")
}
