package com.photohub.compressor.ui.screens

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.photohub.compressor.auth.GoogleAuthManager
import com.photohub.compressor.data.AppSettingsState
import com.photohub.compressor.ui.components.GradientPrimaryButton
import com.photohub.compressor.ui.components.MascotMood
import com.photohub.compressor.ui.components.SunnyMascot
import com.photohub.compressor.ui.components.WarmStatChip
import com.photohub.compressor.ui.theme.PhotoHubAmber
import com.photohub.compressor.ui.theme.PhotoHubMint
import com.photohub.compressor.ui.theme.PhotoHubOrange

@Composable
fun SignInScreen(
    settingsState: AppSettingsState,
    authManager: GoogleAuthManager
) {
    val context = LocalContext.current
    val isAuthenticating by authManager.isAuthenticating.collectAsStateWithLifecycle()
    val errorMessage by authManager.errorMessage.collectAsStateWithLifecycle()

    var entered by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { entered = true }
    val heroScale by animateFloatAsState(
        targetValue = if (entered) 1f else 0.85f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy),
        label = "signInHero"
    )

    val bgBrush = Brush.verticalGradient(
        colors = listOf(
            MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.85f),
            MaterialTheme.colorScheme.background
        )
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bgBrush)
            .systemBarsPadding()
            .padding(horizontal = 28.dp, vertical = 28.dp)
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Spacer(modifier = Modifier.height(16.dp))

            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                SunnyMascot(
                    mood = if (isAuthenticating) MascotMood.UPLOADING else MascotMood.HAPPY,
                    size = 132.dp,
                    modifier = Modifier.scale(heroScale)
                )

                Text(
                    text = "photoHub",
                    style = MaterialTheme.typography.headlineLarge,
                    fontWeight = FontWeight.ExtraBold,
                    color = MaterialTheme.colorScheme.onBackground
                )

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    WarmStatChip(text = "Backup", tint = PhotoHubOrange, icon = Icons.Rounded.CloudUpload)
                    WarmStatChip(text = "Compress", tint = PhotoHubAmber, icon = Icons.Rounded.AutoAwesome)
                    WarmStatChip(text = "Free", tint = PhotoHubMint, icon = Icons.Rounded.Verified)
                }
            }

            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                GradientPrimaryButton(
                    text = if (isAuthenticating) "Signing in…" else "Continue with Google",
                    icon = Icons.Rounded.AccountCircle,
                    enabled = settingsState.gatewayUrl != null,
                    loading = isAuthenticating,
                    onClick = { authManager.startSignIn(context) },
                    modifier = Modifier.fillMaxWidth()
                )

                if (!errorMessage.isNullOrBlank()) {
                    Text(
                        text = errorMessage.orEmpty(),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                        textAlign = TextAlign.Center
                    )
                }
            }
        }
    }
}
