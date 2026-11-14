package io.github.nodyssey.ios.native

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import io.github.nodyssey.data.settings.AppLanguage
import io.github.nodyssey.data.settings.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import okio.FileSystem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.uuid.Uuid

class NativeSettingsPersistenceTest {
    @Test
    fun imageCapabilitiesMatchTheNativePlatformWithoutInventingOtherSupport() {
        val capabilities = settingsCapabilities(offlineAvailable = true, networkDiagnosticsAvailable = false)
        assertEquals("true", capabilities["imagesOnWifiOnly"].toString())
        assertEquals("true", capabilities["offlineImageReading"].toString())
        assertEquals("false", capabilities["networkDiagnostics"].toString())
        assertEquals("false", capabilities["notificationPolling"].toString())
    }

    @Test
    fun wifiImageControlPersistsTheSettingConsumedByNativePlatform() = runBlocking {
        val path = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / "native-settings-${Uuid.random()}.preferences_pb"
        val job = SupervisorJob()
        try {
            val repository = SettingsRepository(PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { path }))
            settingsApply(repository, Json.parseToJsonElement("{\"key\":\"imagesOnWifiOnly\",\"value\":true}").jsonObject)
            assertEquals(true, repository.settings.first().imagesOnWifiOnly)
            settingsApply(repository, Json.parseToJsonElement("{\"key\":\"imagesOnWifiOnly\",\"value\":false}").jsonObject)
            assertEquals(false, repository.settings.first().imagesOnWifiOnly)
        } finally {
            job.cancelAndJoin()
            FileSystem.SYSTEM.delete(path, mustExist = false)
        }
    }

    @Test
    fun settingsMutationsSurviveReopeningWithoutResettingOtherFields() = runBlocking {
        val path = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / "native-settings-${Uuid.random()}.preferences_pb"
        var job: Job = SupervisorJob()
        fun repository() = SettingsRepository(PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { path }))
        try {
            val first = repository()
            settingsApply(first, Json.parseToJsonElement("{\"key\":\"appLanguage\",\"value\":\"ENGLISH\"}").jsonObject)
            settingsApply(first, Json.parseToJsonElement("{\"key\":\"fontScale\",\"value\":100}").jsonObject)
            settingsApply(first, Json.parseToJsonElement("{\"key\":\"imagesOnWifiOnly\",\"value\":true}").jsonObject)
            assertFailsWith<IllegalArgumentException> {
                settingsApply(first, Json.parseToJsonElement("{\"key\":\"appLanguage\",\"value\":\"invalid\"}").jsonObject)
            }
            job.cancelAndJoin()
            job = SupervisorJob()
            val reloaded = repository().settings.first()
            assertEquals(AppLanguage.ENGLISH, reloaded.appLanguage)
            assertEquals(SettingsRepository.MAX_FONT_SCALE, reloaded.fontScale)
            assertEquals(true, reloaded.imagesOnWifiOnly)
        } finally {
            job.cancelAndJoin()
            FileSystem.SYSTEM.delete(path, mustExist = false)
        }
    }
}
