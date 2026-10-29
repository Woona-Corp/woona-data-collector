package com.example.myapplication.sync

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.localization.AppLanguage
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.net.HttpURLConnection

@RunWith(AndroidJUnit4::class)
class ServerStorageStatusDeviceTest {
    @get:Rule val compose=createComposeRule()

    @Test fun authenticatedManualReadValidatesExactAccountAndPreservesLargeIntegerVolumes() {
        var requested=0
        val client=ServerApiClient(settings,connectionFactory={url ->
            assertEquals("/v1/storage-status",url.file);requested++
            object:HttpURLConnection(url) {
                override fun connect() {};override fun disconnect() {};override fun usingProxy()=false
                override fun getResponseCode():Int {
                    assertEquals("Bearer synthetic-token",getRequestProperty("Authorization"))
                    assertEquals("account-a",getRequestProperty("X-Woona-Account"));return 200
                }
                override fun getInputStream()=fixture().toString().byteInputStream()
            }
        })
        val value=client.storageStatus()
        assertEquals(1,requested);assertEquals("account-a",value.accountId)
        assertEquals(9007199254740993L,value.serverTotalBytes)
        assertNull(value.remainingQuotaBytes);assertEquals(0L,value.accountLimitBytes)
        assertEquals(listOf("capacity_reserved"),value.blockingReasons)
        assertTrue(value.existingUploadsMayResume)
    }
    @Test fun otherAccountAllAccountsAndNegativeMetricsAreNeverDisplayedAsCurrentScope() {
        for (wrong in listOf(fixture().apply {getJSONObject("checkedScope").put("accountId","account-b")},
            fixture().apply {getJSONObject("checkedScope").put("includesAllAccounts",true)},
            fixture().apply {getJSONObject("checkedScope").put("unassignedOnly",true)})) {
            assertEquals("storage_scope_mismatch",assertThrows(ServerTransferException::class.java) { parseServerStorageStatus(wrong,"account-a") }.code)
        }
        assertThrows(IllegalArgumentException::class.java) { parseServerStorageStatus(fixture().apply {getJSONObject("account").put("declaredReservedBytes",-1)},"account-a") }
        for (malformed in listOf(-0.5, 1.5, "0", "NaN", "9223372036854775808")) {
            val value=fixture().apply {getJSONObject("limits").put("accountBytes",malformed)}
            assertThrows(IllegalArgumentException::class.java) {parseServerStorageStatus(value,"account-a")}
        }
        val overflow=JSONObject(fixture().toString().replace("9007199254740993","9223372036854775808"))
        assertThrows(IllegalArgumentException::class.java) {parseServerStorageStatus(overflow,"account-a")}
        assertEquals(Long.MAX_VALUE,parseServerStorageStatus(fixture().apply {getJSONObject("limits").put("accountBytes",Long.MAX_VALUE)},"account-a").accountLimitBytes)
        val unassigned=fixture().apply {getJSONObject("checkedScope").put("accountId",JSONObject.NULL).put("unassignedOnly",true)}
        assertNull(parseServerStorageStatus(unassigned,null).accountId)
    }
    @Test fun storageSectionHasUncheckedLoadingUnavailableAndRetryStatesWithoutConnectionClaims() {
        val state=mutableStateOf(ServerStorageUiState());val configured=mutableStateOf(false);val language=mutableStateOf(AppLanguage.ENGLISH);var checks=0
        compose.setContent {MaterialTheme {Column(Modifier.verticalScroll(rememberScrollState())) {ServerStorageSection(state.value,configured.value,language.value,{checks++})}}}
        compose.onNodeWithText("Check server storage").assertIsNotEnabled()
        compose.runOnIdle {configured.value=true}
        compose.onNodeWithText("Storage and limits have not been checked yet.").assertExists()
        compose.onNodeWithText("Check server storage").performClick()
        compose.runOnIdle {assertEquals(1,checks);state.value=ServerStorageUiState(StorageCheck.CHECKING)}
        compose.onNodeWithText("Checking storage and limits…").assertExists()
        compose.onNodeWithText("Check server storage").assertIsNotEnabled()
        compose.runOnIdle {state.value=ServerStorageUiState(StorageCheck.UNAVAILABLE,error="HTTP 404 fixture-request-id")}
        compose.onNodeWithText("This server version does not support storage and limits checks. Connection checks remain available separately.").assertExists()
        compose.onNodeWithText("HTTP 404 fixture-request-id").assertExists()
        compose.onNodeWithText("Retry storage check").performScrollTo().assertIsEnabled().performClick()
        compose.runOnIdle {assertEquals(2,checks);state.value=ServerStorageUiState(StorageCheck.FAILED,error="storage_scope_mismatch requestId=scope-fixture")}
        compose.onNodeWithText("The server returned storage status for a different account.",substring=true).assertExists()
        compose.runOnIdle {language.value=AppLanguage.RUSSIAN}
        compose.onNodeWithText("Сервер вернул статус другого аккаунта.",substring=true).assertExists()
        compose.onNodeWithText("requestId=scope-fixture",substring=true).assertExists()
    }
    @Test fun scopedVolumesShowUnlimitedAndGlobalCapacityWithoutClaimingVerifiedCopy() {
        val result=parseServerStorageStatus(fixture(),"account-a")
        compose.setContent {MaterialTheme {Column(Modifier.verticalScroll(rememberScrollState())) {ServerStorageSection(ServerStorageUiState(StorageCheck.CHECKED,"2026-10-29T10:00:00Z",result),true,AppLanguage.ENGLISH,{})}}}
        compose.onNodeWithText("Account: account-a").assertExists()
        compose.onNodeWithText("Account limit: Unlimited").assertExists()
        compose.onNodeWithText("Remaining account quota: Unlimited").assertExists()
        compose.onNodeWithText("Entire server — available for new uploads: 1.00 GiB").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Previously accepted uploads may resume.").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("These volumes do not verify file integrity.",substring=true).assertExists()
    }
    @Test fun olderBackendKeepsHttp404SeparateFromReadiness() {
        val client=ServerApiClient(settings,connectionFactory={url ->object:HttpURLConnection(url) {
            override fun connect() {};override fun disconnect() {};override fun usingProxy()=false
            override fun getResponseCode()=404
            override fun getErrorStream()="{\"requestId\":\"old-backend-fixture\"}".byteInputStream()
            override fun getHeaderFields():Map<String,List<String>> = emptyMap()
        }})
        val error=assertThrows(ServerHttpException::class.java) {client.storageStatus()}
        assertEquals(404,error.status);assertTrue(error.responseBody.contains("old-backend-fixture"))
    }
    @Test fun sharedCapturedWireContractMatchesNativeDtoAndFlatQuotaErrors() {
        val context=androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().context
        val contract=context.assets.open("storage-api-contract.json").bufferedReader().use {JSONObject(it.readText())}
        assertEquals(1,contract.getInt("contractVersion"))
        val status=contract.getJSONObject("storageStatus")
        assertEquals(200,status.getInt("httpStatus"))
        val parsed=parseServerStorageStatus(status.getJSONObject("body"),"qa-storage-wire-contract")
        assertEquals("qa-storage-wire-contract",parsed.accountId);assertTrue(parsed.existingUploadsMayResume)
        for ((key,code,http,action,retryable) in listOf(
            listOf("quotaExceeded","storage_quota_exceeded",413,"review_server_storage_limits",false),
            listOf("reservationUnavailable","storage_reservation_unavailable",507,"retry_after_storage_available",true))) {
            val response=contract.getJSONObject(key as String);val body=response.getJSONObject("body")
            assertEquals(http,response.getInt("httpStatus"));assertEquals(code,body.getString("code"))
            assertEquals(action,body.getString("nextAction"));assertEquals(retryable,body.getBoolean("retryable"))
            assertFalse("Actual API errors are flat",body.has("detail"))
            val requestId=body.getString("requestId")
            assertEquals(requestId,response.getJSONObject("headers").getString("x-request-id"))
            val failure=ServerHttpException(http as Int,body.toString(),mapOf("X-Request-ID" to listOf(requestId)))
            assertTrue(failure.responseBody.contains(requestId))
            val explanation=com.example.myapplication.localization.recordingUploadErrorText(failure.message,AppLanguage.ENGLISH)
            assertFalse(explanation.contains(code as String));assertTrue(explanation.contains("Local files are preserved."))
            assertFalse(nextTransferActionText(action as String,false)==action)
        }
    }
    private val settings get()=ServerSettings("https://invalid.example","synthetic-token","device",false,"account-a")
    private fun fixture()=JSONObject("""{
        "checkedScope":{"accountId":"account-a","unassignedOnly":false,"includesAllAccounts":false},
        "limits":{"recordingBytes":21474836480,"accountBytes":0,"freeSpaceReserveBytes":1073741824},
        "account":{"declaredReservedBytes":1610612736,"acknowledgedBytes":1073741824,"remainingQuotaBytes":null,"recordings":3,"artifacts":6},
        "serverStorage":{"totalBytes":9007199254740993,"freeBytes":4294967296,"freeSpaceReserveBytes":1073741824,"pendingReservedBytes":2147483648,"pendingArtifacts":2,"newReservationAvailableBytes":1073741824,"scope":"server"},
        "status":"capacity_reserved","nextAction":"retry_after_storage_available","admission":{"blockingReasons":["capacity_reserved"]},"existingUploadsMayResume":true
    }""")
}
