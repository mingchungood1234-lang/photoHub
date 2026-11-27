import Combine
import SwiftUI

/// First-launch backup mode selection + animated interactive tutorial shown once when
/// photoHub is first opened on a device (and replayable anytime from Settings).
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    var isReplay: Bool = false
    var onComplete: ((BackupStorageMode) -> Void)? = nil
    var onDismissReplay: (() -> Void)? = nil

    private enum Phase: Equatable {
        case chooseMode
        case tutorial
    }

    @State private var phase: Phase = .chooseMode
    @State private var selectedMode: BackupStorageMode?
    @State private var tutorialPage: Int = 0
    @State private var appeared: Bool = false

    init(
        settings: AppSettings,
        isReplay: Bool = false,
        onComplete: ((BackupStorageMode) -> Void)? = nil,
        onDismissReplay: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.isReplay = isReplay
        self.onComplete = onComplete
        self.onDismissReplay = onDismissReplay
        // On first install, leave nil so the user consciously chooses their preferred storage mode.
        _selectedMode = State(initialValue: isReplay ? settings.backupStorageMode : nil)
    }

    private var activeMode: BackupStorageMode {
        selectedMode ?? .optimizeStorage
    }

    private let totalTutorialPages = 4

    var body: some View {
        ZStack {
            PhotoHubPalette.sunriseBackdrop.ignoresSafeArea()
            OnboardingAmbientOrbs()

            Group {
                if phase == .chooseMode {
                    modeSelectionStage
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                } else {
                    tutorialStage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .animation(.spring(response: 0.48, dampingFraction: 0.84), value: phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }

    // MARK: - Stage 1: Choose Your Backup Mode

    private var modeSelectionStage: some View {
        VStack(spacing: 0) {
            if isReplay {
                HStack {
                    Spacer()
                    Button {
                        onDismissReplay?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(PhotoHubPalette.muted)
                            .frame(width: 34, height: 34)
                            .background(PhotoHubPalette.card.opacity(0.9), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        SunnyMascotView(
                            mood: selectedMode == nil ? .happy : .celebrate,
                            size: 108
                        )
                        .scaleEffect(appeared ? 1.0 : 0.84)
                        .opacity(appeared ? 1.0 : 0.0)

                        Text("Welcome to photoHub")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundColor(PhotoHubPalette.ink)
                            .multilineTextAlignment(.center)

                        Text("Choose how photoHub should handle photos & videos on this device.")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(PhotoHubPalette.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .padding(.top, isReplay ? 6 : 22)

                    VStack(spacing: 14) {
                        modeOptionCard(
                            mode: .optimizeStorage,
                            icon: "sparkles",
                            badgeText: "Save ~90% Space",
                            accent: PhotoHubPalette.orange,
                            bullets: [
                                ("icloud.and.arrow.up.fill", "Backs up full-resolution originals to your cloud"),
                                ("arrow.down.right.and.arrow.up.left", "Replaces originals on phone with tiny previews"),
                                ("square.and.arrow.up", "Share or restore full originals anytime"),
                            ]
                        )

                        modeOptionCard(
                            mode: .backupOnly,
                            icon: "checkmark.shield.fill",
                            badgeText: "Originals Untouched",
                            accent: PhotoHubPalette.mint,
                            bullets: [
                                ("icloud.and.arrow.up.fill", "Automatically backs up every photo & video"),
                                ("lock.shield.fill", "Never deletes or compresses photos on your phone"),
                                ("photo.on.rectangle.angled", "Ideal if you have plenty of phone storage"),
                            ]
                        )
                    }
                    .padding(.horizontal, 18)

                    Text("You can switch between modes anytime in Settings.")
                        .font(.caption.weight(.medium))
                        .foregroundColor(PhotoHubPalette.muted)
                        .padding(.bottom, 12)
                }
            }

            VStack(spacing: 10) {
                Button {
                    guard selectedMode != nil else { return }
                    tutorialPage = 0
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
                        phase = .tutorial
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedMode == nil ? "Choose an Option Above" : "Continue to Quick Tour")
                            .font(.headline.weight(.bold))
                        if selectedMode != nil {
                            Image(systemName: "arrow.right")
                                .font(.subheadline.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PhotoHubPrimaryButtonStyle())
                .disabled(selectedMode == nil)
                .opacity(selectedMode == nil ? 0.55 : 1.0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
    }

    @ViewBuilder
    private func modeOptionCard(
        mode: BackupStorageMode,
        icon: String,
        badgeText: String,
        accent: Color,
        bullets: [(String, String)]
    ) -> some View {
        let isSelected = selectedMode == mode

        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                selectedMode = mode
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent.opacity(isSelected ? 0.20 : 0.12))
                            .frame(width: 46, height: 46)
                        Image(systemName: icon)
                            .font(.title3.weight(.bold))
                            .foregroundColor(accent)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.title)
                            .font(.headline.weight(.heavy))
                            .foregroundColor(PhotoHubPalette.ink)
                        Text(badgeText)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(accent.opacity(0.13), in: Capsule())
                    }

                    Spacer()

                    ZStack {
                        Circle()
                            .stroke(isSelected ? accent : PhotoHubPalette.cardBorder, lineWidth: 2)
                            .frame(width: 26, height: 26)
                        if isSelected {
                            Circle()
                                .fill(accent)
                                .frame(width: 26, height: 26)
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.heavy))
                                .foregroundColor(.white)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<bullets.count, id: \.self) { idx in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: bullets[idx].0)
                                .font(.caption.weight(.bold))
                                .foregroundColor(accent)
                                .frame(width: 16)
                                .padding(.top, 2)
                            Text(bullets[idx].1)
                                .font(.caption.weight(.medium))
                                .foregroundColor(PhotoHubPalette.muted)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? accent : PhotoHubPalette.cardBorder, lineWidth: isSelected ? 2.4 : 1)
            )
            .shadow(
                color: isSelected ? accent.opacity(0.22) : Color.black.opacity(0.04),
                radius: isSelected ? 14 : 6,
                y: isSelected ? 6 : 2
            )
            .scaleEffect(isSelected ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stage 2: Animated Tutorial

    private var tutorialStage: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) {
                        phase = .chooseMode
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                        Text("Mode")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundColor(PhotoHubPalette.deepOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(PhotoHubPalette.softPeach, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                WarmStatPill(
                    icon: activeMode == .backupOnly ? "checkmark.shield.fill" : "sparkles",
                    text: activeMode.shortTitle,
                    tint: activeMode == .backupOnly ? PhotoHubPalette.mint : PhotoHubPalette.orange
                )

                Spacer()

                Button(tutorialPage < totalTutorialPages - 1 ? "Skip" : "Done") {
                    finishOnboarding()
                }
                .font(.subheadline.weight(.bold))
                .foregroundColor(PhotoHubPalette.muted)
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            TabView(selection: $tutorialPage) {
                tutorialSlideView(
                    tag: 0,
                    title: "Every Memory, Verified & Safe",
                    description: "Your photos and 4K videos upload safely to your private cloud with SHA-256 verification so nothing is ever lost."
                ) {
                    UploadFlowAnimationView()
                }

                if activeMode == .optimizeStorage {
                    tutorialSlideView(
                        tag: 1,
                        title: "Reclaim Up to 90% Space",
                        description: "Keep crisp lightweight previews in your native Photos app while full-resolution originals stay safely in your cloud."
                    ) {
                        OptimizeStorageAnimationView()
                    }
                } else {
                    tutorialSlideView(
                        tag: 1,
                        title: "Originals Stay Untouched",
                        description: "Backup Only never deletes, replaces, or compresses photos on your phone — your full-resolution library stays intact."
                    ) {
                        BackupOnlyAnimationView()
                    }
                }

                tutorialSlideView(
                    tag: 2,
                    title: activeMode == .optimizeStorage ? "Share Full Quality Anytime" : "Access & Share Anywhere",
                    description: activeMode == .optimizeStorage
                        ? "Tap Share Original to fetch the exact full-res master on demand, or restore your full library back to Photos anytime."
                        : "Browse your full timeline from any device or web browser, search instantly, and share expiring photo links in one tap."
                ) {
                    ShareAccessAnimationView(isBackupOnly: activeMode == .backupOnly)
                }

                readyCelebrationSlide
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.28), value: tutorialPage)

            // Animated page indicator pills + controls
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(0..<totalTutorialPages, id: \.self) { idx in
                        Capsule()
                            .fill(idx == tutorialPage ? PhotoHubPalette.orange : PhotoHubPalette.orange.opacity(0.24))
                            .frame(width: idx == tutorialPage ? 26 : 8, height: 8)
                            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: tutorialPage)
                    }
                }

                HStack(spacing: 12) {
                    if tutorialPage > 0 {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                tutorialPage -= 1
                            }
                        } label: {
                            Image(systemName: "arrow.left")
                                .font(.headline.weight(.bold))
                                .frame(width: 24)
                        }
                        .buttonStyle(PhotoHubSoftButtonStyle())
                    }

                    Button {
                        if tutorialPage < totalTutorialPages - 1 {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                tutorialPage += 1
                            }
                        } else {
                            finishOnboarding()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(tutorialPage < totalTutorialPages - 1 ? "Next" : (isReplay ? "Save & Close" : "Get Started"))
                                .font(.headline.weight(.bold))
                            Image(systemName: tutorialPage < totalTutorialPages - 1 ? "arrow.right" : "checkmark.circle.fill")
                                .font(.subheadline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PhotoHubPrimaryButtonStyle())
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func tutorialSlideView<Illustration: View>(
        tag: Int,
        title: String,
        description: String,
        @ViewBuilder illustration: () -> Illustration
    ) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)

            illustration()
                .frame(height: 250)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)

            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                    .foregroundColor(PhotoHubPalette.ink)
                    .multilineTextAlignment(.center)

                Text(description)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(PhotoHubPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 8)
        }
        .tag(tag)
    }

    private var readyCelebrationSlide: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [PhotoHubPalette.mint.opacity(0.22), Color.clear],
                            center: .center,
                            startRadius: 16,
                            endRadius: 120
                        )
                    )
                    .frame(width: 220, height: 220)
                SunnyMascotView(mood: .celebrate, size: 132)
            }
            .frame(height: 210)

            VStack(spacing: 10) {
                Text("You're All Set!")
                    .font(.system(size: 27, weight: .heavy, design: .rounded))
                    .foregroundColor(PhotoHubPalette.ink)

                Text(
                    activeMode == .backupOnly
                    ? "photoHub will quietly back up your photos & videos while keeping every original untouched on your phone."
                    : "photoHub will verify your cloud backups with SHA-256 and help you reclaim gigabytes on your phone."
                )
                .font(.subheadline.weight(.medium))
                .foregroundColor(PhotoHubPalette.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 26)
            }

            HStack(spacing: 10) {
                Image(systemName: activeMode == .backupOnly ? "checkmark.shield.fill" : "sparkles")
                    .font(.title3)
                    .foregroundColor(activeMode == .backupOnly ? PhotoHubPalette.mint : PhotoHubPalette.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected Mode")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(PhotoHubPalette.muted)
                    Text(activeMode.title)
                        .font(.subheadline.weight(.heavy))
                        .foregroundColor(PhotoHubPalette.ink)
                }
                Spacer()
                Button("Change") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) {
                        phase = .chooseMode
                    }
                }
                .font(.caption.weight(.bold))
                .foregroundColor(PhotoHubPalette.deepOrange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(PhotoHubPalette.softPeach, in: Capsule())
            }
            .padding(14)
            .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 26)

            Spacer(minLength: 8)
        }
    }

    private func finishOnboarding() {
        let chosen = activeMode
        settings.completeOnboarding(with: chosen)
        onComplete?(chosen)
        if isReplay {
            onDismissReplay?()
        }
    }
}

// MARK: - Ambient Animated Background Orbs

private struct OnboardingAmbientOrbs: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Circle()
                .fill(PhotoHubPalette.orange.opacity(0.11))
                .frame(width: 240, height: 240)
                .offset(x: drift ? -110 : -140, y: drift ? -240 : -280)
                .blur(radius: 18)

            Circle()
                .fill(PhotoHubPalette.warmAmber.opacity(0.11))
                .frame(width: 200, height: 200)
                .offset(x: drift ? 130 : 100, y: drift ? 210 : 250)
                .blur(radius: 16)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

// MARK: - Slide 1 Animation: Floating Photo Cards Uploading to Cloud

private struct UploadFlowAnimationView: View {
    @State private var pulse = false
    @State private var step = 0
    private let timer = Timer.publish(every: 1.35, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(PhotoHubPalette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                )
                .shadow(color: PhotoHubPalette.orange.opacity(0.10), radius: 14, y: 6)

            VStack(spacing: 0) {
                // Cloud target at top
                ZStack {
                    Circle()
                        .fill(PhotoHubPalette.orange.opacity(pulse ? 0.18 : 0.08))
                        .frame(width: 96, height: 96)
                        .scaleEffect(pulse ? 1.12 : 0.94)

                    Image(systemName: "cloud.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(PhotoHubPalette.orangeGradient)

                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(PhotoHubPalette.mint)
                        .padding(4)
                        .background(PhotoHubPalette.card, in: Circle())
                        .offset(x: 24, y: 16)
                        .scaleEffect(step % 2 == 0 ? 1.12 : 0.96)
                }
                .padding(.top, 16)

                // Rising photo cards beam
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [PhotoHubPalette.orange.opacity(0.45), PhotoHubPalette.warmAmber.opacity(0.12)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 6, height: 64)

                    ForEach(0..<3, id: \.self) { idx in
                        let active = (step + idx) % 3
                        let yOff: CGFloat = active == 0 ? 22 : (active == 1 ? 0 : -24)
                        let opacityVal: Double = active == 1 ? 1.0 : 0.45
                        let iconName = idx == 0 ? "photo.fill" : (idx == 1 ? "video.fill" : "sparkles")
                        let tint = idx == 0 ? PhotoHubPalette.orange : (idx == 1 ? PhotoHubPalette.coral : PhotoHubPalette.mint)

                        Image(systemName: iconName)
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .shadow(color: tint.opacity(0.35), radius: 5, y: 2)
                            .offset(x: CGFloat(idx - 1) * 34, y: yOff)
                            .opacity(opacityVal)
                            .animation(.spring(response: 0.65, dampingFraction: 0.78), value: step)
                    }
                }
                .frame(height: 76)

                // Phone source at bottom
                HStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .font(.title3.weight(.bold))
                        .foregroundColor(PhotoHubPalette.ink)
                    Text("SHA-256 Verified Upload")
                        .font(.caption.weight(.bold))
                        .foregroundColor(PhotoHubPalette.ink)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(PhotoHubPalette.softPeach, in: Capsule())
                .padding(.bottom, 18)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) {
                step = (step + 1) % 6
            }
        }
    }
}

// MARK: - Slide 2A Animation: Optimize Phone Storage (92% -> 12% Bar Shrink)

private struct OptimizeStorageAnimationView: View {
    @State private var optimized = false
    private let timer = Timer.publish(every: 2.3, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(PhotoHubPalette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                )
                .shadow(color: PhotoHubPalette.orange.opacity(0.10), radius: 14, y: 6)

            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    // Shrinking phone photo card
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(optimized ? PhotoHubPalette.mint.opacity(0.16) : PhotoHubPalette.orange.opacity(0.18))
                                .frame(width: optimized ? 58 : 78, height: optimized ? 58 : 78)
                            Image(systemName: optimized ? "photo" : "photo.fill")
                                .font(.system(size: optimized ? 24 : 34, weight: .bold))
                                .foregroundColor(optimized ? PhotoHubPalette.mint : PhotoHubPalette.orange)
                        }
                        .frame(width: 82, height: 82)
                        Text(optimized ? "Preview · 2 MB" : "Original · 48 MB")
                            .font(.caption2.weight(.heavy).monospacedDigit())
                            .foregroundColor(optimized ? PhotoHubPalette.mint : PhotoHubPalette.deepOrange)
                    }

                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.heavy))
                        .foregroundColor(PhotoHubPalette.orange)
                        .offset(x: optimized ? 4 : -4)

                    // Cloud full-res safe card
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(PhotoHubPalette.orangeGradient)
                                .frame(width: 78, height: 78)
                                .scaleEffect(optimized ? 1.06 : 0.94)
                            VStack(spacing: 2) {
                                Image(systemName: "cloud.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                Text("4K HD")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(width: 82, height: 82)
                        Text("Safe in Cloud")
                            .font(.caption2.weight(.heavy))
                            .foregroundColor(PhotoHubPalette.ink)
                    }
                }

                // Animated Phone Storage Bar
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("Phone Storage", systemImage: "iphone")
                            .font(.caption.weight(.bold))
                            .foregroundColor(PhotoHubPalette.ink)
                        Spacer()
                        Text(optimized ? "12% Used · ~90% Freed!" : "92% Full")
                            .font(.caption.weight(.heavy).monospacedDigit())
                            .foregroundColor(optimized ? PhotoHubPalette.mint : PhotoHubPalette.rose)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(PhotoHubPalette.softPeach)
                            Capsule()
                                .fill(optimized ? PhotoHubPalette.mint : PhotoHubPalette.rose)
                                .frame(width: max(22, geo.size.width * (optimized ? 0.14 : 0.92)))
                        }
                    }
                    .frame(height: 14)
                }
                .padding(.horizontal, 22)
            }
            .padding(.vertical, 16)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.spring(response: 0.75, dampingFraction: 0.78)) {
                    optimized = true
                }
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.spring(response: 0.75, dampingFraction: 0.78)) {
                optimized.toggle()
            }
        }
    }
}

// MARK: - Slide 2B Animation: Backup Only (Full Original Kept + Mirrored Cloud)

private struct BackupOnlyAnimationView: View {
    @State private var pulseStep = 0
    private let timer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(PhotoHubPalette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                )
                .shadow(color: PhotoHubPalette.mint.opacity(0.12), radius: 14, y: 6)

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    // Phone original card (untouched + green lock)
                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(PhotoHubPalette.mint.opacity(0.15))
                                .frame(width: 88, height: 88)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(PhotoHubPalette.mint, lineWidth: 2)
                                )
                            VStack(spacing: 3) {
                                Image(systemName: "photo.fill")
                                    .font(.title2)
                                    .foregroundColor(PhotoHubPalette.mint)
                                Text("100%")
                                    .font(.caption2.weight(.heavy))
                                    .foregroundColor(PhotoHubPalette.mint)
                            }
                            .frame(width: 88, height: 88)

                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.heavy))
                                .foregroundColor(.white)
                                .padding(5)
                                .background(PhotoHubPalette.mint, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                        Text("Phone Original")
                            .font(.caption.weight(.bold))
                            .foregroundColor(PhotoHubPalette.ink)
                    }

                    // Shimmering sync dots
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { idx in
                            Circle()
                                .fill(pulseStep % 3 == idx ? PhotoHubPalette.orange : PhotoHubPalette.orange.opacity(0.25))
                                .frame(width: pulseStep % 3 == idx ? 10 : 7, height: pulseStep % 3 == idx ? 10 : 7)
                                .animation(.easeInOut(duration: 0.35), value: pulseStep)
                        }
                    }

                    // Cloud mirrored copy card
                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(PhotoHubPalette.orangeGradient)
                                .frame(width: 88, height: 88)
                            VStack(spacing: 3) {
                                Image(systemName: "cloud.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                Text("BACKUP")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 88, height: 88)

                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.heavy))
                                .foregroundColor(.white)
                                .padding(5)
                                .background(PhotoHubPalette.mint, in: Circle())
                                .offset(x: 6, y: -6)
                                .scaleEffect(pulseStep % 3 == 2 ? 1.18 : 1.0)
                        }
                        Text("Cloud Copy")
                            .font(.caption.weight(.bold))
                            .foregroundColor(PhotoHubPalette.ink)
                    }
                }

                WarmStatPill(
                    icon: "checkmark.shield.fill",
                    text: "Zero Deletions · Full Resolution Kept",
                    tint: PhotoHubPalette.mint
                )
            }
            .padding(.vertical, 16)
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                pulseStep = (pulseStep + 1) % 3
            }
        }
    }
}

// MARK: - Slide 3 Animation: Instant Share & Multi-Device Access

private struct ShareAccessAnimationView: View {
    let isBackupOnly: Bool
    @State private var ripple = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(PhotoHubPalette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
                )
                .shadow(color: PhotoHubPalette.orange.opacity(0.10), radius: 14, y: 6)

            // Concentric warm share waves
            ForEach(0..<2, id: \.self) { idx in
                Circle()
                    .stroke(PhotoHubPalette.orange.opacity(ripple ? 0.04 : 0.26), lineWidth: 2)
                    .frame(width: CGFloat(110 + idx * 54), height: CGFloat(110 + idx * 54))
                    .scaleEffect(ripple ? 1.22 : 0.88)
            }

            // Center photo badge
            VStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(PhotoHubPalette.orangeGradient)
                Text("Original HD")
                    .font(.caption2.weight(.heavy))
                    .foregroundColor(PhotoHubPalette.ink)
            }
            .padding(14)
            .background(PhotoHubPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: PhotoHubPalette.orange.opacity(0.18), radius: 10, y: 4)

            // Floating feature chips around the center
            WarmStatPill(icon: "link", text: "Share Link", tint: PhotoHubPalette.orange)
                .offset(x: -74, y: -74 + (ripple ? -4 : 4))

            WarmStatPill(
                icon: isBackupOnly ? "globe" : "icloud.and.arrow.down",
                text: isBackupOnly ? "Web & Phone" : "Restore Anytime",
                tint: PhotoHubPalette.mint
            )
            .offset(x: 68, y: -68 + (ripple ? 4 : -4))

            WarmStatPill(icon: "magnifyingglass", text: "Smart Search", tint: PhotoHubPalette.warmAmber)
                .offset(x: 0, y: 84 + (ripple ? -3 : 3))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                ripple = true
            }
        }
    }
}
