package com.photohub.compressor.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.*
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.photohub.compressor.data.BackupStorageMode
import com.photohub.compressor.ui.components.*
import com.photohub.compressor.ui.theme.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class OnboardingStage {
    CHOOSE_MODE,
    TUTORIAL
}

/**
 * First-launch backup mode selection + animated interactive tutorial shown once when
 * photoHub is first opened on the device (and replayable anytime from Settings).
 */
@Composable
fun OnboardingScreen(
    initialMode: BackupStorageMode? = null,
    isReplay: Boolean = false,
    onComplete: (BackupStorageMode) -> Unit,
    onDismissReplay: (() -> Unit)? = null
) {
    var stage by remember { mutableStateOf(OnboardingStage.CHOOSE_MODE) }
    var selectedMode by remember { mutableStateOf(if (isReplay) initialMode else null) }
    val activeMode = selectedMode ?: BackupStorageMode.OPTIMIZE_STORAGE

    val bgBrush = Brush.verticalGradient(
        colors = listOf(
            MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.72f),
            MaterialTheme.colorScheme.background
        )
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bgBrush)
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        OnboardingAmbientGlow()

        AnimatedContent(
            targetState = stage,
            transitionSpec = {
                if (targetState == OnboardingStage.TUTORIAL) {
                    (slideInHorizontally(tween(340)) { it / 3 } + fadeIn(tween(260))) togetherWith
                        (slideOutHorizontally(tween(300)) { -it / 3 } + fadeOut(tween(200)))
                } else {
                    (slideInHorizontally(tween(340)) { -it / 3 } + fadeIn(tween(260))) togetherWith
                        (slideOutHorizontally(tween(300)) { it / 3 } + fadeOut(tween(200)))
                }
            },
            label = "onboardingStage"
        ) { currentStage ->
            when (currentStage) {
                OnboardingStage.CHOOSE_MODE -> ModeSelectionStage(
                    selectedMode = selectedMode,
                    isReplay = isReplay,
                    onSelect = { selectedMode = it },
                    onContinue = { stage = OnboardingStage.TUTORIAL },
                    onDismissReplay = onDismissReplay
                )

                OnboardingStage.TUTORIAL -> AnimatedTutorialStage(
                    mode = activeMode,
                    isReplay = isReplay,
                    onBackToMode = { stage = OnboardingStage.CHOOSE_MODE },
                    onFinish = { onComplete(activeMode) }
                )
            }
        }
    }
}

@Composable
private fun OnboardingAmbientGlow() {
    val infinite = rememberInfiniteTransition(label = "onboardingGlow")
    val drift by infinite.animateFloat(
        initialValue = -16f,
        targetValue = 16f,
        animationSpec = infiniteRepeatable(
            animation = tween(4200, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "drift"
    )

    Box(modifier = Modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .size(220.dp)
                .offset(x = (-70 + drift).dp, y = (-50 - drift).dp)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        listOf(PhotoHubOrange.copy(alpha = 0.14f), Color.Transparent)
                    )
                )
        )
        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .size(210.dp)
                .offset(x = (60 - drift).dp, y = (40 + drift).dp)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        listOf(PhotoHubAmber.copy(alpha = 0.14f), Color.Transparent)
                    )
                )
        )
    }
}

@Composable
private fun ModeSelectionStage(
    selectedMode: BackupStorageMode?,
    isReplay: Boolean,
    onSelect: (BackupStorageMode) -> Unit,
    onContinue: () -> Unit,
    onDismissReplay: (() -> Unit)?
) {
    Column(modifier = Modifier.fillMaxSize()) {
        if (isReplay && onDismissReplay != null) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.End
            ) {
                IconButton(onClick = onDismissReplay) {
                    Icon(Icons.Rounded.Close, contentDescription = "Close")
                }
            }
        }

        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Spacer(modifier = Modifier.height(if (isReplay) 4.dp else 18.dp))

            SunnyMascot(
                mood = if (selectedMode == null) MascotMood.HAPPY else MascotMood.CELEBRATE,
                size = 104.dp
            )

            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    text = "Welcome to photoHub",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.ExtraBold,
                    textAlign = TextAlign.Center
                )
                Text(
                    text = "Choose how photoHub should handle photos & videos on this device.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 12.dp)
                )
            }

            ModeOptionCard(
                mode = BackupStorageMode.OPTIMIZE_STORAGE,
                isSelected = selectedMode == BackupStorageMode.OPTIMIZE_STORAGE,
                icon = Icons.Rounded.AutoAwesome,
                badgeText = "Save ~90% Space",
                accent = PhotoHubOrange,
                bullets = listOf(
                    Icons.Rounded.CloudUpload to "Backs up full-resolution originals to your cloud",
                    Icons.Rounded.Compress to "Replaces originals on phone with tiny previews",
                    Icons.Rounded.IosShare to "Share or restore full originals anytime"
                ),
                onClick = { onSelect(BackupStorageMode.OPTIMIZE_STORAGE) }
            )

            ModeOptionCard(
                mode = BackupStorageMode.BACKUP_ONLY,
                isSelected = selectedMode == BackupStorageMode.BACKUP_ONLY,
                icon = Icons.Rounded.VerifiedUser,
                badgeText = "Originals Untouched",
                accent = PhotoHubMint,
                bullets = listOf(
                    Icons.Rounded.CloudUpload to "Automatically backs up every photo & video",
                    Icons.Rounded.Lock to "Never deletes or compresses photos on your phone",
                    Icons.Rounded.PhotoLibrary to "Ideal if you have plenty of phone storage"
                ),
                onClick = { onSelect(BackupStorageMode.BACKUP_ONLY) }
            )

            Text(
                text = "You can switch between modes anytime in Settings.",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(bottom = 12.dp)
            )
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            GradientPrimaryButton(
                text = if (selectedMode == null) "Choose an Option Above" else "Continue to Quick Tour",
                icon = if (selectedMode != null) Icons.Rounded.ChevronRight else null,
                enabled = selectedMode != null,
                onClick = onContinue,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun ModeOptionCard(
    mode: BackupStorageMode,
    isSelected: Boolean,
    icon: ImageVector,
    badgeText: String,
    accent: Color,
    bullets: List<Pair<ImageVector, String>>,
    onClick: () -> Unit
) {
    val scale by animateFloatAsState(
        targetValue = if (isSelected) 1.018f else 1f,
        animationSpec = spring(dampingRatio = 0.68f, stiffness = 420f),
        label = "modeCardScale"
    )
    val borderColor by animateColorAsState(
        targetValue = if (isSelected) accent else MaterialTheme.colorScheme.outlineVariant,
        animationSpec = tween(220),
        label = "modeCardBorder"
    )

    Surface(
        shape = RoundedCornerShape(22.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(if (isSelected) 2.2.dp else 1.dp, borderColor),
        shadowElevation = if (isSelected) 8.dp else 1.dp,
        modifier = Modifier
            .fillMaxWidth()
            .scale(scale)
            .clip(RoundedCornerShape(22.dp))
            .clickable(onClick = onClick)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Box(
                    modifier = Modifier
                        .size(46.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(accent.copy(alpha = if (isSelected) 0.20f else 0.12f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(icon, contentDescription = null, tint = accent, modifier = Modifier.size(24.dp))
                }

                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = mode.title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.ExtraBold
                    )
                    Surface(
                        shape = CircleShape,
                        color = accent.copy(alpha = 0.13f)
                    ) {
                        Text(
                            text = badgeText,
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                            color = accent,
                            modifier = Modifier.padding(horizontal = 9.dp, vertical = 3.dp)
                        )
                    }
                }

                Box(
                    modifier = Modifier
                        .size(26.dp)
                        .clip(CircleShape)
                        .background(if (isSelected) accent else Color.Transparent),
                    contentAlignment = Alignment.Center
                ) {
                    if (isSelected) {
                        Icon(
                            Icons.Rounded.Check,
                            contentDescription = "Selected",
                            tint = Color.White,
                            modifier = Modifier.size(16.dp)
                        )
                    } else {
                        Surface(
                            shape = CircleShape,
                            color = Color.Transparent,
                            border = BorderStroke(2.dp, MaterialTheme.colorScheme.outlineVariant),
                            modifier = Modifier.fillMaxSize()
                        ) {}
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for ((bIcon, text) in bullets) {
                    Row(
                        verticalAlignment = Alignment.Top,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = bIcon,
                            contentDescription = null,
                            tint = accent,
                            modifier = Modifier
                                .padding(top = 2.dp)
                                .size(15.dp)
                        )
                        Text(
                            text = text,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AnimatedTutorialStage(
    mode: BackupStorageMode,
    isReplay: Boolean,
    onBackToMode: () -> Unit,
    onFinish: () -> Unit
) {
    val totalPages = 4
    val pagerState = rememberPagerState(initialPage = 0, pageCount = { totalPages })
    val scope = rememberCoroutineScope()
    val isBackupOnly = mode == BackupStorageMode.BACKUP_ONLY

    Column(modifier = Modifier.fillMaxSize()) {
        // Top header bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(
                onClick = onBackToMode,
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Icon(
                        Icons.Rounded.ChevronLeft,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                        modifier = Modifier.size(16.dp)
                    )
                    Text(
                        "Mode",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onPrimaryContainer
                    )
                }
            }

            Spacer(modifier = Modifier.weight(1f))

            WarmStatChip(
                text = mode.shortTitle,
                tint = if (isBackupOnly) PhotoHubMint else PhotoHubOrange,
                icon = if (isBackupOnly) Icons.Rounded.VerifiedUser else Icons.Rounded.AutoAwesome
            )

            Spacer(modifier = Modifier.weight(1f))

            TextButton(onClick = onFinish) {
                Text(
                    if (pagerState.currentPage < totalPages - 1) "Skip" else "Done",
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        // Swipeable animated pages
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
        ) { page ->
            when (page) {
                0 -> TutorialSlideLayout(
                    title = "Every Memory, Verified & Safe",
                    description = "Your photos and 4K videos upload safely to your private cloud with SHA-256 verification so nothing is ever lost."
                ) {
                    UploadFlowAnimationCard()
                }

                1 -> if (!isBackupOnly) {
                    TutorialSlideLayout(
                        title = "Reclaim Up to 90% Space",
                        description = "Keep crisp lightweight previews in your native Gallery while full-resolution originals stay safely in your cloud."
                    ) {
                        OptimizeStorageAnimationCard()
                    }
                } else {
                    TutorialSlideLayout(
                        title = "Originals Stay Untouched",
                        description = "Backup Only never deletes, replaces, or compresses photos on your phone — your full-resolution library stays intact."
                    ) {
                        BackupOnlyAnimationCard()
                    }
                }

                2 -> TutorialSlideLayout(
                    title = if (isBackupOnly) "Access & Share Anywhere" else "Share Full Quality Anytime",
                    description = if (isBackupOnly) {
                        "Browse your full timeline from any device or web browser, search instantly, and share expiring photo links in one tap."
                    } else {
                        "Tap Share Original to fetch the exact full-res master on demand, or restore your full library back to Gallery anytime."
                    }
                ) {
                    ShareAccessAnimationCard(isBackupOnly = isBackupOnly)
                }

                else -> ReadyCelebrationSlide(
                    mode = mode,
                    onChangeMode = onBackToMode
                )
            }
        }

        // Page indicator pills + navigation buttons
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                repeat(totalPages) { idx ->
                    val selected = pagerState.currentPage == idx
                    val width by animateDpAsState(
                        targetValue = if (selected) 26.dp else 8.dp,
                        animationSpec = spring(dampingRatio = 0.72f, stiffness = 420f),
                        label = "dotWidth"
                    )
                    Box(
                        modifier = Modifier
                            .height(8.dp)
                            .width(width)
                            .clip(CircleShape)
                            .background(if (selected) PhotoHubOrange else PhotoHubOrange.copy(alpha = 0.25f))
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (pagerState.currentPage > 0) {
                    SoftOrangeButton(
                        text = "",
                        icon = Icons.Rounded.ChevronLeft,
                        onClick = {
                            scope.launch {
                                pagerState.animateScrollToPage(pagerState.currentPage - 1)
                            }
                        },
                        modifier = Modifier.width(56.dp)
                    )
                }

                val isLast = pagerState.currentPage == totalPages - 1
                GradientPrimaryButton(
                    text = when {
                        !isLast -> "Next"
                        isReplay -> "Save & Close"
                        else -> "Get Started"
                    },
                    icon = if (isLast) Icons.Rounded.CheckCircle else Icons.Rounded.ChevronRight,
                    onClick = {
                        if (!isLast) {
                            scope.launch {
                                pagerState.animateScrollToPage(pagerState.currentPage + 1)
                            }
                        } else {
                            onFinish()
                        }
                    },
                    modifier = Modifier.weight(1f)
                )
            }
        }
    }
}

@Composable
private fun TutorialSlideLayout(
    title: String,
    description: String,
    illustration: @Composable () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(250.dp),
            contentAlignment = Alignment.Center
        ) {
            illustration()
        }

        Spacer(modifier = Modifier.height(24.dp))

        Text(
            text = title,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.ExtraBold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(10.dp))

        Text(
            text = description,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 10.dp)
        )
    }
}

@Composable
private fun UploadFlowAnimationCard() {
    var step by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1150L)
            step = (step + 1) % 6
        }
    }
    val infinite = rememberInfiniteTransition(label = "uploadPulse")
    val haloScale by infinite.animateFloat(
        initialValue = 0.92f,
        targetValue = 1.12f,
        animationSpec = infiniteRepeatable(tween(1500, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "haloScale"
    )

    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        shadowElevation = 4.dp,
        modifier = Modifier.fillMaxSize()
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            // Cloud target at top
            Box(contentAlignment = Alignment.Center) {
                Box(
                    modifier = Modifier
                        .size(86.dp)
                        .scale(haloScale)
                        .clip(CircleShape)
                        .background(PhotoHubOrange.copy(alpha = 0.14f))
                )
                Icon(
                    Icons.Rounded.Cloud,
                    contentDescription = null,
                    tint = PhotoHubOrange,
                    modifier = Modifier.size(56.dp)
                )
                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surface,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .offset(x = 2.dp, y = (-4).dp)
                ) {
                    Icon(
                        Icons.Rounded.VerifiedUser,
                        contentDescription = null,
                        tint = PhotoHubMint,
                        modifier = Modifier
                            .padding(3.dp)
                            .size(18.dp)
                    )
                }
            }

            // Rising photo/video cards along glowing transfer beam
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(78.dp),
                contentAlignment = Alignment.Center
            ) {
                Box(
                    modifier = Modifier
                        .width(6.dp)
                        .height(64.dp)
                        .clip(CircleShape)
                        .background(
                            Brush.verticalGradient(
                                listOf(PhotoHubOrange.copy(alpha = 0.50f), PhotoHubAmber.copy(alpha = 0.15f))
                            )
                        )
                )

                val items = listOf(
                    Triple(Icons.Rounded.Photo, PhotoHubOrange, -36f),
                    Triple(Icons.Rounded.Videocam, PhotoHubCoral, 0f),
                    Triple(Icons.Rounded.AutoAwesome, PhotoHubMint, 36f)
                )
                items.forEachIndexed { idx, (icon, tint, xOff) ->
                    val phase = (step + idx) % 3
                    val yTarget = when (phase) {
                        0 -> 22f
                        1 -> 0f
                        else -> -24f
                    }
                    val yAnim by animateFloatAsState(
                        targetValue = yTarget,
                        animationSpec = spring(dampingRatio = 0.74f, stiffness = 240f),
                        label = "cardY$idx"
                    )
                    val alphaAnim by animateFloatAsState(
                        targetValue = if (phase == 1) 1f else 0.45f,
                        animationSpec = tween(320),
                        label = "cardA$idx"
                    )
                    Surface(
                        shape = RoundedCornerShape(10.dp),
                        color = tint,
                        shadowElevation = 4.dp,
                        modifier = Modifier
                            .offset(x = xOff.dp, y = yAnim.dp)
                            .size(30.dp)
                            .alpha(alphaAnim)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }

            // Bottom phone pill
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(
                        Icons.Rounded.PhoneAndroid,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                        modifier = Modifier.size(18.dp)
                    )
                    Text(
                        "SHA-256 Verified Upload",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onPrimaryContainer
                    )
                }
            }
        }
    }
}

@Composable
private fun OptimizeStorageAnimationCard() {
    var optimized by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(650L)
        while (true) {
            optimized = !optimized
            delay(2300L)
        }
    }

    val boxSize by animateDpAsState(
        targetValue = if (optimized) 58.dp else 78.dp,
        animationSpec = spring(dampingRatio = 0.72f, stiffness = 220f),
        label = "previewSize"
    )
    val barFraction by animateFloatAsState(
        targetValue = if (optimized) 0.14f else 0.92f,
        animationSpec = spring(dampingRatio = 0.78f, stiffness = 170f),
        label = "storageBar"
    )
    val barColor by animateColorAsState(
        targetValue = if (optimized) PhotoHubMint else PhotoHubRed,
        animationSpec = tween(420),
        label = "storageColor"
    )

    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        shadowElevation = 4.dp,
        modifier = Modifier.fillMaxSize()
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 20.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.SpaceEvenly,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(modifier = Modifier.size(82.dp), contentAlignment = Alignment.Center) {
                        Box(
                            modifier = Modifier
                                .size(boxSize)
                                .clip(RoundedCornerShape(16.dp))
                                .background((if (optimized) PhotoHubMint else PhotoHubOrange).copy(alpha = 0.18f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                Icons.Rounded.Photo,
                                contentDescription = null,
                                tint = if (optimized) PhotoHubMint else PhotoHubOrange,
                                modifier = Modifier.size(if (optimized) 26.dp else 36.dp)
                            )
                        }
                    }
                    Text(
                        text = if (optimized) "Preview · 2 MB" else "Original · 48 MB",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.ExtraBold,
                        color = if (optimized) PhotoHubMint else PhotoHubDeepOrange
                    )
                }

                Icon(
                    Icons.Rounded.ChevronRight,
                    contentDescription = null,
                    tint = PhotoHubOrange,
                    modifier = Modifier.size(28.dp)
                )

                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(modifier = Modifier.size(82.dp), contentAlignment = Alignment.Center) {
                        Box(
                            modifier = Modifier
                                .size(78.dp)
                                .scale(if (optimized) 1.05f else 0.95f)
                                .clip(RoundedCornerShape(16.dp))
                                .background(
                                    Brush.linearGradient(listOf(PhotoHubAmber, PhotoHubOrange, PhotoHubDeepOrange))
                                ),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Icon(Icons.Rounded.Cloud, contentDescription = null, tint = Color.White, modifier = Modifier.size(28.dp))
                                Text("4K HD", color = Color.White, fontWeight = FontWeight.ExtraBold, fontSize = 10.sp)
                            }
                        }
                    }
                    Text(
                        text = "Safe in Cloud",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.ExtraBold
                    )
                }
            }

            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(7.dp)
            ) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.PhoneAndroid, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Phone Storage", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                    Text(
                        text = if (optimized) "12% Used · ~90% Freed!" else "92% Full",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.ExtraBold,
                        color = barColor
                    )
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(14.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primaryContainer)
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .fillMaxWidth(barFraction)
                            .clip(CircleShape)
                            .background(barColor)
                    )
                }
            }
        }
    }
}

@Composable
private fun BackupOnlyAnimationCard() {
    var pulseStep by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(550L)
            pulseStep = (pulseStep + 1) % 3
        }
    }

    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        shadowElevation = 4.dp,
        modifier = Modifier.fillMaxSize()
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(18.dp),
            verticalArrangement = Arrangement.SpaceEvenly,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                // Untouched Phone Original Vault
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box {
                        Surface(
                            shape = RoundedCornerShape(18.dp),
                            color = PhotoHubMint.copy(alpha = 0.14f),
                            border = BorderStroke(2.dp, PhotoHubMint),
                            modifier = Modifier.size(86.dp)
                        ) {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.Center
                            ) {
                                Icon(Icons.Rounded.Photo, contentDescription = null, tint = PhotoHubMint, modifier = Modifier.size(30.dp))
                                Text("100%", color = PhotoHubMint, fontWeight = FontWeight.ExtraBold, fontSize = 11.sp)
                            }
                        }
                        Surface(
                            shape = CircleShape,
                            color = PhotoHubMint,
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .offset(x = 5.dp, y = (-5).dp)
                                .size(24.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(Icons.Rounded.Lock, contentDescription = null, tint = Color.White, modifier = Modifier.size(13.dp))
                            }
                        }
                    }
                    Text("Phone Original", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
                }

                // Shimmering sync dots
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    repeat(3) { idx ->
                        val active = pulseStep == idx
                        Box(
                            modifier = Modifier
                                .size(if (active) 10.dp else 7.dp)
                                .clip(CircleShape)
                                .background(if (active) PhotoHubOrange else PhotoHubOrange.copy(alpha = 0.25f))
                        )
                    }
                }

                // Cloud Mirror Copy
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box {
                        Box(
                            modifier = Modifier
                                .size(86.dp)
                                .clip(RoundedCornerShape(18.dp))
                                .background(
                                    Brush.linearGradient(listOf(PhotoHubAmber, PhotoHubOrange, PhotoHubDeepOrange))
                                ),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Icon(Icons.Rounded.Cloud, contentDescription = null, tint = Color.White, modifier = Modifier.size(30.dp))
                                Text("BACKUP", color = Color.White, fontWeight = FontWeight.ExtraBold, fontSize = 9.sp)
                            }
                        }
                        Surface(
                            shape = CircleShape,
                            color = PhotoHubMint,
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .offset(x = 5.dp, y = (-5).dp)
                                .size(24.dp)
                                .scale(if (pulseStep == 2) 1.15f else 1f)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(Icons.Rounded.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                            }
                        }
                    }
                    Text("Cloud Copy", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
                }
            }

            WarmStatChip(
                text = "Zero Deletions · Full Resolution Kept",
                tint = PhotoHubMint,
                icon = Icons.Rounded.VerifiedUser
            )
        }
    }
}

@Composable
private fun ShareAccessAnimationCard(isBackupOnly: Boolean) {
    val infinite = rememberInfiniteTransition(label = "shareRipple")
    val ripple by infinite.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2000, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "ripple"
    )

    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        shadowElevation = 4.dp,
        modifier = Modifier.fillMaxSize()
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            repeat(2) { idx ->
                val base = 110 + idx * 52
                Surface(
                    shape = CircleShape,
                    color = Color.Transparent,
                    border = BorderStroke(2.dp, PhotoHubOrange.copy(alpha = 0.26f - ripple * 0.20f)),
                    modifier = Modifier
                        .size(base.dp)
                        .scale(0.90f + ripple * 0.26f)
                ) {}
            }

            Surface(
                shape = RoundedCornerShape(20.dp),
                color = MaterialTheme.colorScheme.surface,
                shadowElevation = 6.dp
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        Icons.Rounded.IosShare,
                        contentDescription = null,
                        tint = PhotoHubOrange,
                        modifier = Modifier.size(40.dp)
                    )
                    Text("Original HD", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.ExtraBold)
                }
            }

            Box(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(16.dp)
                    .offset(y = (ripple * -6f).dp)
            ) {
                WarmStatChip(
                    text = "Share Link",
                    tint = PhotoHubOrange,
                    icon = Icons.Rounded.Link
                )
            }

            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(16.dp)
                    .offset(y = (ripple * 6f).dp)
            ) {
                WarmStatChip(
                    text = if (isBackupOnly) "Web & Phone" else "Restore Anytime",
                    tint = PhotoHubMint,
                    icon = if (isBackupOnly) Icons.Rounded.Public else Icons.Rounded.CloudDownload
                )
            }

            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 16.dp)
                    .offset(y = (ripple * -4f).dp)
            ) {
                WarmStatChip(
                    text = "Smart Search",
                    tint = PhotoHubAmber,
                    icon = Icons.Rounded.Search
                )
            }
        }
    }
}

@Composable
private fun ReadyCelebrationSlide(
    mode: BackupStorageMode,
    onChangeMode: () -> Unit
) {
    val isBackupOnly = mode == BackupStorageMode.BACKUP_ONLY

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        SunnyMascot(mood = MascotMood.CELEBRATE, size = 126.dp)

        Spacer(modifier = Modifier.height(18.dp))

        Text(
            text = "You're All Set!",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.ExtraBold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(10.dp))

        Text(
            text = if (isBackupOnly) {
                "photoHub will quietly back up your photos & videos while keeping every original untouched on your phone."
            } else {
                "photoHub will verify your cloud backups with SHA-256 and help you reclaim gigabytes on your phone."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(22.dp))

        Surface(
            shape = RoundedCornerShape(18.dp),
            color = MaterialTheme.colorScheme.surface,
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            modifier = Modifier.fillMaxWidth()
        ) {
            Row(
                modifier = Modifier.padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Icon(
                    imageVector = if (isBackupOnly) Icons.Rounded.VerifiedUser else Icons.Rounded.AutoAwesome,
                    contentDescription = null,
                    tint = if (isBackupOnly) PhotoHubMint else PhotoHubOrange,
                    modifier = Modifier.size(24.dp)
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Selected Mode",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = mode.title,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.ExtraBold
                    )
                }
                TextButton(onClick = onChangeMode) {
                    Text("Change", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}
