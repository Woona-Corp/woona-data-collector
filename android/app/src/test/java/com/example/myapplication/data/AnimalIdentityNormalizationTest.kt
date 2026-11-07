package com.example.myapplication.data

import org.junit.Assert.*
import org.junit.Test

class AnimalIdentityNormalizationTest {
    @Test fun fullCasefoldUsesPinnedServerUnicode151NotTheDeviceOrJvmUnicodeVersion() {
        for ((source, folded) in listOf(
            " Straße " to "strasse", "Σςσ" to "σσσ", "ﬃ" to "ffi", "İ" to "i\u0307",
            "\uA7D0" to "\uA7D1",
            String(Character.toChars(0x10570)) to String(Character.toChars(0x10597)),
            String(Character.toChars(0x10400)) to String(Character.toChars(0x10428)),
            "\uAB70" to "\u13A0",
        )) {
            assertEquals(folded, normalizedAnimalIdentity(source))
            assertEquals(normalizedAnimalIdentity(source), normalizedAnimalIdentity(folded))
        }
        assertEquals(1530, animalIdentityCaseFolding.size)
        // Future Unicode16 folds are intentionally NOT server-equivalent.
        assertNotEquals(normalizedAnimalIdentity("\uA7CB"), normalizedAnimalIdentity("\u0264"))
        assertNotEquals(normalizedAnimalIdentity("\u1C89"), normalizedAnimalIdentity("\u1C8A"))
    }

    @Test fun pythonStripIncludesNelAndControlSeparatorsButDoesNotNormalizeSpelling() {
        val whitespace = (listOf(9, 10, 11, 12, 13, 28, 29, 30, 31, 32, 0x85, 0xA0, 0x1680) +
            (0x2000..0x200A) + listOf(0x2028, 0x2029, 0x202F, 0x205F, 0x3000))
            .joinToString("") { String(Character.toChars(it)) }
        assertEquals("dog", normalizedAnimalIdentity(whitespace + "DOG" + whitespace))
        assertEquals("", normalizedAnimalIdentity(whitespace))
        assertEquals("\u200bdog\u200b", normalizedAnimalIdentity("\u200bDOG\u200b"))
        assertNotEquals(normalizedAnimalIdentity("é"), normalizedAnimalIdentity("e\u0301"))
        assertNotEquals(normalizedAnimalIdentity("Ａ"), normalizedAnimalIdentity("A"))
    }
}
