package com.example.myapplication.localization

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf

private val LocalAppLanguage = staticCompositionLocalOf<AppLanguage> {
    error("App language was not provided")
}

private val LocalAppTextResolver = staticCompositionLocalOf<AppTextResolver> {
    error("App text resolver was not provided")
}

@Composable
fun AppLocalizationProvider(
    language: AppLanguage,
    textResolver: AppTextResolver,
    content: @Composable () -> Unit,
) {
    CompositionLocalProvider(
        LocalAppLanguage provides language,
        LocalAppTextResolver provides textResolver,
        content = content,
    )
}

@Composable
fun appStringResource(
    @StringRes resId: Int,
    vararg formatArgs: Any,
): String {
    return LocalAppTextResolver.current.getString(LocalAppLanguage.current, resId, *formatArgs)
}

@Composable
fun currentAppLanguage(): AppLanguage = LocalAppLanguage.current
