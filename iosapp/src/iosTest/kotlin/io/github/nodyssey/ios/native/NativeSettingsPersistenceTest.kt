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
    fun unimplementedWifiImageControlDoesNotPretendToSave() = runBlocking {
        val path = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / "native-settings-${Uuid.random()}.preferences_pb"
        val job = SupervisorJob()
        try {
            val repository = SettingsRepository(PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { path }))
            val error = assertFailsWith<NativeFailure> {
                settingsApply(repository, Json.parseToJsonElement("{\"key\":\"imagesOnWifiOnly\",\"value\":true}").jsonObject)
            }
            assertEquals("UNSUPPORTED_SETTING", error.code)
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
            assertFailsWith<IllegalArgumentException> {
                settingsApply(first, Json.parseToJsonElement("{\"key\":\"appLanguage\",\"value\":\"invalid\"}").jsonObject)
            }
            job.cancelAndJoin()
            job = SupervisorJob()
            val reloaded = repository().settings.first()
            assertEquals(AppLanguage.ENGLISH, reloaded.appLanguage)
            assertEquals(SettingsRepository.MAX_FONT_SCALE, reloaded.fontScale)
        } finally {
            job.cancelAndJoin()
            FileSystem.SYSTEM.delete(path, mustExist = false)
        }
    }
}
