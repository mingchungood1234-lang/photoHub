package com.photohub.compressor.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.photohub.compressor.ui.theme.*
import kotlinx.coroutines.delay

enum class MascotMood {
    HAPPY,
    UPLOADING,
    CELEBRATE,
    SLEEPING,
    ALERT
}

/**
 * Cute animated cartoon mascot ("Sunny" the orange cloud-camera buddy) drawn natively on Canvas.
 */
@Composable
fun SunnyMascot(
    mood: MascotMood,
    modifier: Modifier = Modifier,
    size: Dp = 112.dp
) {
    val infinite = rememberInfiniteTransition(label = "sunnyMascot")
    val bobDuration = if (mood == MascotMood.UPLOADING || mood == MascotMood.CELEBRATE) 650 else 1500
    val bobFraction by infinite.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = bobDuration, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "bob"
    )
    val pulseScale by infinite.animateFloat(
        initialValue = 0.93f,
        targetValue = 1.07f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1750, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulse"
    )
    val waveAngle by infinite.animateFloat(
        initialValue = -14f,
        targetValue = -36f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 820, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "wave"
    )
    val sparklePhase by infinite.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1100, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "sparkle"
    )

    var isBlinking by remember { mutableStateOf(false) }
    LaunchedEffect(mood) {
        while (true) {
            delay(3200L)
            if (mood == MascotMood.HAPPY || mood == MascotMood.UPLOADING) {
                isBlinking = true
                delay(140L)
                isBlinking = false
            }
        }
    }

    val haloColor = when (mood) {
        MascotMood.HAPPY -> PhotoHubOrange
        MascotMood.UPLOADING -> PhotoHubAmber
        MascotMood.CELEBRATE -> PhotoHubMint
        MascotMood.SLEEPING -> PhotoHubCoral
        MascotMood.ALERT -> PhotoHubAmber
    }

    Canvas(modifier = modifier.size(size * 1.15f, size * 1.05f)) {
        val w = this.size.width
        val h = this.size.height
        val s = minOf(w, h)
        val cx = w / 2f
        val cy = h / 2f
        val bobY = -bobFraction * s * (if (mood == MascotMood.UPLOADING || mood == MascotMood.CELEBRATE) 0.065f else 0.04f)

        // 1. Soft pulsing halo
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(haloColor.copy(alpha = 0.28f), Color.Transparent),
                center = Offset(cx, cy),
                radius = s * 0.54f * pulseScale
            ),
            radius = s * 0.54f * pulseScale,
            center = Offset(cx, cy)
        )

        // 2. Fluffy cream cloud cushion
        val cloudY = cy + s * 0.31f
        val cloudColor = Color(0xFFFFFFFF).copy(alpha = 0.94f)
        drawRoundRect(
            color = cloudColor,
            topLeft = Offset(cx - s * 0.34f, cloudY - s * 0.08f),
            size = Size(s * 0.68f, s * 0.18f),
            cornerRadius = CornerRadius(s * 0.09f, s * 0.09f)
        )
        drawCircle(cloudColor, radius = s * 0.12f, center = Offset(cx - s * 0.19f, cloudY - s * 0.04f))
        drawCircle(cloudColor, radius = s * 0.145f, center = Offset(cx + s * 0.03f, cloudY - s * 0.07f))
        drawCircle(cloudColor, radius = s * 0.105f, center = Offset(cx + s * 0.22f, cloudY - s * 0.02f))

        // 3. Cute arms (bob with body)
        val bodyCy = cy + bobY
        rotate(degrees = if (mood == MascotMood.CELEBRATE) 38f else 22f, pivot = Offset(cx - s * 0.33f, bodyCy + s * 0.05f)) {
            drawRoundRect(
                color = PhotoHubDeepOrange,
                topLeft = Offset(cx - s * 0.40f, bodyCy - s * 0.06f),
                size = Size(s * 0.13f, s * 0.22f),
                cornerRadius = CornerRadius(s * 0.065f, s * 0.065f)
            )
        }
        val rightPivot = Offset(cx + s * 0.33f, bodyCy + (if (mood == MascotMood.CELEBRATE) -s * 0.02f else s * 0.03f))
        rotate(degrees = if (mood == MascotMood.CELEBRATE) -42f else waveAngle, pivot = rightPivot) {
            drawRoundRect(
                color = PhotoHubDeepOrange,
                topLeft = Offset(rightPivot.x - s * 0.065f, rightPivot.y - s * 0.11f),
                size = Size(s * 0.13f, s * 0.22f),
                cornerRadius = CornerRadius(s * 0.065f, s * 0.065f)
            )
        }

        // 4. Camera top shutter button & viewfinder bump
        drawRoundRect(
            color = PhotoHubAmber,
            topLeft = Offset(cx - s * 0.24f, bodyCy - s * 0.34f),
            size = Size(s * 0.13f, s * 0.09f),
            cornerRadius = CornerRadius(s * 0.045f, s * 0.045f)
        )
        drawRoundRect(
            color = PhotoHubOrange,
            topLeft = Offset(cx - s * 0.05f, bodyCy - s * 0.37f),
            size = Size(s * 0.25f, s * 0.15f),
            cornerRadius = CornerRadius(s * 0.09f, s * 0.09f)
        )

        // 5. Plump orange camera-buddy body
        val bodyW = s * 0.68f
        val bodyH = s * 0.56f
        val bodyTopLeft = Offset(cx - bodyW / 2f, bodyCy - bodyH / 2f)
        drawRoundRect(
            brush = Brush.linearGradient(
                colors = listOf(Color(0xFFFFB25B), Color(0xFFFA7A23), Color(0xFFEA580C)),
                start = bodyTopLeft,
                end = Offset(bodyTopLeft.x + bodyW, bodyTopLeft.y + bodyH)
            ),
            topLeft = bodyTopLeft,
            size = Size(bodyW, bodyH),
            cornerRadius = CornerRadius(s * 0.23f, s * 0.23f)
        )

        // Glossy top-left shine
        rotate(degrees = -14f, pivot = Offset(cx - s * 0.11f, bodyCy - s * 0.18f)) {
            drawOval(
                color = Color.White.copy(alpha = 0.28f),
                topLeft = Offset(cx - s * 0.26f, bodyCy - s * 0.23f),
                size = Size(s * 0.30f, s * 0.10f)
            )
        }

        // 6. Soft cream face window
        val faceW = s * 0.50f
        val faceH = s * 0.35f
        val faceCy = bodyCy + s * 0.03f
        drawRoundRect(
            color = Color(0xFFFFF5EB),
            topLeft = Offset(cx - faceW / 2f, faceCy - faceH / 2f),
            size = Size(faceW, faceH),
            cornerRadius = CornerRadius(s * 0.16f, s * 0.16f)
        )

        // 7. Rosy coral cheeks
        val cheekColor = Color(0xFFFF7F70).copy(alpha = 0.45f)
        drawOval(
            color = cheekColor,
            topLeft = Offset(cx - s * 0.20f, faceCy + s * 0.015f),
            size = Size(s * 0.09f, s * 0.055f)
        )
        drawOval(
            color = cheekColor,
            topLeft = Offset(cx + s * 0.11f, faceCy + s * 0.015f),
            size = Size(s * 0.09f, s * 0.055f)
        )

        // 8. Eyes & mouth
        val espresso = Color(0xFF312016)
        val eyeY = faceCy - s * 0.03f
        val eyeOffsetX = s * 0.115f
        val eyeR = s * 0.044f
        val strokeW = maxOf(2.2f, s * 0.025f)

        listOf(cx - eyeOffsetX, cx + eyeOffsetX).forEach { ex ->
            when {
                mood == MascotMood.CELEBRATE -> {
                    val p = Path().apply {
                        moveTo(ex - eyeR * 1.1f, eyeY + eyeR * 0.4f)
                        quadraticTo(ex, eyeY - eyeR * 0.9f, ex + eyeR * 1.1f, eyeY + eyeR * 0.4f)
                    }
                    drawPath(p, color = espresso, style = Stroke(width = strokeW, cap = StrokeCap.Round))
                }
                mood == MascotMood.SLEEPING -> {
                    val p = Path().apply {
                        moveTo(ex - eyeR * 1.05f, eyeY)
                        quadraticTo(ex, eyeY + eyeR * 0.9f, ex + eyeR * 1.05f, eyeY)
                    }
                    drawPath(p, color = espresso, style = Stroke(width = strokeW * 0.9f, cap = StrokeCap.Round))
                }
                isBlinking -> {
                    drawLine(
                        color = espresso,
                        start = Offset(ex - eyeR, eyeY),
                        end = Offset(ex + eyeR, eyeY),
                        strokeWidth = strokeW,
                        cap = StrokeCap.Round
                    )
                }
                else -> {
                    drawCircle(espresso, radius = eyeR, center = Offset(ex, eyeY))
                    drawCircle(Color.White, radius = eyeR * 0.36f, center = Offset(ex + eyeR * 0.28f, eyeY - eyeR * 0.28f))
                }
            }
        }

        val mouthY = faceCy + s * 0.065f
        when (mood) {
            MascotMood.ALERT -> {
                drawCircle(
                    color = espresso,
                    radius = s * 0.036f,
                    center = Offset(cx, mouthY + s * 0.01f),
                    style = Stroke(width = strokeW * 0.85f)
                )
            }
            MascotMood.SLEEPING -> {
                drawLine(
                    color = espresso.copy(alpha = 0.7f),
                    start = Offset(cx - s * 0.035f, mouthY),
                    end = Offset(cx + s * 0.035f, mouthY),
                    strokeWidth = strokeW * 0.85f,
                    cap = StrokeCap.Round
                )
            }
            else -> {
                val smile = Path().apply {
                    moveTo(cx - s * 0.065f, mouthY - s * 0.01f)
                    quadraticTo(cx, mouthY + s * 0.07f, cx + s * 0.065f, mouthY - s * 0.01f)
                }
                drawPath(smile, color = espresso, style = Stroke(width = strokeW, cap = StrokeCap.Round))
            }
        }

        // 9. Mood floating sparkles / accents
        val spShift = sparklePhase * s * 0.06f
        fun drawSparkle(center: Offset, radius: Float, color: Color) {
            val p = Path().apply {
                moveTo(center.x, center.y - radius)
                quadraticTo(center.x, center.y, center.x + radius, center.y)
                quadraticTo(center.x, center.y, center.x, center.y + radius)
                quadraticTo(center.x, center.y, center.x - radius, center.y)
                quadraticTo(center.x, center.y, center.x, center.y - radius)
                close()
            }
            drawPath(p, color = color)
        }

        when (mood) {
            MascotMood.HAPPY -> {
                drawSparkle(Offset(cx + s * 0.40f, cy - s * 0.30f - spShift), s * 0.075f, PhotoHubAmber)
            }
            MascotMood.UPLOADING -> {
                val arrowCenter = Offset(cx + s * 0.39f, cy - s * 0.28f - spShift * 1.4f)
                drawCircle(PhotoHubOrange, radius = s * 0.09f, center = arrowCenter)
                val arrow = Path().apply {
                    moveTo(arrowCenter.x, arrowCenter.y - s * 0.042f)
                    lineTo(arrowCenter.x, arrowCenter.y + s * 0.042f)
                    moveTo(arrowCenter.x - s * 0.035f, arrowCenter.y - s * 0.008f)
                    lineTo(arrowCenter.x, arrowCenter.y - s * 0.045f)
                    lineTo(arrowCenter.x + s * 0.035f, arrowCenter.y - s * 0.008f)
                }
                drawPath(arrow, color = Color.White, style = Stroke(width = strokeW * 0.9f, cap = StrokeCap.Round))
                drawSparkle(Offset(cx - s * 0.40f, cy - s * 0.22f + spShift), s * 0.065f, PhotoHubAmber)
            }
            MascotMood.CELEBRATE -> {
                drawSparkle(Offset(cx - s * 0.41f, cy - s * 0.30f - spShift), s * 0.08f, PhotoHubAmber)
                val badgeCenter = Offset(cx + s * 0.40f, cy - s * 0.28f - spShift)
                drawCircle(PhotoHubMint, radius = s * 0.095f, center = badgeCenter)
                val check = Path().apply {
                    moveTo(badgeCenter.x - s * 0.042f, badgeCenter.y + s * 0.002f)
                    lineTo(badgeCenter.x - s * 0.010f, badgeCenter.y + s * 0.035f)
                    lineTo(badgeCenter.x + s * 0.046f, badgeCenter.y - s * 0.030f)
                }
                drawPath(check, color = Color.White, style = Stroke(width = strokeW, cap = StrokeCap.Round))
            }
            MascotMood.SLEEPING -> {
                drawSparkle(Offset(cx + s * 0.36f, cy - s * 0.30f - spShift), s * 0.06f, PhotoHubCoral.copy(alpha = 0.8f))
                drawSparkle(Offset(cx + s * 0.44f, cy - s * 0.40f - spShift * 1.2f), s * 0.045f, PhotoHubAmber.copy(alpha = 0.7f))
            }
            MascotMood.ALERT -> {
                val badge = Offset(cx + s * 0.39f, cy - s * 0.30f)
                drawCircle(PhotoHubAmber, radius = s * 0.095f, center = badge)
                drawLine(
                    color = Color.White,
                    start = Offset(badge.x, badge.y - s * 0.042f),
                    end = Offset(badge.x, badge.y + s * 0.008f),
                    strokeWidth = strokeW,
                    cap = StrokeCap.Round
                )
                drawCircle(Color.White, radius = s * 0.015f, center = Offset(badge.x, badge.y + s * 0.042f))
            }
        }
    }
}

@Composable
fun PulsingStatusDot(
    color: Color = PhotoHubOrange,
    modifier: Modifier = Modifier
) {
    val infinite = rememberInfiniteTransition(label = "pulseDot")
    val scale by infinite.animateFloat(
        initialValue = 0.8f,
        targetValue = 1.45f,
        animationSpec = infiniteRepeatable(
            animation = tween(1050, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "dotScale"
    )
    val alpha by infinite.animateFloat(
        initialValue = 0.7f,
        targetValue = 0.05f,
        animationSpec = infiniteRepeatable(
            animation = tween(1050, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "dotAlpha"
    )
    Box(modifier = modifier.size(14.dp), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size(12.dp)
                .scale(scale)
                .clip(CircleShape)
                .background(color.copy(alpha = alpha))
        )
        Box(
            modifier = Modifier
                .size(7.dp)
                .clip(CircleShape)
                .background(color)
        )
    }
}

@Composable
fun GradientPrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    loading: Boolean = false
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) 0.96f else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = 450f),
        label = "btnScale"
    )
    val brush = if (enabled) {
        Brush.horizontalGradient(listOf(Color(0xFFFF9840), PhotoHubOrange, PhotoHubDeepOrange))
    } else {
        Brush.horizontalGradient(listOf(PhotoHubOrange.copy(alpha = 0.4f), PhotoHubDeepOrange.copy(alpha = 0.4f)))
    }

    Box(
        modifier = modifier
            .scale(scale)
            .height(50.dp)
            .clip(CircleShape)
            .background(brush)
            .clickable(
                enabled = enabled && !loading,
                interactionSource = interaction,
                indication = null,
                onClick = onClick
            )
            .padding(horizontal = 22.dp),
        contentAlignment = Alignment.Center
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    color = Color.White,
                    strokeWidth = 2.2.dp
                )
            } else if (icon != null) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(19.dp))
            }
            Text(
                text = text,
                color = Color.White,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )
        }
    }
}

@Composable
fun SoftOrangeButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    enabled: Boolean = true
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) 0.96f else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = 450f),
        label = "softScale"
    )

    Surface(
        onClick = onClick,
        enabled = enabled,
        interactionSource = interaction,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.primaryContainer,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = modifier
            .scale(scale)
            .height(46.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            if (icon != null) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
            }
            Text(
                text = text,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold
            )
        }
    }
}

@Composable
fun WarmStatChip(
    text: String,
    tint: Color = PhotoHubOrange,
    icon: ImageVector? = null
) {
    Surface(
        shape = CircleShape,
        color = tint.copy(alpha = 0.13f)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            if (icon != null) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(13.dp))
            }
            Text(
                text = text,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = tint
            )
        }
    }
}

@Composable
fun WarmCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.7f)),
        tonalElevation = 1.dp,
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            content = content
        )
    }
}

@Composable
fun WarmShimmerBox(
    modifier: Modifier = Modifier,
    cornerRadius: Dp = 12.dp
) {
    val infinite = rememberInfiniteTransition(label = "warmShimmer")
    val shift by infinite.animateFloat(
        initialValue = -0.6f,
        targetValue = 1.6f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1350, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "shimmerShift"
    )
    val baseColor = MaterialTheme.colorScheme.surfaceVariant
    val highlight = PhotoHubOrange.copy(alpha = 0.16f)
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(cornerRadius))
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(baseColor, highlight, baseColor),
                    start = Offset(shift * 420f - 180f, 0f),
                    end = Offset(shift * 420f + 180f, 180f)
                )
            )
    )
}

@Composable
fun CloudLoadingSkeleton(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            SunnyMascot(mood = MascotMood.UPLOADING, size = 90.dp)
            Text(
                "Waking up your cloud…",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onBackground
            )
            WarmShimmerBox(
                modifier = Modifier
                    .width(148.dp)
                    .height(5.dp),
                cornerRadius = 99.dp
            )
        }

        WarmShimmerBox(
            modifier = Modifier
                .width(136.dp)
                .height(18.dp),
            cornerRadius = 8.dp
        )

        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            repeat(4) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    repeat(3) {
                        WarmShimmerBox(
                            modifier = Modifier
                                .weight(1f)
                                .aspectRatio(1f),
                            cornerRadius = 12.dp
                        )
                    }
                }
            }
        }
    }
}
