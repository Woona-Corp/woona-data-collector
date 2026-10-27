package com.example.myapplication.sync

import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Test
import org.junit.Assert.*

class ServerDisconnectTest {
    private class FakeConnection:HttpURLConnection(URL("https://invalid.example")) {
        val closed=CountDownLatch(1)
        override fun connect() {}
        override fun disconnect() {closed.countDown()}
        override fun usingProxy()=false
    }
    @Test fun disconnectClosesActiveConnectionsAndRejectsCapturedSettingsBeforeNewNetworkAccess() {
        val snapshot=ServerSettings("https://invalid.example","synthetic","device",true)
        val connection=FakeConnection()
        ServerTransferRegistry.register(connection,snapshot.transferGeneration)
        ServerTransferRegistry.cancelAll()
        assertTrue(connection.closed.await(2,TimeUnit.SECONDS))
        var networkOpened=false
        val client=ServerApiClient(snapshot,connectionFactory={networkOpened=true;FakeConnection()})
        assertThrows(CancellationException::class.java) {client.fetchDeletions()}
        assertFalse(networkOpened)
        val staleConnection=FakeConnection()
        assertThrows(CancellationException::class.java) {ServerTransferRegistry.register(staleConnection,snapshot.transferGeneration)}
        assertTrue(staleConnection.closed.await(2,TimeUnit.SECONDS))
        val fresh=ServerSettings(snapshot.baseUrl,snapshot.token,snapshot.deviceId,true)
        val resumed=FakeConnection();ServerTransferRegistry.register(resumed,fresh.transferGeneration);ServerTransferRegistry.release(resumed)
        assertTrue(resumed.closed.await(2,TimeUnit.SECONDS))
    }
    @Test fun destructiveRetirementResponseCannotCrossServerTokenOrGenerationChanges() {
        val original=ServerSettings("https://invalid.example","synthetic","device",true,"account-a")
        val marker=listOf("recording" to "a".repeat(64))
        for(changed in listOf(original.copy(baseUrl="https://other.invalid"),original.copy(token="other-synthetic"),original.copy(transferGeneration=original.transferGeneration+1))) {
            var applied=false
            assertFalse(reconcileCurrentRetirements(original,{changed},{marker},{applied=true}))
            assertFalse(applied)
        }
        var accepted:List<Pair<String,String>>?=null
        // Global retirement remains authoritative across the UI account selector.
        assertTrue(reconcileCurrentRetirements(original,{original.copy(accountId="account-b")},{marker},{accepted=it}))
        assertEquals(marker,accepted)
    }
    @Test fun authenticationAndServerFailuresAreNeverConvertedToAnEmptySuccessfulRetirementList() {
        val original=ServerSettings("https://invalid.example","synthetic","device",true)
        for(status in listOf(401,403,500)) {
            var applied=false
            val error=assertThrows(ServerHttpException::class.java) {
                reconcileCurrentRetirements(original,{original},{throw ServerHttpException(status,"synthetic failure",emptyMap())},{applied=true})
            }
            assertEquals(status,error.status);assertFalse(applied)
        }
    }
}
