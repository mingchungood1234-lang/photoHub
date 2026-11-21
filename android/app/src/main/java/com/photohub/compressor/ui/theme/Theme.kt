package com.photohub.compressor.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val PhotoHubBlue = Color(0xFF007AFF)
val PhotoHubIndigo = Color(0xFF5856D6)
val PhotoHubGreen = Color(0xFF34C759)
val PhotoHubOrange = Color(0xFFFF9500)
val PhotoHubRed = Color(0xFFFF3B30)

private val LightColors = lightColorScheme(
    primary = PhotoHubBlue,
    onPrimary = Color.White,
    secondary = PhotoHubIndigo,
    onSecondary = Color.White,
    tertiary = PhotoHubGreen,
    error = PhotoHubRed,
    background = Color(0xFFF2F2F7),
    surface = Color.White,
    surfaceVariant = Color(0xFFE5E5EA)
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF0A84FF),
    onPrimary = Color.White,
    secondary = Color(0xFF5E5CE6),
    onSecondary = Color.White,
    tertiary = Color(0xFF30D158),
    error = Color(0xFFFF453A),
    background = Color(0xFF000000),
    surface = Color(0xFF1C1C1E),
    surfaceVariant = Color(0xFF2C2C2E)
)

@Composable
fun PhotoHubTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content
    )
}
