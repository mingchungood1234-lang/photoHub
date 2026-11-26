package com.photohub.compressor.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Comfortable Sunset Orange & Warm Cream / Espresso Palette
val PhotoHubOrange = Color(0xFFF97316)       // Sunset tangerine primary
val PhotoHubDeepOrange = Color(0xFFEA580C)   // Warm burnt orange
val PhotoHubAmber = Color(0xFFF59E0B)        // Golden honey accent
val PhotoHubCoral = Color(0xFFFF865E)        // Soft coral highlight
val PhotoHubMint = Color(0xFF10B981)         // Fresh soothing mint (success)
val PhotoHubRed = Color(0xFFEF4444)          // Soft coral red (destructive)

// Warm surface tokens
val PhotoHubCreamBg = Color(0xFFFFF9F5)
val PhotoHubSoftPeach = Color(0xFFFFF0E5)
val PhotoHubPeachBorder = Color(0xFFF9D8C1)
val PhotoHubEspressoText = Color(0xFF261C15)
val PhotoHubWarmTaupe = Color(0xFF8C7466)

val PhotoHubDarkBg = Color(0xFF14100E)
val PhotoHubDarkSurface = Color(0xFF211A16)
val PhotoHubDarkPeach = Color(0xFF2E231D)
val PhotoHubDarkBorder = Color(0xFF41322A)

// Legacy color aliases mapped cleanly into the warm harmonious palette
val PhotoHubBlue = PhotoHubOrange
val PhotoHubIndigo = PhotoHubDeepOrange
val PhotoHubGreen = PhotoHubMint

private val LightColors = lightColorScheme(
    primary = PhotoHubOrange,
    onPrimary = Color.White,
    primaryContainer = PhotoHubSoftPeach,
    onPrimaryContainer = PhotoHubDeepOrange,
    secondary = PhotoHubAmber,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFFEF3C7),
    onSecondaryContainer = Color(0xFF92400E),
    tertiary = PhotoHubMint,
    onTertiary = Color.White,
    error = PhotoHubRed,
    onError = Color.White,
    background = PhotoHubCreamBg,
    onBackground = PhotoHubEspressoText,
    surface = Color.White,
    onSurface = PhotoHubEspressoText,
    surfaceVariant = PhotoHubSoftPeach,
    onSurfaceVariant = PhotoHubWarmTaupe,
    outlineVariant = PhotoHubPeachBorder
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFFB923C),
    onPrimary = Color(0xFF2A1205),
    primaryContainer = PhotoHubDarkPeach,
    onPrimaryContainer = Color(0xFFFDBA74),
    secondary = Color(0xFFFBBF24),
    onSecondary = Color(0xFF261802),
    secondaryContainer = Color(0xFF3A2910),
    onSecondaryContainer = Color(0xFFFDE68A),
    tertiary = Color(0xFF34D399),
    onTertiary = Color(0xFF03281C),
    error = Color(0xFFF87171),
    onError = Color(0xFF2B0808),
    background = PhotoHubDarkBg,
    onBackground = Color(0xFFFFF7F0),
    surface = PhotoHubDarkSurface,
    onSurface = Color(0xFFFFF7F0),
    surfaceVariant = PhotoHubDarkPeach,
    onSurfaceVariant = Color(0xFFB8A498),
    outlineVariant = PhotoHubDarkBorder
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
