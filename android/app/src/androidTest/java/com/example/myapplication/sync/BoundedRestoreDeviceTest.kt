package com.example.myapplication.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class BoundedRestoreDeviceTest {
    @Test fun actualRestoreDetailsUseAtMostFourRequestsKeepOrderAndFetchMarkersLast() {
        val ids=(0 until 13).map { "00000000-0000-0000-0000-${it.toString().padStart(12,'0')}" }
        val active=AtomicInteger();val maximum=AtomicInteger();val firstFour=CountDownLatch(4)
        val paths=java.util.Collections.synchronizedList(mutableListOf<String>())
        val client=ServerApiClient(settings,connectionFactory={url ->
            object:HttpURLConnection(url) {
                private val counted=AtomicBoolean(false)
                override fun connect() {};override fun usingProxy()=false
                override fun disconnect() { if(counted.compareAndSet(true,false))active.decrementAndGet() }
                override fun getResponseCode():Int {
                    assertEquals("account-a",getRequestProperty("X-Woona-Account"));paths+=url.file
                    if(url.path.startsWith("/v1/dogs/") && !url.path.endsWith("/recordings")) {
                        counted.set(true);maximum.accumulateAndGet(active.incrementAndGet(),::maxOf)
                        if(url.path.substringAfterLast('/') in ids.take(4)) {firstFour.countDown();check(firstFour.await(3,TimeUnit.SECONDS))}
                    }
                    return 200
                }
                override fun getInputStream()=when {
                    url.file=="/v1/dogs?limit=200" -> page(ids)
                    url.path=="/v1/deletions" -> "{\"entities\":[]}"
                    url.path.endsWith("/recordings") -> page(emptyList())
                    else -> dog(url.path.substringAfterLast('/')).toString()
                }.byteInputStream()
            }
        })
        val result=client.fetchRestoreSnapshot()
        assertEquals(ids,result.dogs.map {it.id});assertTrue(result.recordings.isEmpty())
        assertEquals(4,maximum.get());assertEquals(0,active.get());assertEquals("/v1/deletions",paths.last())
        assertTrue(paths.filter {it.contains('?')}.all {it.contains("limit=200")})
    }
    @Test fun fatalDetailFailureDisconnectsSiblingRequestsWithoutCancellingUnrelatedTransfers() {
        val ids=(1..4).map {"00000000-0000-0000-0000-${it.toString().padStart(12,'0')}"}
        val allStarted=CountDownLatch(4);val release=CountDownLatch(1);val disconnected=CountDownLatch(3)
        val epoch=ServerTransferRegistry.generation
        val client=ServerApiClient(settings,connectionFactory={url ->object:HttpURLConnection(url) {
            private val closed=AtomicBoolean(false)
            override fun connect() {};override fun usingProxy()=false
            override fun disconnect() {if(url.path.startsWith("/v1/dogs/") && !url.path.endsWith(ids.first()) && closed.compareAndSet(false,true)) {disconnected.countDown();release.countDown()} }
            override fun getResponseCode():Int {
                if(url.path=="/v1/dogs")return 200
                allStarted.countDown();check(allStarted.await(3,TimeUnit.SECONDS))
                if(url.path.endsWith(ids.first()))return 401
                if(!release.await(3,TimeUnit.SECONDS))error("Sibling request was not disconnected")
                throw java.io.IOException("Fixture read cancelled")
            }
            override fun getInputStream()=page(ids).byteInputStream()
            override fun getErrorStream()="{\"errorCode\":\"invalid_bearer_token\"}".byteInputStream()
            override fun getHeaderFields():Map<String,List<String>> = emptyMap()
        }})
        try {
            assertEquals(401,assertThrows(ServerHttpException::class.java) {client.fetchRestoreSnapshot()}.status)
            assertTrue(disconnected.await(3,TimeUnit.SECONDS));assertEquals(epoch,ServerTransferRegistry.generation)
            ServerTransferRegistry.ensureActive(epoch)
        } finally {release.countDown()}
    }
    private val settings get()=ServerSettings("https://invalid.example","synthetic-token","device",false,"account-a")
    private fun page(ids:List<String>)=JSONObject().put("items",JSONArray(ids.map {JSONObject().put("id",it)})).put("nextCursor",JSONObject.NULL).toString()
    private fun dog(id:String)=JSONObject().put("id",id).put("accountId","account-a").put("numberOrName",id).put("revision",1).put("profileVersion",JSONObject().put("id",id).put("schemaVersion",2).put("questionnaire",JSONObject()).put("contentSha256","a".repeat(64)).put("clientCreatedAtUtc","2026-10-29T00:00:00Z"))
}
