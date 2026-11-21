// Local Room 2.8.5 replacement for the two iOS targets only. See UPSTREAM.md.
plugins {
    // KGP is already on the root classpath through build-logic; do not request a new version.
    id("org.jetbrains.kotlin.multiplatform")
    id("plaza.dependency-locking")
}

kotlin {
    iosArm64()
    iosSimulatorArm64()
    // Keep the upstream common expect and jvmNative actual pair; never compile a flattened
    // simulator fixture as production multi-target source.
    sourceSets {
        commonMain.dependencies {
            api(libs.androidx.room.runtime)
            api(libs.androidx.paging.common)
            implementation(libs.kotlinx.coroutines.core)
            // Original Native published edge, pinned to :shared's already selected version.
            // Room's own Native atomics are used; no atomicfu compiler plugin is introduced.
            implementation("org.jetbrains.kotlinx:atomicfu:0.32.1")
        }
        iosMain {
            kotlin.srcDir("src/jvmNativeMain/kotlin")
            dependencies {
                // Match the frozen iOS consumers; do not request Room's obsolete 1.5.0 leaf.
                implementation("androidx.collection:collection:1.6.0")
            }
        }
    }
}

// Preserve the KLIB identity referenced by generated consumers and any unchanged public IR.
// Per-target outputs remain separate; this does NOT turn a simulator klib into a device klib.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinNativeCompile>().configureEach {
    if (name in setOf("compileKotlinIosArm64", "compileKotlinIosSimulatorArm64")) {
        compilerOptions.moduleName.set("androidx.room:room-paging")
    }
}
