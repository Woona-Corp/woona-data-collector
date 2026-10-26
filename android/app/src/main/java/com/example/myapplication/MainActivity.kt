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
    private var connectionCheckedAt: String? = null
    private var connectionCheckError: String? = null
    private var workersRunning = 0
    private var workersQueued = 0
    private var isServerRestoreInProgress = false
    private var isServerSettingsVisible by mutableStateOf(false)
    private var isDogQuestionnaireVisible by mutableStateOf(false)
    private var editingProfile by mutableStateOf<DogProfile?>(null)
    private var isSessionQuestionnaireVisible by mutableStateOf(false)
    private var editingRecording by mutableStateOf<com.example.myapplication.data.Recording?>(null)
    private var accountBusy by mutableStateOf(false)
    private var heartQuestionnaireRecordingId by mutableStateOf<String?>(null)
    private var referenceRecordingId: String? = null
    private var referenceUri by mutableStateOf<android.net.Uri?>(null)

    private val referencePicker = registerForActivityResult(ActivityResultContracts.GetContent()) { uri -> referenceUri = uri }
    private var pendingLiveAddress: String? = null
    private var pendingReplayQuestionnaire: SessionQuestionnaire? = null
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
        if (uri == null) return@registerForActivityResult
        if (accountBusy) { toast("Дождитесь применения аккаунта"); return@registerForActivityResult }
        val profileId = selectedProfileId ?: return@registerForActivityResult
        val questionnaire = pendingReplayQuestionnaire ?: return@registerForActivityResult
        val recording = runCatching {
            woonaDatabase.beginRecording(
                profileId = profileId,
                source = RecordingSource.REPLAY,
                questionnaire = questionnaire,
            )
        }.getOrElse {
            Log.e(TAG, "Failed to prepare replay recording", it)
            deviceFeatureController.showErrorOnMainThread(if (selectedLanguage == AppLanguage.RUSSIAN) "Не удалось создать replay" else "Failed to create replay", it)
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

        if (!CaptureServiceBridge.isRunning && !DeviceFeatureControllerHolder.hasActiveCapture()) {
            woonaDatabase.interruptUnfinished()
        }
        refreshProfilesAndRecordings()
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
        }
        refreshServerState()
        ServerSyncScheduler.refreshPendingNetworkPolicy(applicationContext) { failure ->
            if (failure != null) runOnUiThread { deviceFeatureController.showErrorOnMainThread("Network policy reconciliation failed; original recordings and upload progress are preserved", failure) }
        }
        observeServerWork()
        deviceFeatureController
        CaptureServiceBridge.onStopRequested = {
            DeviceFeatureControllerHolder.requestStop()
        }
        enableEdgeToEdge()
        setContent {
            AppLocalizationEntryPoint.Provide(
                language = selectedLanguage,
                textResolver = appTextResolver,
            ) {
                val uiState = deviceFeatureController.uiState
                AppThemeEntryPoint.Render(themeMode = selectedThemeMode) {
                    AppShellEntryPoint.Render(
                        uiState = uiState,
                        selectedLanguage = selectedLanguage,
                        selectedThemeMode = selectedThemeMode,
                        serverSyncState = serverSyncState,
                        onStartScan = {
                            if (selectedProfileId == null) {
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
                            pendingLiveAddress = address
                            isSessionQuestionnaireVisible = true
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
                        onServerConfigure = { isServerSettingsVisible = true },
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
                        onServerRetryPending = {
                            woonaDatabase.resetFailedSync()
                            ServerSyncScheduler.enqueuePending(applicationContext)
                            refreshServerState()
                        },
                        onServerRestore = ::restoreServerData,
                        onServerCheck = ::checkServerConnection,
                        onDisconnect = ::stopSession,
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
                            androidx.compose.material3.Text(localHistorySummary)
                            AccountControls(
                                accountId = serverSettingsStore.get().accountId,
                                language = selectedLanguage,
                                enabled = !accountBusy && !isServerRestoreInProgress && !deviceFeatureController.isCaptureActive() && serverSyncState.uploading == 0,
                                unassigned = woonaDatabase.profiles().filter { it.accountId == null },
                                onApply = ::applyAccount, onLink = ::linkDogAccount,
                            )
                            }
                            ProfilesOverview(
                                showingAllRecordings = showingAllRecordings,
                                onShowAllRecordings = { showingAllRecordings = true; refreshProfilesAndRecordings() },
                                serverReports = serverRecordingReports,
                                onCheckServerRecording = ::checkRecordingOnServer,
                                section = section,
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
                                val saved = woonaDatabase.saveProfile(
                                    questionnaire = questionnaire,
                                    profileId = editingProfile?.id,
                                    accountId = serverSettingsStore.get().accountId,
                                )
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
                            onDismiss = {
                                pendingLiveAddress = null
                                isSessionQuestionnaireVisible = false
                            },
                            onSave = { questionnaire ->
                                isSessionQuestionnaireVisible = false
                                val address = pendingLiveAddress
                                pendingLiveAddress = null
                                if (address == null) {
                                    pendingReplayQuestionnaire = questionnaire
                                    replayFilePickerLauncher.launch("*/*")
                                } else {
                                    startLiveRecording(address, questionnaire)
                                }
                            },
                        )
                    }
                    heartQuestionnaireRecordingId?.let { id ->
                        HeartQuestionnaireDialog(
                            language = selectedLanguage,
                            initial = editingRecording?.questionnaire?.heartQuestionnaire ?: woonaDatabase.heartQuestionnaireDraft(id),
                            onDismiss = { heartQuestionnaireRecordingId = null; editingRecording = null },
                            onSave = {
                                val displayed = editingRecording ?: woonaDatabase.recording(id)
                                displayed?.questionnaire?.let { q -> saveEditedQuestionnaire(displayed, q.copy(heartQuestionnaire = it)) }
                            },
                        )
                    }
                    editingRecording?.takeIf { it.questionnaire?.sessionKind != "heart" }?.let { recording ->
                        SessionQuestionnaireDialog(language = selectedLanguage, initial = recording.questionnaire,
                            onDismiss = { editingRecording = null },
                            onSave = { saveEditedQuestionnaire(recording, it) })
                    }
                    referenceUri?.let { uri ->
                        val name = contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                            if (it.moveToFirst()) it.getString(0) else null
                        } ?: "data.bin"
                        ReferenceAttachmentDialog(selectedLanguage, name,
                            onDismiss = { referenceUri = null; referenceRecordingId = null },
                            onSave = { type, metadata ->
                                val id = requireNotNull(referenceRecordingId)
                                referenceUri = null
                                referenceRecordingId = null
                                backgroundExecutor.execute {
                                    try {
                                        woonaDatabase.attachReference(id, type, name, requireNotNull(contentResolver.openInputStream(uri)), metadata)
                                        handleRecordingChanged()
                                    } catch (error: Exception) { runOnUiThread { Toast.makeText(this, error.message, Toast.LENGTH_LONG).show() } }
                                }
                            },
                        )
                    }
                    if (isServerSettingsVisible) {
                        ServerSettingsDialog(
                            current = serverSettingsStore.get(),
                            language = selectedLanguage,
                            onDismiss = { isServerSettingsVisible = false },
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

    override fun onPause() {
        super.onPause()
        // An Activity losing focus is not a capture stop. The foreground
        // service and the explicit Stop action own the recording lifecycle.
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_DOG_QUESTIONNAIRE_VISIBLE, isDogQuestionnaireVisible)
        outState.putString(STATE_EDITING_PROFILE_ID, editingProfile?.id)
        outState.putBoolean(STATE_SESSION_QUESTIONNAIRE_VISIBLE, isSessionQuestionnaireVisible)
        outState.putString(STATE_PENDING_LIVE_ADDRESS, pendingLiveAddress)
        outState.putString(
            STATE_PENDING_REPLAY_QUESTIONNAIRE,
            pendingReplayQuestionnaire?.toJson(),
        )
        outState.putBoolean(STATE_SERVER_SETTINGS_VISIBLE, isServerSettingsVisible)
        super.onSaveInstanceState(outState)
    }

    override fun onResume() {
        super.onResume()
        refreshServerState()
    }

    override fun onDestroy() {
        setChartFullscreenActive(false)
        if (!deviceFeatureController.isCaptureActive()) {
            DeviceFeatureControllerHolder.releaseIfInactive(deviceFeatureController)
            CaptureServiceBridge.onStopRequested = null
            woonaDatabase.close()
        }
        backgroundExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun toggleCapture() {
        when (deviceFeatureController.uiState.videoState) {
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

    private fun startLiveRecording(address: String, questionnaire: SessionQuestionnaire) {
        if (accountBusy) { toast("Дождитесь применения аккаунта"); return }
        val profileId = selectedProfileId ?: return
        runCatching {
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
        }.onFailure {
            Log.e(TAG, "Failed to prepare live recording", it)
            deviceFeatureController.showErrorOnMainThread(if (selectedLanguage == AppLanguage.RUSSIAN) "Не удалось создать запись" else "Failed to create recording", it)
        }
    }

    private fun selectProfile(profileId: String) {
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
        localHistorySummary = if (selectedLanguage == AppLanguage.RUSSIAN)
            "Локальная история: ${allProfiles.size} животных, $recordingCount сессий. Аккаунт: ${account ?: "без аккаунта"}. Фильтр скрывает ${allProfiles.size - profiles.size} животных; смена аккаунта не удаляет данные."
            else "Local history: ${allProfiles.size} animals, $recordingCount sessions. Account: ${account ?: "unassigned"}. The filter hides ${allProfiles.size - profiles.size} animals; changing accounts does not delete data."
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
            refreshProfilesAndRecordings()
            recentRecordings.firstOrNull {
                it.endedAtUtc != null && it.questionnaire?.sessionKind == "heart" && it.questionnaire.heartQuestionnaire == null
            }?.let { if (heartQuestionnaireRecordingId == null) { editingRecording = it; heartQuestionnaireRecordingId = it.id } }
            ServerSyncScheduler.enqueuePending(applicationContext)
            refreshServerState()
        }
    }

    private fun refreshServerState() {
        val settings = serverSettingsStore.get()
        if (checkedConfiguration != null && checkedConfiguration != settings && connectionCheck != com.example.myapplication.sync.ConnectionCheck.CHECKING) {
            connectionCheck = com.example.myapplication.sync.ConnectionCheck.NOT_CHECKED
            connectionCheckedAt = null; connectionCheckError = null
        }
        val counts = woonaDatabase.serverSyncCounts()
        serverSyncState = ServerSyncUiState(
            status = when {
                !settings.isConfigured -> ServerSyncStatus.NOT_CONFIGURED
                counts.failed > 0 -> ServerSyncStatus.NEEDS_ATTENTION
                counts.uploading > 0 -> ServerSyncStatus.UPLOADING
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
        val language = selectedLanguage
        backgroundExecutor.execute {
            val result = runCatching { com.example.myapplication.sync.recordingServerReport(ServerApiClient(settings).syncStatus(id), language) }
            runOnUiThread {
                if (settings.accountId != serverSettingsStore.get().accountId) {
                    serverRecordingReports = serverRecordingReports - id
                } else {
                    val report = result.getOrElse { com.example.myapplication.localization.recordingUploadErrorText(it.message, language) + "\n" + it.message.orEmpty() }
                    serverRecordingReports = serverRecordingReports + (id to (report to false))
                }
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
                if (settings.isConfigured) ServerApiClient(settings).fetchRestoreSnapshot() else null
            }
            }
            runOnUiThread {
                accountBusy = false
                result.onSuccess { snapshot ->
                    if (deviceFeatureController.isCaptureActive()) { toast("Дождитесь завершения записи"); return@onSuccess }
                    snapshot?.let { woonaDatabase.restoreServerMetadata(it.dogs, it.recordings) }
                    serverSettingsStore.setAccount(identifier)
                    editingProfile = null; editingRecording = null; heartQuestionnaireRecordingId = null
                    isDogQuestionnaireVisible = false
                    refreshProfilesAndRecordings(); refreshServerState()
                }.onFailure { toast("Не удалось применить аккаунт: ${it.message}") }
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
                    .onFailure { toast("Не удалось связать собаку: ${it.message}") }
            }
        }
    }

    private fun saveEditedQuestionnaire(displayed: com.example.myapplication.data.Recording, questionnaire: SessionQuestionnaire) {
        val settings = serverSettingsStore.get().copy(accountId = woonaDatabase.profile(displayed.profileId)?.accountId)
        backgroundExecutor.execute {
            val result = runCatching { serverOperationLock.withLock {
                require(woonaDatabase.recording(displayed.id)?.serverSyncState != "uploading") { "Дождитесь завершения выгрузки" }
                if (settings.isConfigured) {
                    try {
                        woonaDatabase.acceptServerRecording(ServerApiClient(settings).editQuestionnaire(displayed.id, displayed.questionnaireRevision, questionnaire))
                    } catch (error: com.example.myapplication.sync.ServerHttpException) {
                        if (error.status != 404 || displayed.serverSyncState == "synced") throw error
                        woonaDatabase.saveSessionQuestionnaire(displayed.id, questionnaire)
                    }
                } else woonaDatabase.saveSessionQuestionnaire(displayed.id, questionnaire)
            }
            }
            runOnUiThread {
                result.onSuccess { editingRecording = null; heartQuestionnaireRecordingId = null; handleRecordingChanged() }
                    .onFailure { error -> toast(if (error is com.example.myapplication.sync.ServerHttpException && error.status == 409)
                        "Анкета изменена на сервере. Закройте редактор и восстановите данные, затем повторите изменения." else "Анкета не сохранена: ${error.message}") }
            }
        }
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
                val restored = woonaDatabase.restoreServerMetadata(snapshot.dogs, snapshot.recordings)
                woonaDatabase.applyServerDeletions(snapshot.deletions)
                restored
            } }
            runOnUiThread {
                isServerRestoreInProgress = false
                refreshProfilesAndRecordings()
                refreshServerState()
                outcome.fold(
                    onSuccess = { result ->
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
                workersRunning = infos.count { it.state == androidx.work.WorkInfo.State.RUNNING }
                workersQueued = infos.count { it.state in setOf(androidx.work.WorkInfo.State.ENQUEUED, androidx.work.WorkInfo.State.BLOCKED) }
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
    }
}
