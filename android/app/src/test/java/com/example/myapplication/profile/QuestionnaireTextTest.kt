package com.example.myapplication.profile

import com.example.myapplication.data.HEART_OPTIONS
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.questionnaireEnglishLabels
import com.example.myapplication.localization.questionnaireText
import org.junit.Assert.*
import org.junit.Test

class QuestionnaireTextTest {
    @Test fun everyCatalogEntryHasEnglishPresentationAndRussianOriginal() {
        assertTrue(questionnaireEnglishLabels.size >= 200)
        questionnaireEnglishLabels.forEach { (russian, english) ->
            assertFalse("Untranslated display text: $russian", english.any { it in 'А'..'я' || it == 'Ё' || it == 'ё' })
            assertEquals(english, questionnaireText(russian, AppLanguage.ENGLISH))
            assertEquals(russian, questionnaireText(russian, AppLanguage.RUSSIAN))
        }
    }

    @Test fun validationLocalizesBothSchemaGenerationsWithoutChangingModelMessages() {
        assertEquals("Enter an animal ID (up to 100 characters)", questionnaireText("Укажите ID животного (до 100 символов)", AppLanguage.ENGLISH))
        assertEquals("Maximum 150 characters", questionnaireText("Максимум 150 символов", AppLanguage.ENGLISH))
        assertEquals("Максимум 150 символов", questionnaireText("Maximum 150 characters", AppLanguage.RUSSIAN))
        assertEquals("Обязательное поле", questionnaireText("Required", AppLanguage.RUSSIAN))
        assertEquals("Поле должно быть пустым", questionnaireText("Must be empty", AppLanguage.RUSSIAN))
    }

    @Test fun everyCurrentFormLiteralAndValidationBranchHasPresentationCoverage() {
        fun source(path: String): String {
            val candidates = listOf("src/main/java/", "app/src/main/java/", "android/app/src/main/java/")
                .map { java.io.File(it + "com/example/myapplication/" + path) }
            return requireNotNull(candidates.firstOrNull { it.isFile }) { "Questionnaire source fixture is unavailable: $path" }.readText()
        }
        val forms = source("profile/ProfilesUi.kt").substringAfter("fun DogQuestionnaireDialog(")
        val literals = Regex("\"([^\"\n]*[А-Яа-яЁё][^\"\n]*)\"").findAll(forms).map { it.groupValues[1] }.toSet()
        assertTrue("Long-form source was not inventoried", literals.size > 150)
        literals.forEach { text ->
            assertFalse("Untranslated form label/option: $text", questionnaireText(text, AppLanguage.ENGLISH).any { it in 'А'..'я' || it == 'Ё' || it == 'ё' })
        }
        val validation = listOf("data/SheetQuestionnaires.kt", "data/HeartQuestionnaire.kt", "data/WoonaData.kt").flatMap { path ->
            Regex("errors\\[[^\\n]*?\\] = \"([^\"]*)\"").findAll(source(path)).map { it.groupValues[1].replace("${'$'}max", "150") }.toList()
        }.toSet()
        assertTrue(validation.size > 30)
        validation.forEach { message ->
            assertFalse("Untranslated validation: $message", questionnaireText(message, AppLanguage.ENGLISH).any { it in 'А'..'я' || it == 'Ё' || it == 'ё' })
            assertTrue("Missing Russian validation: $message", questionnaireText(message, AppLanguage.RUSSIAN).any { it in 'А'..'я' || it == 'Ё' || it == 'ё' } || message == "BCS: 1–9")
        }
    }

    @Test fun heartOptionTitlesTranslateWithoutMutatingCanonicalKeysOrTexts() {
        val before = HEART_OPTIONS.mapValues { (_, values) -> values.toList() }
        HEART_OPTIONS.values.flatten().forEach { (_, russianTitle) ->
            assertFalse(questionnaireText(russianTitle, AppLanguage.ENGLISH).any { it in 'А'..'я' || it == 'Ё' || it == 'ё' })
        }
        assertEquals(before, HEART_OPTIONS)
        assertEquals("Unlisted imported answer / Иван", questionnaireText("Unlisted imported answer / Иван", AppLanguage.ENGLISH))
    }
}
