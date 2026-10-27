package com.example.myapplication

import android.Manifest
import android.os.Bundle
import android.os.CancellationSignal
import android.util.Log
import android.view.Surface
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.work.WorkManager
import com.example.myapplication.ble.BleTransportProfilePreferences
import com.example.myapplication.data.DogProfile
import com.example.myapplication.data.Recording
import com.example.myapplication.data.RecordingSource
import com.example.myapplication.data.profileSyncRecord
import com.example.myapplication.data.normalizeAccountId
import com.example.myapplication.data.acceptServerRecording
import com.example.myapplication.data.SessionQuestionnaire
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.data.artifactDownloadTarget
import com.example.myapplication.data.markArtifactDownloaded
import com.example.myapplication.data.remoteArtifacts
import com.example.myapplication.data.resetFailedSync
import com.example.myapplication.data.restoreServerMetadata
import com.example.myapplication.data.applyServerDeletions
import com.example.myapplication.data.retryRetirementCleanup
import com.example.myapplication.data.retirementCleanupStatus
import com.example.myapplication.data.serverSyncCounts
import com.example.myapplication.data.sessionQuestionnaireFromJson
import com.example.myapplication.data.removeLocalRecordingFiles
import com.example.myapplication.localization.recordingUploadErrorText
import com.example.myapplication.data.toJson
import com.example.myapplication.feature.device.DeviceFeatureController
import com.example.myapplication.feature.device.VideoCaptureState
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppLanguagePreferences
import com.example.myapplication.localization.AppLocalizationEntryPoint
import com.example.myapplication.localization.AppTextResolver
import com.example.myapplication.profile.DogQuestionnaireDialog
import com.example.myapplication.profile.ProfilesOverview
import com.example.myapplication.profile.SessionQuestionnaireDialog
import com.example.myapplication.profile.HeartQuestionnaireDialog
import com.example.myapplication.profile.ReferenceAttachmentDialog
import com.example.myapplication.data.heartQuestionnaireDraft
import com.example.myapplication.sync.serverOperationLock
import com.example.myapplication.sync.sameRetirementServer
import kotlin.concurrent.withLock
import com.example.myapplication.sync.ServerSettingsDialog
import com.example.myapplication.sync.ServerSettingsStore
import com.example.myapplication.sync.ServerApiClient
import com.example.myapplication.sync.ServerSyncScheduler
import com.example.myapplication.sync.ServerSyncStatus
import com.example.myapplication.sync.ServerSyncUiState
import com.example.myapplication.ui.theme.AppThemeEntryPoint
import com.example.myapplication.ui.theme.AppThemeMode
import com.example.myapplication.ui.theme.AppThemePreferences
import com.example.myapplication.ui.theme.applyAppThemeMode
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val serviceUuid = UUID.fromString("0000fff0-0000-1000-8000-00805f9b34fb")
    private val characteristicUuid = UUID.fromString("0000fff1-0000-1000-8000-00805f9b34fb")
    private val descriptorUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private val blePermissions = arrayOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT,
    )

    private val appLanguagePreferences by lazy { AppLanguagePreferences(applicationContext) }
    private val appThemePreferences by lazy { AppThemePreferences(applicationContext) }
    private val transportPreferences by lazy { BleTransportProfilePreferences(applicationContext) }
    private val serverSettingsStore by lazy { ServerSettingsStore(applicationContext) }
    private val woonaDatabase by lazy { WoonaDatabase(applicationContext) }
    private val profilePreferences by lazy {
        getSharedPreferences(PROFILE_PREFERENCES_NAME, MODE_PRIVATE)
    }
    private val appTextResolver by lazy {
        AppTextResolver(applicationContext) { selectedLanguage }
    }
    private val backgroundExecutor: ExecutorService by lazy {
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "main-activity-io").apply { priority = Thread.NORM_PRIORITY }
        }
    }

    private var selectedLanguage by mutableStateOf(AppLanguage.ENGLISH)
    private var selectedThemeMode by mutableStateOf(AppThemeMode.SYSTEM)
    private var dogProfiles by mutableStateOf<List<DogProfile>>(emptyList())
    private var selectedProfileId by mutableStateOf<String?>(null)
    private var recentRecordings by mutableStateOf<List<Recording>>(emptyList())
    private var showingAllRecordings by mutableStateOf(false)
    private var localHistorySummary by mutableStateOf("")
    private var serverRecordingReports by mutableStateOf<Map<String, Pair<String?, Boolean>>>(emptyMap())
    private var serverSyncState by mutableStateOf(ServerSyncUiState())
    private var connectionCheck = com.example.myapplication.sync.ConnectionCheck.NOT_CHECKED
    private var checkedConfiguration: com.example.myapplication.sync.ServerSettings? = null
    private var reportConfiguration: com.example.myapplication.sync.ServerSettings? = null
    private var connectionCheckedAt: String? = null
    private var connectionCheckError: String? = null
    private var workersRunning = 0
    private var workersQueued = 0
    private var retirementChecking = false
    private var retirementNetworkError: String? = null
    private var isServerRestoreInProgress = false
    private var isServerSettingsVisible by mutableStateOf(false)
    private var isDogQuestionnaireVisible by mutableStateOf(false)
    private var editingProfile by mutableStateOf<DogProfile?>(null)
    private var isSessionQuestionnaireVisible by mutableStateOf(false)
    private var editingRecording by mutableStateOf<com.example.myapplication.data.Recording?>(null)
    private var startupReady by mutableStateOf(false)
    private var startupRecoveryRunning by mutableStateOf(false)
    private var startupRecoveryError by mutableStateOf<String?>(null)
    private var startupSavedState: Bundle? = null
    private var accountBusy by mutableStateOf(false)
    private var heartQuestionnaireRecordingId by mutableStateOf<String?>(null)
    private var referenceRecordingId: String? = null
    private var referenceUri by mutableStateOf<android.net.Uri?>(null)

    private val referencePicker = registerForActivityResult(ActivityResultContracts.GetContent()) { uri -> referenceUri = uri }
    private var pendingLiveAddress: String? = null
    private var pendingReplayQuestionnaire: SessionQuestionnaire? = null
    private var sessionPreparationError by mutableStateOf<String?>(null)
    private var isChartFullscreenActive = false
    private var isStopSessionInProgress = false
    private var isCameraPermissionRequestInProgress = false
    private var startCaptureAfterCameraPermission = false
    private var startPolarScanAfterPermission = false
    private var pendingPreviewSurface: Surface? = null

    private val requestPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { permissions ->
        val granted = permissions.values.all { it }
        if (granted && startPolarScanAfterPermission) {
            deviceFeatureController.onPolarScanRequested()
        } else {
            deviceFeatureController.onPermissionsResult(granted)
        }
        startPolarScanAfterPermission = false
        if (!granted) toast(
            if (selectedLanguage == AppLanguage.RUSSIAN) {
                "Нужны разрешения Bluetooth"
            } else {
                "Bluetooth permissions are required"
            },
        )
    }

    private val requestCameraPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        isCameraPermissionRequestInProgress = false
        if (granted) {
            deviceFeatureController.setVideoPreviewSurface(pendingPreviewSurface)
            if (startCaptureAfterCameraPermission) {
                startCaptureAfterCameraPermission = false
                deviceFeatureController.startSynchronizedSession()
            }
        } else {
            startCaptureAfterCameraPermission = false
            deviceFeatureController.onVideoPermissionDenied()
        }
    }

    private val replayFilePickerLauncher = registerForActivityResult(
        ActivityResultContracts.GetContent(),
    ) { uri ->
        if (uri == null) {
            sessionPreparationError = if (selectedLanguage == AppLanguage.RUSSIAN) "Файл не выбран. Черновик сохранён в этом окне; повторите выбор или отмените." else "No file was selected. Your draft remains in this window; select a file again or cancel."
            return@registerForActivityResult
        }
        if (!startupReady || accountBusy || selectedProfileId == null) {
            sessionPreparationError = if (selectedLanguage == AppLanguage.RUSSIAN) "Не удалось начать воспроизведение: дождитесь операции аккаунта и выберите животное. Черновик остаётся открытым." else "Cannot start replay: wait for the account operation and select an animal. Your draft remains open."
            return@registerForActivityResult
        }
        val profileId = requireNotNull(selectedProfileId)
        val questionnaire = pendingReplayQuestionnaire ?: return@registerForActivityResult
        val recording = runCatching {
            woonaDatabase.beginRecording(
                profileId = profileId,
                source = RecordingSource.REPLAY,
                questionnaire = questionnaire,
            )
        }.getOrElse {
            Log.e(TAG, "Failed to prepare replay recording", it)
            sessionPreparationError = (if (selectedLanguage == AppLanguage.RUSSIAN) "Не удалось сохранить анкету и создать воспроизведение. Черновик остаётся открытым; повторите выбор файла." else "Failed to save the questionnaire and create replay. Your draft remains open; select the file again.") + "\n" + it.toString()
            isSessionQuestionnaireVisible = true
            return@registerForActivityResult
        }
        deviceFeatureController.beginRecordingSession(recording)
        deviceFeatureController.startReplay { cancellationToken ->
            val cancellationSignal = CancellationSignal()
            cancellationToken.invokeOnCancellation(cancellationSignal::cancel)
            val descriptor = contentResolver.openAssetFileDescriptor(uri, "r", cancellationSignal)
                ?: return@startReplay null
            try {
                descriptor.createInputStream()
            } catch (error: Exception) {
                descriptor.close()
                throw error
            }
        }
        pendingReplayQuestionnaire = null
        sessionPreparationError = null
        isSessionQuestionnaireVisible = false
    }

    private val deviceFeatureController: DeviceFeatureController by lazy {
        DeviceFeatureControllerHolder.obtain(
            onRecordingChanged = ::handleRecordingChanged,
        ) {
            DeviceFeatureModuleEntryPoint.create(
                context = applicationContext,
                filesDir = filesDir,
                fileProviderAuthority = "$packageName.provider",
                serviceUuid = serviceUuid,
                characteristicUuid = characteristicUuid,
                descriptorUuid = descriptorUuid,
                initialTransportProfile = transportPreferences.selectedTransportProfile(),
                appTextResolver = appTextResolver,
                woonaDatabase = woonaDatabase,
                snapshotDirectory = File(cacheDir, "woona_export_snapshots"),
                onRecordingChanged = ::handleRecordingChanged,
                onCaptureLifecycleChanged = { active ->
                    if (active) {
                        CaptureForegroundService.start(applicationContext)
                    } else {
                        CaptureForegroundService.stop(applicationContext)
                    }
                },
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        selectedLanguage = appLanguagePreferences.selectedLanguage()
        selectedThemeMode = appThemePreferences.selectedThemeMode()
        applyAppThemeMode(this, selectedThemeMode)
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        CaptureServiceBridge.onStopRequested = {
            DeviceFeatureControllerHolder.requestStop()
        }
        enableEdgeToEdge()
        setContent {
            AppLocalizationEntryPoint.Provide(
                language = selectedLanguage,
                textResolver = appTextResolver,
            ) {
                if (!startupReady) {
                    AppThemeEntryPoint.Render(themeMode = selectedThemeMode) {
                        com.example.myapplication.storage.StartupRecoveryScreen(selectedLanguage, startupRecoveryRunning, startupRecoveryError) { beginStartupRecovery() }
                    }
                } else {
                val uiState = deviceFeatureController.uiState
                AppThemeEntryPoint.Render(themeMode = selectedThemeMode) {
                    val serverMutationBlock = serverMutationBlockReason(serverSyncState.uploading)
                    AppShellEntryPoint.Render(
                        uiState = uiState,
                        selectedLanguage = selectedLanguage,
                        selectedThemeMode = selectedThemeMode,
                        serverSyncState = serverSyncState.copy(mutationsAllowed = serverMutationBlock == null, mutationBlockReason = serverMutationBlock,
                            connectionEditorAllowed = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && !com.example.myapplication.data.isCompleteArchiveExporting,
                            networkPolicyAllowed = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && serverSyncState.workersRunning == 0),
                        onStartScan = {
                            if (accountBusy || isServerRestoreInProgress) {
                                deviceFeatureController.showErrorOnMainThread(if (selectedLanguage == AppLanguage.RUSSIAN) "Дождитесь завершения операции с аккаунтом или восстановления" else "Wait for the account or restore operation to finish", null)
                            } else if (selectedProfileId == null) {
                                editingProfile = null
                                isDogQuestionnaireVisible = true
                            } else {
                                deviceFeatureController.onStartScanRequested(
                                    hasPermissions = ::hasBlePermissions,
                                    requestPermissions = { requestPermissionLauncher.launch(blePermissions) },
                                )
                            }
                        },
                        onConnect = { address ->
                            if (!accountBusy && !isServerRestoreInProgress) {
                                pendingLiveAddress = address
                                isSessionQuestionnaireVisible = true
                            }
                        },
                        onTransportProfileSelect = { profile ->
                            transportPreferences.setSelectedTransportProfile(profile)
                            deviceFeatureController.onTransportProfileSelected(profile)
                        },
                        onLanguageSelect = {
                            appLanguagePreferences.setSelectedLanguage(it)
                            selectedLanguage = it
                        },
                        onThemeModeSelect = {
                            appThemePreferences.setSelectedThemeMode(it)
                            selectedThemeMode = it
                            applyAppThemeMode(this, it)
                        },
                        onServerConfigure = {
                            if (!accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && !com.example.myapplication.data.isCompleteArchiveExporting) isServerSettingsVisible = true
                        },
                        onServerWifiOnlyChange = {
                            if (!accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && serverSyncState.workersRunning == 0) {
                                serverSettingsStore.setWifiOnly(it)
                                refreshServerState()
                                ServerSyncScheduler.refreshPendingNetworkPolicy(applicationContext) { failure ->
                                    if (failure != null) deviceFeatureController.showErrorOnMainThread("Network policy could not be applied; original recordings and confirmed upload progress are preserved", failure)
                                    runOnUiThread { refreshServerState() }
                                }
                            }
                        },
                        onServerRetryPending = retryPending@{
                            if (accountBusy || isServerRestoreInProgress || deviceFeatureController.isCaptureActive() || woonaDatabase.serverSyncCounts().uploading > 0) return@retryPending
                            woonaDatabase.resetFailedSync()
                            ServerSyncScheduler.enqueuePending(applicationContext)
                            refreshServerState()
                        },
                        onServerRestore = ::restoreServerData,
                        onServerCheck = ::checkServerConnection,
                        onDisconnect = ::stopSession,
                        onV2Discovery = deviceFeatureController::onV2DiscoveryRequested,
                        onV2PreviewConnect = ::connectV2Preview,
                        onV2PreviewScan = {
                            if (!accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive()) {
                                deviceFeatureController.onStartScanRequested(
                                    hasPermissions = ::hasBlePermissions,
                                    requestPermissions = { requestPermissionLauncher.launch(blePermissions) },
                                )
                            }
                        },
                        onV2StreamToggle = deviceFeatureController::onV2StreamToggled,
                        onV2LiveStart = deviceFeatureController::onV2LiveStartRequested,
                        onV2LiveStop = deviceFeatureController::onV2LiveStopRequested,
                        onSensorSelect = deviceFeatureController::onSensorSelected,
                        onChannelSelect = deviceFeatureController::onChannelSelected,
                        onChartWindowSelect = deviceFeatureController::onChartWindowSelected,
                        onFollowLiveChange = deviceFeatureController::onFollowLiveChanged,
                        onChartPanLeft = deviceFeatureController::onChartPanLeftRequested,
                        onChartPanRight = deviceFeatureController::onChartPanRightRequested,
                        onChartZoomIn = deviceFeatureController::onChartZoomInRequested,
                        onChartZoomOut = deviceFeatureController::onChartZoomOutRequested,
                        onChartZoomReset = deviceFeatureController::onChartZoomResetRequested,
                        onChartPanGesture = deviceFeatureController::onChartPanned,
                        onChartZoomGesture = deviceFeatureController::onChartZoomChanged,
                        onChartFullscreenChange = ::setChartFullscreenActive,
                        canShareAllFiles = deviceFeatureController.canShareAllFiles(),
                        canSharePacketFile = deviceFeatureController.canSharePacketFile(),
                        canShareCsvFile = deviceFeatureController.canShareCsvFile(),
                        canShareRawFile = deviceFeatureController.canShareRawFile(),
                        canShareLogFile = deviceFeatureController.canShareLogFile(),
                        onShareAllFiles = {
                            prepareShareIntentAsync {
                                deviceFeatureController.createAllFilesShareIntent(this)
                            }
                        },
                        onSharePacketFile = {
                            prepareShareIntentAsync {
                                deviceFeatureController.createPacketShareIntent(this)
                            }
                        },
                        onShareCsvFile = {
                            prepareShareIntentAsync {
                                deviceFeatureController.createCsvShareIntent(this)
                            }
                        },
                        onShareRawFile = {
                            prepareShareIntentAsync {
                                deviceFeatureController.createRawShareIntent(this)
                            }
                        },
                        onShareLogFile = {
                            prepareShareIntentAsync {
                                deviceFeatureController.createLogShareIntent(this)
                            }
                        },
                        showReplayAction = true,
                        onReplayRequest = {
                            if (deviceFeatureController.uiState.isReplayPreparing) {
                                deviceFeatureController.cancelReplayPreparation()
                            } else {
                                pendingLiveAddress = null
                                pendingReplayQuestionnaire = null
                                isSessionQuestionnaireVisible = true
                            }
                        },
                        overviewProfileContent = { section ->
                            if (section == com.example.myapplication.profile.ProfileScreenSection.ANIMALS) {
                            AccountControls(
                                accountId = serverSettingsStore.get().accountId,
                                language = selectedLanguage,
                                enabled = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && serverSyncState.uploading == 0,
                                unassigned = woonaDatabase.profiles().filter { it.accountId == null },
                                onApply = ::applyAccount, onLink = ::linkDogAccount, localHistorySummary = localHistorySummary,
                            )
                            }
                            ProfilesOverview(
                                showingAllRecordings = showingAllRecordings,
                                onShowAllRecordings = { showingAllRecordings = true; refreshProfilesAndRecordings() },
                                serverReports = serverRecordingReports,
                                onCheckServerRecording = ::checkRecordingOnServer,
                                section = section,
                                canSelectProfile = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive(),
                                profiles = dogProfiles,
                                selectedProfileId = selectedProfileId,
                                recordings = recentRecordings,
                                language = selectedLanguage,
                                onSelectProfile = ::selectProfile,
                                onCreateProfile = {
                                    editingProfile = null
                                    isDogQuestionnaireVisible = true
                                },
                                onEditProfile = {
                                    editingProfile = it
                                    isDogQuestionnaireVisible = true
                                },
                                onShareRecording = { recordingId ->
                                    prepareShareIntentAsync {
                                        deviceFeatureController.createRecordingShareIntent(
                                            this,
                                            recordingId,
                                        )
                                    }
                                },
                                onDownloadRecording = ::downloadRecording,
                                onRemoveLocalRecording = ::removeLocalRecordingFiles,
                                localRemovalEnabled = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive(),
                                videoState = uiState.videoState,
                                videoOffsetMillis = uiState.videoOffsetMillis,
                                onVideoAction = ::toggleCapture,
                                showVideoPreview = deviceFeatureController.isVideoRequested(),
                                onPreviewSurface = ::onPreviewSurfaceChanged,
                                connectionQuality = uiState.connectionQuality,
                                packetsLost = uiState.packetsLost,
                                polarStatus = uiState.polarStatus,
                                polarDevices = uiState.polarDevices,
                                onPolarScan = {
                                    if (hasBlePermissions()) {
                                        deviceFeatureController.onPolarScanRequested()
                                    } else {
                                        startPolarScanAfterPermission = true
                                        requestPermissionLauncher.launch(blePermissions)
                                    }
                                },
                                onPolarConnect = { device ->
                                    deviceFeatureController.onPolarConnectRequested(device.address, device.name)
                                },
                                onPolarDisconnect = deviceFeatureController::onPolarDisconnectRequested,
                                onHeartQuestionnaire = { editingRecording = woonaDatabase.recording(it); heartQuestionnaireRecordingId = it },
                                onEditQuestionnaire = { recording ->
                                    editingRecording = recording
                                    if (recording.questionnaire?.sessionKind == "heart") heartQuestionnaireRecordingId = recording.id
                                },
                                onAddReference = { referenceRecordingId = it; referencePicker.launch("*/*") },
                            )
                        },
                    )
                    if (isDogQuestionnaireVisible) {
                        DogQuestionnaireDialog(
                            initial = editingProfile?.questionnaire,
                            required = false,
                            language = selectedLanguage,
                            onDismiss = {
                                editingProfile = null
                                isDogQuestionnaireVisible = false
                            },
                            onSave = { questionnaire ->
                                val saved = runCatching { woonaDatabase.saveProfile(
                                    questionnaire = questionnaire,
                                    profileId = editingProfile?.id,
                                    accountId = serverSettingsStore.get().accountId,
                                ) }.getOrElse { error ->
                                    throw IllegalStateException(if (selectedLanguage == AppLanguage.RUSSIAN)
                                        "Анкета не сохранена на устройстве. Черновик остаётся открытым; устраните причину и повторите сохранение.\n${error.message ?: error.javaClass.simpleName}"
                                        else "The questionnaire was not saved on this device. Your draft remains open; correct the cause and retry.\n${error.message ?: error.javaClass.simpleName}", error)
                                }
                                editingProfile = null
                                isDogQuestionnaireVisible = false
                                refreshProfilesAndRecordings(saved.id)
                                ServerSyncScheduler.enqueueProfile(
                                    applicationContext,
                                    saved.profileVersionId,
                                )
                                refreshServerState()
                            },
                        )
                    }
                    if (isSessionQuestionnaireVisible) {
                        SessionQuestionnaireDialog(
                            language = selectedLanguage,
                            externalError = sessionPreparationError,
                            onDismiss = {
                                pendingLiveAddress = null
                                pendingReplayQuestionnaire = null; sessionPreparationError = null
                                isSessionQuestionnaireVisible = false
                            },
                            onSave = { questionnaire ->
                                sessionPreparationError = null
                                val address = pendingLiveAddress
                                if (address == null) {
                                    pendingReplayQuestionnaire = questionnaire
                                    replayFilePickerLauncher.launch("*/*")
                                } else {
                                    startLiveRecording(address, questionnaire)
                                    pendingLiveAddress = null
                                    isSessionQuestionnaireVisible = false
                                }
                            },
                        )
                    }
                    heartQuestionnaireRecordingId?.let { id ->
                        androidx.compose.runtime.key("heart", id) {
                            HeartQuestionnaireDialog(
                                language = selectedLanguage,
                                initial = editingRecording?.questionnaire?.heartQuestionnaire ?: woonaDatabase.heartQuestionnaireDraft(id),
                                onDismiss = { heartQuestionnaireRecordingId = null; editingRecording = null },
                                onSave = {},
                                onSaveAtRevision = { heart, revision ->
                                    val displayed = requireNotNull(editingRecording ?: woonaDatabase.recording(id)) { "Исходная запись больше недоступна / Original recording is unavailable" }
                                    val original = requireNotNull(displayed.questionnaire) { "Исходная анкета отсутствует / Original questionnaire is missing" }
                                    saveEditedQuestionnaire(displayed, original.copy(heartQuestionnaire = heart), revision, heartOnly = true)
                                },
                            )
                        }
                    }
                    editingRecording?.takeIf { it.questionnaire?.sessionKind != "heart" }?.let { recording ->
                        androidx.compose.runtime.key("session", recording.id) {
                            SessionQuestionnaireDialog(language = selectedLanguage, initial = recording.questionnaire,
                                onDismiss = { editingRecording = null },
                                onSave = {}, onSaveAtRevision = { answers, revision -> saveEditedQuestionnaire(recording, answers, revision) })
                        }
                    }
                    referenceUri?.let { uri ->
                        androidx.compose.runtime.key("reference", referenceRecordingId, uri) {
                            val name = runCatching { contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                                if (it.moveToFirst()) it.getString(0) else null
                            } }.getOrNull() ?: "data.bin"
                            ReferenceAttachmentDialog(selectedLanguage, name,
                                onDismiss = { referenceUri = null; referenceRecordingId = null },
                                onSave = { type, metadata ->
                                    val id = requireNotNull(referenceRecordingId)
                                    check(!accountBusy && !deviceFeatureController.isCaptureActive()) { "Дождитесь завершения записи/операции аккаунта / Wait for capture/account operation" }
                                    accountBusy = true
                                    try {
                                        withContext(Dispatchers.IO) { serverOperationLock.withLock {
                                            val recording = requireNotNull(woonaDatabase.recording(id))
                                            check(recording.serverSyncState != "uploading") { "Дождитесь завершения выгрузки / Wait for upload completion" }
                                            check(woonaDatabase.profile(recording.profileId)?.accountId == serverSettingsStore.get().accountId) { "Аккаунт записи изменился / The recording account changed" }
                                            woonaDatabase.attachReference(id, type, name, requireNotNull(contentResolver.openInputStream(uri)), metadata)
                                        } }
                                        referenceUri = null; referenceRecordingId = null
                                        handleRecordingChanged()
                                    } finally { accountBusy = false; refreshServerState() }
                                },
                            )
                        }
                    }
                    if (isServerSettingsVisible) {
                        ServerSettingsDialog(
                            current = serverSettingsStore.get(),
                            language = selectedLanguage,
                            onDismiss = { isServerSettingsVisible = false },
                            onDisconnect = ::disconnectServer,
                            canSave = serverSyncState.mutationsAllowed,
                            canDisconnect = serverSyncState.connectionEditorAllowed,
                            onSave = { url, token ->
                                if (accountBusy || isServerRestoreInProgress || deviceFeatureController.isCaptureActive() || woonaDatabase.serverSyncCounts().uploading > 0) {
                                    toast("Дождитесь завершения записи и синхронизации"); return@ServerSettingsDialog
                                }
                                if (!serverOperationLock.tryLock()) { toast("Дождитесь завершения синхронизации"); return@ServerSettingsDialog }
                                try {
                                serverSettingsStore.save(
                                    baseUrl = url,
                                    token = token,
                                    wifiOnly = serverSettingsStore.get().wifiOnly,
                                )
                                } finally { serverOperationLock.unlock() }
                                isServerSettingsVisible = false
                                woonaDatabase.resetFailedSync()
                                refreshServerState()
                                ServerSyncScheduler.enqueuePending(applicationContext)
                            },
                        )
                    }
                }
                }
            }
        }
        startupSavedState = savedInstanceState
        beginStartupRecovery()
    }

    private fun beginStartupRecovery() {
        if (startupRecoveryRunning || startupReady) return
        startupRecoveryRunning = true
        startupRecoveryError = null
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    serverOperationLock.withLock {
                        if (!CaptureServiceBridge.isRunning && !DeviceFeatureControllerHolder.hasActiveCapture()) {
                            WoonaDatabase(applicationContext).use { it.interruptUnfinished(); it.applyServerDeletions(emptyList()) }
                        }
                    }
                }
                refreshProfilesAndRecordings()
                restoreStartupUiState(startupSavedState)
                startupSavedState = null
                startupReady = true
                refreshServerState()
                observeServerWork()
                ServerSyncScheduler.refreshPendingNetworkPolicy(applicationContext) { failure ->
                    if (failure != null) runOnUiThread { deviceFeatureController.showErrorOnMainThread("Network policy reconciliation failed; original recordings and upload progress are preserved", failure) }
                }
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (error: Exception) { startupReady = false; startupRecoveryError = error.message ?: error.javaClass.simpleName }
            finally { startupRecoveryRunning = false }
        }
    }

    private fun restoreStartupUiState(savedInstanceState: Bundle?) {
        savedInstanceState?.let { state ->
            editingProfile = state.getString(STATE_EDITING_PROFILE_ID)
                ?.let { id -> dogProfiles.firstOrNull { it.id == id } }
            isDogQuestionnaireVisible =
                state.getBoolean(STATE_DOG_QUESTIONNAIRE_VISIBLE) || dogProfiles.isEmpty()
            isSessionQuestionnaireVisible =
                state.getBoolean(STATE_SESSION_QUESTIONNAIRE_VISIBLE)
            isServerSettingsVisible = state.getBoolean(STATE_SERVER_SETTINGS_VISIBLE)
            pendingLiveAddress = state.getString(STATE_PENDING_LIVE_ADDRESS)
            pendingReplayQuestionnaire = state.getString(STATE_PENDING_REPLAY_QUESTIONNAIRE)
                ?.let { json -> runCatching { sessionQuestionnaireFromJson(json) }.getOrNull() }
            sessionPreparationError = state.getString(STATE_SESSION_PREPARATION_ERROR)
            editingRecording = state.getString(STATE_EDITING_RECORDING_ID)?.let { woonaDatabase.recording(it) }?.let { current ->
                current.copy(
                    questionnaire = state.getString(STATE_EDITING_RECORDING_QUESTIONNAIRE)?.let { json ->
                        runCatching { sessionQuestionnaireFromJson(json) }.getOrNull()
                    } ?: current.questionnaire,
                    // Keep the revision the operator actually opened. A newer DB
                    // copy must produce a reviewable 409, never a silent rebase.
                    questionnaireRevision = state.getInt(STATE_EDITING_RECORDING_REVISION, current.questionnaireRevision),
                )
            }
            heartQuestionnaireRecordingId = state.getString(STATE_HEART_RECORDING_ID)
                ?.takeIf { woonaDatabase.recording(it) != null }
            referenceRecordingId = state.getString(STATE_REFERENCE_RECORDING_ID)
                ?.takeIf { woonaDatabase.recording(it) != null }
            referenceUri = state.getString(STATE_REFERENCE_URI)?.takeIf { referenceRecordingId != null }?.let(android.net.Uri::parse)
        }
    }

    override fun onPause() {
        super.onPause()
        // An Activity losing focus is not a capture stop. The foreground
        // service and the explicit Stop action own the recording lifecycle.
    }

    override fun onSaveInstanceState(outState: Bundle) {
        if (!startupReady) {
            startupSavedState?.let(outState::putAll)
            super.onSaveInstanceState(outState)
            return
        }
        outState.putBoolean(STATE_DOG_QUESTIONNAIRE_VISIBLE, isDogQuestionnaireVisible)
        outState.putString(STATE_EDITING_PROFILE_ID, editingProfile?.id)
        outState.putBoolean(STATE_SESSION_QUESTIONNAIRE_VISIBLE, isSessionQuestionnaireVisible)
        outState.putString(STATE_PENDING_LIVE_ADDRESS, pendingLiveAddress)
        outState.putString(
            STATE_PENDING_REPLAY_QUESTIONNAIRE,
            pendingReplayQuestionnaire?.toJson(),
        )
        outState.putString(STATE_SESSION_PREPARATION_ERROR, sessionPreparationError)
        outState.putString(STATE_EDITING_RECORDING_ID, editingRecording?.id)
        outState.putString(STATE_EDITING_RECORDING_QUESTIONNAIRE, editingRecording?.questionnaire?.toJson())
        editingRecording?.let { outState.putInt(STATE_EDITING_RECORDING_REVISION, it.questionnaireRevision) }
        outState.putString(STATE_HEART_RECORDING_ID, heartQuestionnaireRecordingId)
        outState.putString(STATE_REFERENCE_RECORDING_ID, referenceRecordingId)
        outState.putString(STATE_REFERENCE_URI, referenceUri?.toString())
        outState.putBoolean(STATE_SERVER_SETTINGS_VISIBLE, isServerSettingsVisible)
        super.onSaveInstanceState(outState)
    }

    override fun onResume() {
        super.onResume()
        if (startupReady) refreshServerState()
    }

    override fun onDestroy() {
        setChartFullscreenActive(false)
        if (startupReady && !deviceFeatureController.isCaptureActive()) {
            DeviceFeatureControllerHolder.releaseIfInactive(deviceFeatureController)
            CaptureServiceBridge.onStopRequested = null
            woonaDatabase.close()
        }
        backgroundExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun toggleCapture() {
        check(startupReady) { "Дождитесь восстановления локальных файлов / Wait for local file recovery" }
        val state = deviceFeatureController.uiState
        if (state.v2DiscoveryRequested) {
            deviceFeatureController.showErrorOnMainThread(getString(R.string.v2_ordinary_recording_unavailable))
            return
        }
        when (state.videoState) {
            VideoCaptureState.STARTING,
            VideoCaptureState.RECORDING,
            VideoCaptureState.DEGRADED,
            -> stopSession()

            VideoCaptureState.READY,
            VideoCaptureState.FAILED,
            -> {
                if (!deviceFeatureController.isVideoRequested()) {
                    deviceFeatureController.startSynchronizedSession()
                } else if (
                    ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                ) {
                    deviceFeatureController.startSynchronizedSession()
                } else {
                    startCaptureAfterCameraPermission = true
                    isCameraPermissionRequestInProgress = true
                    requestCameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                }
            }

            else -> Unit
        }
    }

    private fun stopSession() {
        if (isStopSessionInProgress) return
        isStopSessionInProgress = true
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    deviceFeatureController.onDisconnectRequested()
                    serverOperationLock.withLock { woonaDatabase.applyServerDeletions(emptyList()) }
                }
                ServerSyncScheduler.enqueuePending(applicationContext)
                refreshProfilesAndRecordings()
                refreshServerState()
            } finally {
                isStopSessionInProgress = false
            }
        }
    }

    private fun onPreviewSurfaceChanged(surface: Surface?) {
        pendingPreviewSurface = surface
        if (
            surface != null &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            deviceFeatureController.setVideoPreviewSurface(surface)
        } else if (surface == null) {
            deviceFeatureController.setVideoPreviewSurface(null)
        }
    }

    private fun connectV2Preview(address: String) {
        if (!startupReady || accountBusy || isServerRestoreInProgress || deviceFeatureController.isCaptureActive()) return
        pendingLiveAddress = null
        isSessionQuestionnaireVisible = false
        deviceFeatureController.onV2PreviewConnectRequested(address)
    }

    private fun startLiveRecording(address: String, questionnaire: SessionQuestionnaire) {
        check(startupReady && !accountBusy) { "Дождитесь восстановления локальных данных и операции аккаунта / Wait for local recovery and account operation" }
        check(!deviceFeatureController.isV2PreviewConnection()) { getString(R.string.v2_ordinary_recording_unavailable) }
        val profileId = requireNotNull(selectedProfileId) { "Выберите карточку животного / Select an animal profile" }
        val recording = woonaDatabase.beginRecording(
            profileId = profileId,
            source = RecordingSource.LIVE,
            questionnaire = questionnaire,
        )
        deviceFeatureController.beginRecordingSession(recording)
        deviceFeatureController.onConnectRequested(address)
        if (
            questionnaire.videoRequested &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            isCameraPermissionRequestInProgress = true
            requestCameraPermissionLauncher.launch(Manifest.permission.CAMERA)
        }
        refreshProfilesAndRecordings()
    }

    private fun selectProfile(profileId: String) {
        if (accountBusy || isServerRestoreInProgress || deviceFeatureController.isCaptureActive()) return
        if (dogProfiles.none { it.id == profileId }) return
        selectedProfileId = profileId
        profilePreferences.edit().putString(LAST_PROFILE_ID_KEY, profileId).apply()
        showingAllRecordings = false
        recentRecordings = woonaDatabase.recentRecordings(profileId)
    }

    private fun refreshProfilesAndRecordings(preferredProfileId: String? = null) {
        val allProfiles = woonaDatabase.profiles()
        val account = serverSettingsStore.get().accountId
        val profiles = allProfiles.filter { it.accountId == account }
        val recordingCount = woonaDatabase.readableDatabase.rawQuery("SELECT COUNT(*) FROM recordings", null).use { it.moveToFirst(); it.getInt(0) }
        val hiddenProfiles = allProfiles.size - profiles.size
        localHistorySummary = if (selectedLanguage == AppLanguage.RUSSIAN) {
            "Локальная история: ${allProfiles.size} животных, $recordingCount сессий. Активный аккаунт: ${account ?: "без аккаунта"}." +
                if (hiddenProfiles > 0) "\nФильтр аккаунта скрывает $hiddenProfiles животных. Данные не удалены: примените прежний аккаунт или свяжите животное без аккаунта." else ""
        } else {
            "Local history: ${allProfiles.size} animals, $recordingCount sessions. Active account: ${account ?: "unassigned"}." +
                if (hiddenProfiles > 0) "\nThe account filter hides $hiddenProfiles animals. Data is not deleted: apply the previous account or link an unassigned animal." else ""
        }
        dogProfiles = profiles
        val storedId = profilePreferences.getString(LAST_PROFILE_ID_KEY, null)
        val selectedId = sequenceOf(preferredProfileId, selectedProfileId, storedId)
            .filterNotNull()
            .firstOrNull { candidate -> profiles.any { it.id == candidate } }
            ?: profiles.firstOrNull()?.id
        selectedProfileId = selectedId
        if (selectedId == null) {
            recentRecordings = emptyList()
            editingProfile = null
            isDogQuestionnaireVisible = false
        } else {
            profilePreferences.edit().putString(LAST_PROFILE_ID_KEY, selectedId).apply()
            recentRecordings = woonaDatabase.recentRecordings(selectedId, if (showingAllRecordings) Int.MAX_VALUE else 10)
        }
    }

    private fun handleRecordingChanged() {
        runOnUiThread {
            if (!startupReady) return@runOnUiThread
            refreshProfilesAndRecordings()
            recentRecordings.firstOrNull {
                it.status.value in setOf("completed", "failed", "interrupted") && it.questionnaire?.sessionKind == "heart" && it.questionnaire.heartQuestionnaire == null
            }?.let { if (heartQuestionnaireRecordingId == null) { editingRecording = it; heartQuestionnaireRecordingId = it.id } }
            ServerSyncScheduler.enqueuePending(applicationContext)
            refreshServerState()
        }
    }

    private fun serverMutationBlockReason(uploading: Int): String? = when {
        deviceFeatureController.isCaptureActive() -> "capture"
        isServerRestoreInProgress -> "restore"
        uploading > 0 -> "upload"
        accountBusy -> "account"
        else -> null
    }

    private fun refreshServerState() {
        if (!startupReady) return
        val settings = serverSettingsStore.get()
        if (reportConfiguration != null && reportConfiguration != settings) {
            serverRecordingReports = emptyMap()
            reportConfiguration = settings
        }
        if (checkedConfiguration != null && checkedConfiguration != settings && connectionCheck != com.example.myapplication.sync.ConnectionCheck.CHECKING) {
            connectionCheck = com.example.myapplication.sync.ConnectionCheck.NOT_CHECKED
            connectionCheckedAt = null; connectionCheckError = null
        }
        val counts = woonaDatabase.serverSyncCounts()
        val cleanup = woonaDatabase.retirementCleanupStatus()
        serverSyncState = ServerSyncUiState(
            status = when {
                !settings.isConfigured -> ServerSyncStatus.NOT_CONFIGURED
                counts.failed > 0 -> ServerSyncStatus.NEEDS_ATTENTION
                workersRunning > 0 -> ServerSyncStatus.UPLOADING
                counts.uploading > 0 || counts.pending > 0 -> ServerSyncStatus.WAITING
                else -> ServerSyncStatus.READY
            },
            baseUrl = settings.baseUrl,
            wifiOnly = settings.wifiOnly,
            pending = counts.pending,
            uploading = counts.uploading,
            synced = counts.synced,
            failed = counts.failed,
            lastErrorMessage = counts.lastErrorMessage,
            restoring = isServerRestoreInProgress,
            mutationsAllowed = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && counts.uploading == 0,
            connectionEditorAllowed = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && !com.example.myapplication.data.isCompleteArchiveExporting,
            retirementCleanupPending = cleanup.pending,
            retirementCleanupError = cleanup.lastError,
            retirementDeferred = cleanup.deferredCount,
            retirementChecking = retirementChecking,
            retirementNetworkError = retirementNetworkError,
            networkPolicyAllowed = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && workersRunning == 0,
            mutationBlockReason = serverMutationBlockReason(counts.uploading),
            networkAvailable = networkCapabilities()?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true,
            unmeteredNetwork = networkCapabilities()?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == true,
            workersRunning = workersRunning,
            workersQueued = workersQueued,
            connectionCheck = connectionCheck,
            checkedAtUtc = connectionCheckedAt,
            connectionError = connectionCheckError,
            accountId = settings.accountId,
            operationMessage = serverSyncState.operationMessage,
        )
    }

    private fun networkCapabilities(): android.net.NetworkCapabilities? {
        val manager = getSystemService(android.net.ConnectivityManager::class.java)
        return manager.getNetworkCapabilities(manager.activeNetwork)
    }

    private fun checkRecordingOnServer(id: String) {
        if (serverRecordingReports[id]?.second == true) return
        val settings = serverSettingsStore.get()
        if (!settings.isConfigured) {
            serverRecordingReports = serverRecordingReports + (id to ((if (selectedLanguage == AppLanguage.RUSSIAN) "Подключите сервер в Настройках." else "Configure the server in Settings.") to false))
            return
        }
        serverRecordingReports = serverRecordingReports + (id to (null to true))
        reportConfiguration = settings
        val language = selectedLanguage
        backgroundExecutor.execute {
            val result = runCatching { com.example.myapplication.sync.recordingServerReport(ServerApiClient(settings).syncStatus(id), language) }
            runOnUiThread {
                if (settings != serverSettingsStore.get()) {
                    serverRecordingReports = serverRecordingReports - id
                } else {
                    val stamp = (if (language == AppLanguage.RUSSIAN) "Проверено: " else "Checked: ") + java.time.Instant.now().toString() + " · " + settings.baseUrl + "\n"
                    val report = stamp + result.getOrElse { com.example.myapplication.localization.recordingUploadErrorText(it.message, language) + "\n" + it.message.orEmpty() }
                    serverRecordingReports = serverRecordingReports + (id to (report to false))
                }
            }
        }
    }

    private fun disconnectServer() {
        if (!startupReady || accountBusy || isServerRestoreInProgress || deviceFeatureController.isCaptureActive() || com.example.myapplication.data.isCompleteArchiveExporting) {
            toast(if (selectedLanguage == AppLanguage.RUSSIAN) "Дождитесь записи, экспорта или операции аккаунта" else "Wait for capture, export or the account operation")
            return
        }
        accountBusy = true
        isServerSettingsVisible = false
        serverSyncState = serverSyncState.copy(operationMessage = if (selectedLanguage == AppLanguage.RUSSIAN) "Отключаем сервер и останавливаем передачи. Локальные данные сохраняются." else "Disconnecting server and stopping transfers. Local data is preserved.")
        refreshServerState()
        backgroundExecutor.execute {
            val result = runCatching { ServerSyncScheduler.disconnect(applicationContext) }
            runOnUiThread {
                accountBusy = false
                connectionCheck = com.example.myapplication.sync.ConnectionCheck.NOT_CHECKED
                connectionCheckedAt = null; connectionCheckError = null
                serverSyncState = serverSyncState.copy(operationMessage = result.fold(
                    onSuccess = { if (selectedLanguage == AppLanguage.RUSSIAN) "Сервер отключён, токен удалён с устройства. Локальные данные и очередь сохранены. Для продолжения укажите токен." else "Server disconnected and token removed from this device. Local data and queue are preserved. Enter a token to resume." },
                    onFailure = { (if (selectedLanguage == AppLanguage.RUSSIAN) "Отключение не завершено; локальные данные сохранены. Повторите действие.\n" else "Disconnection did not complete; local data is preserved. Retry.\n") + (it.message ?: it.javaClass.simpleName) },
                ))
                refreshServerState()
            }
        }
    }

    private fun checkServerConnection() {
        if (connectionCheck == com.example.myapplication.sync.ConnectionCheck.CHECKING) return
        val settings = serverSettingsStore.get()
        if (!settings.isConfigured) return
        connectionCheck = com.example.myapplication.sync.ConnectionCheck.CHECKING
        checkedConfiguration = settings
        connectionCheckError = null
        refreshServerState()
        backgroundExecutor.execute {
            val result = runCatching { ServerApiClient(settings).checkConnection() }
            runOnUiThread {
                if (settings != serverSettingsStore.get()) {
                    connectionCheck = com.example.myapplication.sync.ConnectionCheck.NOT_CHECKED
                    connectionCheckedAt = null
                } else {
                    connectionCheck = if (result.isSuccess) com.example.myapplication.sync.ConnectionCheck.VERIFIED else com.example.myapplication.sync.ConnectionCheck.FAILED
                    connectionCheckedAt = java.time.Instant.now().toString()
                    connectionCheckError = result.exceptionOrNull()?.let { com.example.myapplication.localization.recordingUploadErrorText(it.message, selectedLanguage) + "\n" + it.message.orEmpty() }
                }
                refreshServerState()
            }
        }
    }

    private fun applyAccount(value: String) {
        if (accountBusy || isServerRestoreInProgress || deviceFeatureController.isCaptureActive() || woonaDatabase.serverSyncCounts().uploading > 0) return
        val identifier = try { value.takeIf { it.isNotBlank() }?.let(::normalizeAccountId) }
            catch (error: Exception) { toast(error.message.orEmpty()); return }
        accountBusy = true
        val settings = serverSettingsStore.get().copy(accountId = identifier)
        backgroundExecutor.execute {
            val result = runCatching { serverOperationLock.withLock {
                if (identifier != null && settings.isConfigured) ServerApiClient(settings).applyAccount(identifier)
                val snapshot = if (settings.isConfigured) ServerApiClient(settings).fetchRestoreSnapshot() else null
                snapshot?.let {
                    woonaDatabase.restoreServerMetadata(it.dogs, it.recordings)
                    if (settings.sameRetirementServer(serverSettingsStore.get())) woonaDatabase.applyServerDeletions(it.deletions)
                }
                snapshot
            }
            }
            runOnUiThread {
                accountBusy = false
                result.onSuccess { snapshot ->
                    if (deviceFeatureController.isCaptureActive()) { toast("Дождитесь завершения записи"); return@onSuccess }
                    serverSettingsStore.setAccount(identifier)
                    serverSyncState = serverSyncState.copy(operationMessage = snapshot?.warnings?.let { com.example.myapplication.sync.restoreWarningsText(it,selectedLanguage) })
                    editingProfile = null; editingRecording = null; heartQuestionnaireRecordingId = null
                    isDogQuestionnaireVisible = false
                    refreshProfilesAndRecordings(); refreshServerState()
                }.onFailure { deviceFeatureController.showErrorOnMainThread(if (selectedLanguage == AppLanguage.RUSSIAN) "Не удалось применить аккаунт. Прежний аккаунт и локальные записи сохранены" else "Account change failed. The previous account and local recordings are preserved", it) }
            }
        }
    }

    private fun linkDogAccount(dogId: String) {
        val settings = serverSettingsStore.get()
        val account = settings.accountId ?: return
        if (accountBusy || deviceFeatureController.isCaptureActive() || woonaDatabase.serverSyncCounts().uploading > 0) return
        accountBusy = true
        backgroundExecutor.execute {
            val result = runCatching { serverOperationLock.withLock {
                val revision = woonaDatabase.profileSyncRecord(requireNotNull(woonaDatabase.profile(dogId)).profileVersionId)?.expectedRevision ?: 0L
                require(settings.isConfigured || revision == 0L) { "Подключитесь к серверу для связывания этой собаки" }
                if (settings.isConfigured) {
                    try { ServerApiClient(settings).linkDogAccount(dogId, account) }
                    catch (error: com.example.myapplication.sync.ServerHttpException) { if (error.status != 404 || revision != 0L) throw error }
                }
                woonaDatabase.linkDogAccount(dogId, account)
            }
            }
            runOnUiThread {
                accountBusy = false
                result.onSuccess { refreshProfilesAndRecordings(dogId); ServerSyncScheduler.enqueuePending(applicationContext) }
                    .onFailure { deviceFeatureController.showErrorOnMainThread(if (selectedLanguage == AppLanguage.RUSSIAN) "Не удалось связать животное с аккаунтом" else "Failed to link the animal to this account", it) }
            }
        }
    }

    private suspend fun saveEditedQuestionnaire(displayed: Recording, questionnaire: SessionQuestionnaire, revision: Int? = null, heartOnly: Boolean = false) {
        check(startupReady) { "Дождитесь восстановления локальных данных / Wait for local recovery" }
        check(!accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive()) { "Дождитесь завершения записи/операции аккаунта / Wait for capture/account operation" }
        val settings = serverSettingsStore.get()
        check(woonaDatabase.profile(displayed.profileId)?.accountId == settings.accountId) { "Аккаунт записи изменился / The recording account changed" }
        accountBusy = true
        try {
            withContext(Dispatchers.IO) { serverOperationLock.withLock {
                val current = requireNotNull(woonaDatabase.recording(displayed.id))
                check(current.status.value in setOf("completed", "failed", "interrupted")) { "Сначала завершите запись / Finish capture first" }
                check(current.serverSyncState != "uploading") { "Дождитесь завершения выгрузки / Wait for upload completion" }
                if (settings.isConfigured) {
                    val client = ServerApiClient(settings)
                    try {
                        val desired = if (heartOnly && revision != null) {
                            val latest = client.fetchRecording(displayed.id)
                            val answers = sessionQuestionnaireFromJson(latest.sessionQuestionnaireJson)
                            if (latest.questionnaireRevision != revision) throw com.example.myapplication.sync.QuestionnaireRevisionConflict(answers, latest.questionnaireRevision)
                            answers.copy(heartQuestionnaire = questionnaire.heartQuestionnaire)
                        } else questionnaire
                        com.example.myapplication.sync.saveQuestionnaireRevision(desired,
                            update = { client.editQuestionnaire(displayed.id, revision ?: displayed.questionnaireRevision, desired) },
                            read = { client.fetchRecording(displayed.id) },
                            persist = { woonaDatabase.acceptServerRecording(it) })
                    } catch (error: com.example.myapplication.sync.ServerHttpException) {
                        if (error.status != 404 || current.requiresServerQuestionnaireEdit) throw error
                        woonaDatabase.saveSessionQuestionnaire(displayed.id, questionnaire)
                    }
                } else {
                    check(!current.requiresServerQuestionnaireEdit) { "Для изменения серверной анкеты укажите адрес и токен / Configure server URL and token to edit the server questionnaire" }
                    woonaDatabase.saveSessionQuestionnaire(displayed.id, questionnaire)
                }
            } }
            editingRecording = null; heartQuestionnaireRecordingId = null
            handleRecordingChanged()
        } finally { accountBusy = false; refreshServerState() }
    }

    private fun restoreServerData() {
        if (accountBusy || isServerRestoreInProgress || deviceFeatureController.isCaptureActive()) return
        val settings = serverSettingsStore.get()
        if (!settings.isConfigured) return
        isServerRestoreInProgress = true
        refreshServerState()
        backgroundExecutor.execute {
            val outcome = runCatching { serverOperationLock.withLock {
                val snapshot = ServerApiClient(settings).fetchRestoreSnapshot()
                check(settings.sameRetirementServer(serverSettingsStore.get())) { "Server connection changed during restore; retry with the current connection" }
                val restored = woonaDatabase.restoreServerMetadata(snapshot.dogs, snapshot.recordings)
                woonaDatabase.applyServerDeletions(snapshot.deletions)
                restored to snapshot.warnings
            } }
            runOnUiThread {
                isServerRestoreInProgress = false
                refreshProfilesAndRecordings()
                refreshServerState()
                outcome.fold(
                    onSuccess = { (result, warnings) ->
                        serverSyncState = serverSyncState.copy(operationMessage = com.example.myapplication.sync.restoreWarningsText(warnings, selectedLanguage)
                            ?: if (selectedLanguage == AppLanguage.RUSSIAN) "Восстановление завершено. Серверные удаления проверены." else "Restore completed. Server retirements were checked.")
                        toast(
                            if (selectedLanguage == AppLanguage.RUSSIAN) {
                                "Восстановлено: собак ${result.dogs}, записей ${result.recordings}, файлов ${result.artifacts}" +
                                    if (result.conflicts > 0) ". Конфликты: ${result.conflicts}" else ""
                            } else {
                                "Restored: ${result.dogs} dogs, ${result.recordings} recordings, ${result.artifacts} files" +
                                    if (result.conflicts > 0) ". Conflicts: ${result.conflicts}" else ""
                            },
                        )
                    },
                    onFailure = { error ->
                        Log.e("SERVER_RESTORE", "Restore failed", error)
                        deviceFeatureController.showErrorOnMainThread(
                            if (selectedLanguage == AppLanguage.RUSSIAN) {
                                "Не удалось восстановить данные"
                            } else {
                                "Restore failed"
                            },
                            error,
                        )
                    },
                )
            }
        }
    }

    private fun removeLocalRecordingFiles(recordingId: String) {
        if (accountBusy || isServerRestoreInProgress || deviceFeatureController.isCaptureActive()) return
        val settings = serverSettingsStore.get()
        if (!settings.isConfigured) {
            toast(if (selectedLanguage == AppLanguage.RUSSIAN) "Подключите сервер, чтобы проверить копию перед удалением" else "Connect the server to verify the copy before removal")
            return
        }
        accountBusy = true
        backgroundExecutor.execute {
            val outcome = runCatching { serverOperationLock.withLock {
                val client = ServerApiClient(settings)
                val status = client.syncStatus(recordingId)
                require(com.example.myapplication.sync.confirmsCurrentServerCopy(status)) { "server_copy_unverified" }
                woonaDatabase.removeLocalRecordingFiles(recordingId, client.fetchRecording(recordingId))
            } }
            runOnUiThread {
                accountBusy = false
                refreshProfilesAndRecordings()
                refreshServerState()
                outcome.fold(
                    onSuccess = { toast(if (selectedLanguage == AppLanguage.RUSSIAN) "Локальные файлы удалены. Сессия осталась на сервере" else "Local files removed. The session remains on the server") },
                    onFailure = { error -> deviceFeatureController.showErrorOnMainThread(
                        if (selectedLanguage == AppLanguage.RUSSIAN) "Удаление с устройства не выполнено" else "Removal from this device failed",
                        IllegalStateException(recordingUploadErrorText(error.message, selectedLanguage)),
                    ) },
                )
            }
        }
    }

    private fun downloadRecording(recordingId: String) {
        val settings = serverSettingsStore.get()
        if (!settings.isConfigured) return
        backgroundExecutor.execute {
            val outcome = runCatching {
                val client = ServerApiClient(settings)
                woonaDatabase.remoteArtifacts(recordingId).forEach { artifact ->
                    val target = woonaDatabase.artifactDownloadTarget(artifact)
                    client.downloadArtifact(
                        artifact.id,
                        artifact.sizeBytes,
                        artifact.sha256,
                        target,
                    )
                    woonaDatabase.markArtifactDownloaded(artifact.id)
                }
            }
            runOnUiThread {
                refreshProfilesAndRecordings()
                outcome.fold(
                    onSuccess = {
                        toast(
                            if (selectedLanguage == AppLanguage.RUSSIAN) {
                                "Файлы скачаны и проверены"
                            } else {
                                "Files downloaded and verified"
                            },
                        )
                    },
                    onFailure = { error ->
                        Log.e("SERVER_DOWNLOAD", "Download failed", error)
                        deviceFeatureController.showErrorOnMainThread(
                            if (selectedLanguage == AppLanguage.RUSSIAN) {
                                "Не удалось скачать файлы"
                            } else {
                                "Download failed"
                            },
                            error,
                        )
                    },
                )
            }
        }
    }

    private fun observeServerWork() {
        WorkManager.getInstance(applicationContext)
            .getWorkInfosByTagLiveData(ServerSyncScheduler.WORK_TAG)
            .observe(this) { infos ->
                val maintenance = infos.filter { ServerSyncScheduler.MAINTENANCE_TAG in it.tags }
                retirementChecking = maintenance.any { it.state == androidx.work.WorkInfo.State.RUNNING }
                retirementNetworkError = maintenance.filter { it.outputData.getString("retirement_completed_at") != null }
                    .maxByOrNull { it.outputData.getString("retirement_completed_at").orEmpty() }?.outputData?.getString("retirement_error")
                workersRunning = infos.count { ServerSyncScheduler.MAINTENANCE_TAG !in it.tags && it.state == androidx.work.WorkInfo.State.RUNNING }
                workersQueued = infos.count { ServerSyncScheduler.MAINTENANCE_TAG !in it.tags && it.state in setOf(androidx.work.WorkInfo.State.ENQUEUED, androidx.work.WorkInfo.State.BLOCKED) }
                refreshServerState()
                refreshProfilesAndRecordings()
            }
    }

    private fun prepareShareIntentAsync(createIntent: () -> android.content.Intent?) {
        backgroundExecutor.execute {
            val intent = runCatching(createIntent).onFailure {
                deviceFeatureController.showErrorOnMainThread("Export failed", it)
            }.getOrNull()
            runOnUiThread {
                try {
                    intent?.let(::startActivity)
                } catch (error: Exception) {
                    deviceFeatureController.showErrorOnMainThread("Failed to open share sheet", error)
                } finally {
                    deviceFeatureController.clearExportProgress()
                }
            }
        }
    }

    private fun hasBlePermissions(): Boolean = blePermissions.all { permission ->
        ContextCompat.checkSelfPermission(this, permission) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    private fun setChartFullscreenActive(active: Boolean) {
        if (isChartFullscreenActive == active) return
        isChartFullscreenActive = active
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (active) {
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private companion object {
        const val TAG = "MAIN_ACTIVITY"
        const val PROFILE_PREFERENCES_NAME = "woona_profiles"
        const val LAST_PROFILE_ID_KEY = "last_profile_id"
        const val STATE_DOG_QUESTIONNAIRE_VISIBLE = "state_dog_questionnaire_visible"
        const val STATE_EDITING_PROFILE_ID = "state_editing_profile_id"
        const val STATE_SESSION_QUESTIONNAIRE_VISIBLE = "state_session_questionnaire_visible"
        const val STATE_PENDING_LIVE_ADDRESS = "state_pending_live_address"
        const val STATE_PENDING_REPLAY_QUESTIONNAIRE = "state_pending_replay_questionnaire"
        const val STATE_SERVER_SETTINGS_VISIBLE = "state_server_settings_visible"
        const val STATE_SESSION_PREPARATION_ERROR = "state_session_preparation_error"
        const val STATE_EDITING_RECORDING_ID = "state_editing_recording_id"
        const val STATE_EDITING_RECORDING_QUESTIONNAIRE = "state_editing_recording_questionnaire"
        const val STATE_EDITING_RECORDING_REVISION = "state_editing_recording_revision"
        const val STATE_HEART_RECORDING_ID = "state_heart_recording_id"
        const val STATE_REFERENCE_RECORDING_ID = "state_reference_recording_id"
        const val STATE_REFERENCE_URI = "state_reference_uri"
    }
}
