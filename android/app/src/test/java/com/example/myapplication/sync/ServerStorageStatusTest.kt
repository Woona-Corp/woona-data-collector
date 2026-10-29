package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage
import org.junit.Assert.*
import org.junit.Test

class ServerStorageStatusTest {
    @Test fun oldCallbacksAreRejectedAfterAccountTokenAddressOrEpochChanges() {
        val gate=StorageRequestEpoch()
        val a=ServerSettings("https://one.invalid","synthetic-a","d",false,"a")
        val old=gate.begin(a); assertTrue(gate.accepts(old,a))
        for (b in listOf(a.copy(accountId="b"),a.copy(token="synthetic-b"),a.copy(baseUrl="https://two.invalid"),a.copy(transferGeneration=a.transferGeneration+1))) {
            assertTrue(gate.configure(b)); assertFalse(gate.accepts(old,b)); gate.configure(a)
            assertFalse("A→B→A must never revive a response",gate.accepts(old,a))
        }
        val newer=gate.begin(a);assertTrue(gate.accepts(newer,a));assertFalse(gate.accepts(old,a))
    }
    @Test fun volumesAndLimitsUseTwoDecimalsAndExplicitUnlimited() {
        assertEquals("1.50 GiB",storageGiB(1610612736,AppLanguage.ENGLISH))
        assertEquals("1,50 ГиБ",storageGiB(1610612736,AppLanguage.RUSSIAN))
        assertEquals("0.00 GiB",storageGiB(0,AppLanguage.ENGLISH))
        assertEquals("Unlimited",storageGiB(0,AppLanguage.ENGLISH,true))
        assertEquals("Без ограничений",storageGiB(null,AppLanguage.RUSSIAN))
        assertEquals("Capacity is reserved by other uploads",storageAdmissionText("server_capacity_reserved",AppLanguage.ENGLISH))
        assertEquals("continue uploads on the source device",nextTransferActionText("continue_upload",false))
        assertEquals("Account storage limit reached",storageAdmissionText("account_quota_reached",AppLanguage.ENGLISH))
    }
}
