package com.example.myapplication

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
import com.example.myapplication.ble.BleTransportProfile
import com.example.myapplication.feature.device.DeviceSettingsScreen
import com.example.myapplication.feature.device.DeviceUiState
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.ui.theme.AppThemeMode
import com.example.myapplication.localization.AppLocalizationProvider
import com.example.myapplication.localization.AppTextResolver
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/**
 * A one-line marquee inside equal-width chips hid the beginning of the Russian
 * "Максимальная производительность" label on a narrow phone, and equal weights
 * broke the words mid-syllable. The option labels must stay fully readable.
 */
class SettingsChipLayoutTest {
    @get:Rule val compose = createAndroidComposeRule<androidx.activity.ComponentActivity>()

    @Test fun narrowRussianSettingsKeepEveryBleProfileLabelReadable() {
        compose.setContent {
            AppLocalizationProvider(
                language = AppLanguage.RUSSIAN,
                textResolver = AppTextResolver(compose.activity) { AppLanguage.RUSSIAN },
            ) {
                Box(Modifier.width(320.dp)) {
                    DeviceSettingsScreen(
                        uiState = DeviceUiState(),
                        selectedLanguage = AppLanguage.RUSSIAN,
                        selectedThemeMode = AppThemeMode.SYSTEM,
                        onTransportProfileSelect = {},
                        onLanguageSelect = {},
                        onThemeModeSelect = {},
                    )
                }
            }
        }

        val titles = listOf(
            "Максимальная производительность",
            "Совместимость",
            "Консервативный",
        )
        titles.forEach { compose.onNodeWithText(it).assertIsDisplayed() }

        val rootWidth = compose.onRoot().getUnclippedBoundsInRoot().width
        val widest = compose.onNodeWithText("Максимальная производительность")
            .getUnclippedBoundsInRoot().width
        // The longest option needs its own line instead of a third of the row.
        assertTrue(
            "Longest BLE profile label was squeezed into $widest of $rootWidth",
            widest >= rootWidth * 0.6f,
        )
        assertTrue(
            "Every profile option must be offered",
            BleTransportProfile.entries.size == 3,
        )
    }
}
