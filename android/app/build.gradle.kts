import java.io.FileInputStream
import java.util.Properties

val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")

if (keyPropertiesFile.isFile) {
    FileInputStream(keyPropertiesFile).use { keyProperties.load(it) }
}

fun releaseSigningProperty(name: String): String? =
    keyProperties.getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }

fun validateReleaseSigning() {
    if (!keyPropertiesFile.isFile) {
        throw GradleException(
            "Assinatura release não configurada: android/key.properties está ausente.",
        )
    }

    val requiredProperties = listOf(
        "keyAlias",
        "keyPassword",
        "storeFile",
        "storePassword",
    )
    val missingProperties = requiredProperties.filter {
        releaseSigningProperty(it) == null
    }

    if (missingProperties.isNotEmpty()) {
        throw GradleException(
            "Assinatura release não configurada: propriedades obrigatórias ausentes.",
        )
    }

    val configuredStoreFile = file(releaseSigningProperty("storeFile")!!)
    if (!configuredStoreFile.isFile) {
        throw GradleException(
            "Assinatura release não configurada: o keystore indicado não existe.",
        )
    }
}

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.firebase.crashlytics")
}

// Explicit, non-publishable Android host for local module qualification.
// Default builds retain the existing package, manifest and startup.
val localLab = providers.gradleProperty("lifeOsLocalLab").orNull == "true"

android {
    namespace = "com.rafalacerda.lifeos"
    compileSdk = 36 
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.rafalacerda.lifeos"
        if (localLab) applicationIdSuffix = ".localdev"
        minSdk = 24 
        targetSdk = 36 
        multiDexEnabled = true // Corrigido
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = releaseSigningProperty("keyAlias")
            keyPassword = releaseSigningProperty("keyPassword")
            storeFile = releaseSigningProperty("storeFile")?.let { file(it) }
            storePassword = releaseSigningProperty("storePassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
    if (localLab) {
        buildTypes.matching { it.name == "profile" }.configureEach { isDebuggable = true }
        sourceSets.getByName("debug").manifest.srcFile("src/localLab/AndroidManifest.xml")
        sourceSets.getByName("profile").manifest.srcFile("src/localLabProfile/AndroidManifest.xml")
    }
}

if (localLab) {
    androidComponents.beforeVariants(androidComponents.selector().withBuildType("release")) {
        it.enable = false
    }
    tasks.matching {
        it.name.endsWith("GoogleServices") || it.name.startsWith("uploadCrashlytics")
    }.configureEach { enabled = false }
}

tasks.matching { it.name.startsWith("compileFlutterBuild") }.configureEach {
    doFirst {
        val target = project.findProperty("target")?.toString()?.replace('\\', '/') ?: "lib/main.dart"
        val allowed = listOf("lib/main_local.dart", "integration_test/local_tasks_native_test.dart", "integration_test/local_finance_native_test.dart", "integration_test/local_habits_native_test.dart", "integration_test/local_goals_native_test.dart", "integration_test/local_checkin_native_test.dart", "integration_test/local_study_native_test.dart", "integration_test/local_focus_native_test.dart")
        val localTarget = allowed.any { target == it || target.endsWith("/$it") }
        if (localLab && !localTarget) {
            throw GradleException("Local lab requires an explicitly qualified local entrypoint.")
        }
        if (!localLab && localTarget) {
            throw GradleException("Local entrypoint requires the isolated lifeOsLocalLab package.")
        }
    }
}

tasks.matching { it.name == "validateSigningRelease" }.configureEach {
    doFirst {
        validateReleaseSigning()
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(platform("com.google.firebase:firebase-bom:34.15.0"))
    implementation("com.google.firebase:firebase-analytics")
    implementation("androidx.multidex:multidex:2.0.1") // Corrigido
}
