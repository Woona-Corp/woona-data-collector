package com.example.myapplication.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

private val DarkColorScheme = darkColorScheme(
    primary = androidx.compose.ui.graphics.Color(0xFF7ACCC5),
    secondary = androidx.compose.ui.graphics.Color(0xFFA8C9CC),
    tertiary = androidx.compose.ui.graphics.Color(0xFFE9BE7C),
    background = androidx.compose.ui.graphics.Color(0xFF101E27),
    surface = androidx.compose.ui.graphics.Color(0xFF182C38),
    onSurface = androidx.compose.ui.graphics.Color(0xFFE3EDF1),
)
private val LightColorScheme = lightColorScheme(
    primary = androidx.compose.ui.graphics.Color(0xFF146B74),
    secondary = androidx.compose.ui.graphics.Color(0xFF437C80),
    tertiary = androidx.compose.ui.graphics.Color(0xFFA86E19),
    background = androidx.compose.ui.graphics.Color(0xFFF4F7FA),
    surface = androidx.compose.ui.graphics.Color.White,
    surfaceContainer = androidx.compose.ui.graphics.Color.White,
    secondaryContainer = androidx.compose.ui.graphics.Color(0xFFE3F4F1),
    onSecondaryContainer = androidx.compose.ui.graphics.Color(0xFF10555E),
    onSurface = androidx.compose.ui.graphics.Color(0xFF172B3C),
    onSurfaceVariant = androidx.compose.ui.graphics.Color(0xFF65778A),
    error = androidx.compose.ui.graphics.Color(0xFFB34A49),
)

@Composable
fun MyApplicationTheme(
    themeMode: AppThemeMode = AppThemeMode.SYSTEM,
    // minSdk is Android 12+, so dynamic color is always available when enabled.
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val darkTheme = when (themeMode) {
        AppThemeMode.SYSTEM -> isSystemInDarkTheme()
        AppThemeMode.LIGHT -> false
        AppThemeMode.DARK -> true
    }
    val colorScheme = when {
        dynamicColor -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }

        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = AppTypography.material3,
        content = content
    )
}

object AppThemeEntryPoint {
    @Composable
    fun Render(
        themeMode: AppThemeMode = AppThemeMode.SYSTEM,
        dynamicColor: Boolean = false,
        content: @Composable () -> Unit,
    ) {
        MyApplicationTheme(
            themeMode = themeMode,
            dynamicColor = dynamicColor,
            content = content,
        )
    }
}
