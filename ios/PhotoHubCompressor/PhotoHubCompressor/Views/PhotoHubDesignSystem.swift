import SwiftUI
import UIKit

// MARK: - Warm Sunset Orange & Comfortable Cream/Espresso Palette

enum PhotoHubPalette {
    static let orange = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.984, green: 0.573, blue: 0.235, alpha: 1.0) // #FB923C
            : UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1.0) // #F97316
    })

    static let deepOrange = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1.0) // #F97316
            : UIColor(red: 0.918, green: 0.345, blue: 0.047, alpha: 1.0) // #EA580C
    })

    static let warmAmber = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.984, green: 0.749, blue: 0.141, alpha: 1.0) // #FBBF24
            : UIColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1.0) // #F59E0B
    })

    static let coral = Color(red: 1.0, green: 0.525, blue: 0.369) // #FF865E

    static let mint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 1.0) // #34D399
            : UIColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 1.0) // #10B981
    })

    static let rose = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.973, green: 0.443, blue: 0.443, alpha: 1.0) // #F87171
            : UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1.0) // #EF4444
    })

    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.078, green: 0.063, blue: 0.055, alpha: 1.0) // #14100E warm espresso
            : UIColor(red: 1.000, green: 0.976, blue: 0.961, alpha: 1.0) // #FFF9F5 warm cream
    })

    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.129, green: 0.102, blue: 0.086, alpha: 1.0) // #211A16 warm cocoa
            : UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0)
    })

    static let softPeach = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.180, green: 0.137, blue: 0.114, alpha: 1.0) // #2E231D
            : UIColor(red: 1.000, green: 0.941, blue: 0.898, alpha: 1.0) // #FFF0E5
    })

    static let cardBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.255, green: 0.196, blue: 0.165, alpha: 0.9)
            : UIColor(red: 0.976, green: 0.847, blue: 0.757, alpha: 0.9)
    })

    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.000, green: 0.969, blue: 0.941, alpha: 1.0)
            : UIColor(red: 0.149, green: 0.110, blue: 0.082, alpha: 1.0) // #261C15
    })

    static let muted = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.722, green: 0.643, blue: 0.596, alpha: 1.0)
            : UIColor(red: 0.549, green: 0.455, blue: 0.400, alpha: 1.0) // #8C7466
    })

    static var orangeGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 1.0, green: 0.62, blue: 0.27), orange, deepOrange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var sunriseBackdrop: LinearGradient {
        LinearGradient(
            colors: [softPeach.opacity(0.85), canvas],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Cute Animated Cartoon Figure ("Sunny" the Orange Cloud-Camera Buddy)

enum MascotMood: Equatable {
    case happy
    case uploading
    case celebrate
    case sleeping
    case alert
}

struct SunnyMascotView: View {
    let mood: MascotMood
    var size: CGFloat = 110

    @State private var floatOffset: CGFloat = 0
    @State private var pulseScale: CGFloat = 0.94
    @State private var waveAngle: Double = -10
    @State private var sparklePhase: Double = 0
    @State private var isBlinking: Bool = false

    private var haloColor: Color {
        switch mood {
        case .happy: return PhotoHubPalette.orange
        case .uploading: return PhotoHubPalette.warmAmber
        case .celebrate: return PhotoHubPalette.mint
        case .sleeping: return PhotoHubPalette.coral
        case .alert: return PhotoHubPalette.warmAmber
        }
    }

    var body: some View {
        ZStack {
            // Soft warm pulsing halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [haloColor.opacity(0.28), haloColor.opacity(0.0)],
                        center: .center,
                        startRadius: size * 0.10,
                        endRadius: size * 0.56
                    )
                )
                .frame(width: size * 1.18, height: size * 1.18)
                .scaleEffect(pulseScale)

            // Mood floating particles (sparkles / upload arrows / zZ)
            moodDecorations

            // Soft cream cloud cushion under Sunny
            cloudBase
                .offset(y: size * 0.34)

            // Main cartoon body (floats gently)
            ZStack {
                // Left paw
                Capsule()
                    .fill(PhotoHubPalette.deepOrange)
                    .frame(width: size * 0.14, height: size * 0.24)
                    .rotationEffect(.degrees(mood == .celebrate ? 38 : 22))
                    .offset(x: -size * 0.37, y: size * 0.06)

                // Right waving paw
                Capsule()
                    .fill(PhotoHubPalette.deepOrange)
                    .frame(width: size * 0.14, height: size * 0.24)
                    .rotationEffect(.degrees(mood == .celebrate ? -42 : waveAngle))
                    .offset(x: size * 0.37, y: mood == .celebrate ? -size * 0.04 : size * 0.02)

                // Camera top viewfinder hump + golden shutter button
                HStack(spacing: size * 0.09) {
                    RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                        .fill(PhotoHubPalette.warmAmber)
                        .frame(width: size * 0.14, height: size * 0.09)
                        .offset(y: size * 0.02)
                    RoundedRectangle(cornerRadius: size * 0.11, style: .continuous)
                        .fill(PhotoHubPalette.orange)
                        .frame(width: size * 0.28, height: size * 0.16)
                }
                .offset(x: -size * 0.05, y: -size * 0.30)

                // Plump rounded tangerine camera-buddy body
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.70, blue: 0.36),
                                Color(red: 0.98, green: 0.48, blue: 0.14),
                                Color(red: 0.92, green: 0.35, blue: 0.07)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size * 0.72, height: size * 0.60)
                    .shadow(color: PhotoHubPalette.orange.opacity(0.28), radius: size * 0.08, y: size * 0.05)

                // Soft glossy top-left highlight
                Ellipse()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: size * 0.34, height: size * 0.12)
                    .rotationEffect(.degrees(-14))
                    .offset(x: -size * 0.11, y: -size * 0.18)

                // Cute face screen patch (soft warm cream face)
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.96, blue: 0.91))
                    .frame(width: size * 0.54, height: size * 0.38)
                    .offset(y: size * 0.03)

                // Face features: cheeks, eyes, mouth
                faceView
                    .offset(y: size * 0.03)
            }
            .offset(y: floatOffset)
        }
        .frame(width: size * 1.15, height: size * 1.05)
        .onAppear {
            startAnimations()
        }
        .onChange(of: mood) { _ in
            startAnimations()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                guard !Task.isCancelled else { break }
                if mood == .happy || mood == .uploading {
                    withAnimation(.easeInOut(duration: 0.10)) { isBlinking = true }
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    withAnimation(.easeInOut(duration: 0.12)) { isBlinking = false }
                }
            }
        }
    }

    @ViewBuilder
    private var cloudBase: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: size * 0.74, height: size * 0.22)
            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: size * 0.26, height: size * 0.26)
                .offset(x: -size * 0.20, y: -size * 0.04)
            Circle()
                .fill(Color.white.opacity(0.98))
                .frame(width: size * 0.30, height: size * 0.30)
                .offset(x: size * 0.04, y: -size * 0.07)
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(x: size * 0.24, y: -size * 0.02)
        }
        .shadow(color: PhotoHubPalette.orange.opacity(0.14), radius: size * 0.06, y: size * 0.03)
    }

    @ViewBuilder
    private var faceView: some View {
        let eyeSize = size * 0.095
        let espresso = Color(red: 0.19, green: 0.13, blue: 0.09)

        ZStack {
            // Rosy cheeks
            HStack(spacing: size * 0.26) {
                Ellipse()
                    .fill(Color(red: 1.0, green: 0.50, blue: 0.44).opacity(0.45))
                    .frame(width: size * 0.10, height: size * 0.06)
                Ellipse()
                    .fill(Color(red: 1.0, green: 0.50, blue: 0.44).opacity(0.45))
                    .frame(width: size * 0.10, height: size * 0.06)
            }
            .offset(y: size * 0.045)

            // Eyes
            HStack(spacing: size * 0.15) {
                eyeShape(size: eyeSize, color: espresso)
                eyeShape(size: eyeSize, color: espresso)
            }
            .offset(y: -size * 0.03)

            // Mouth
            mouthShape(color: espresso)
                .offset(y: size * 0.075)
        }
    }

    @ViewBuilder
    private func eyeShape(size eyeSize: CGFloat, color: Color) -> some View {
        switch mood {
        case .celebrate:
            HappyArcShape()
                .stroke(color, style: StrokeStyle(lineWidth: max(2, eyeSize * 0.28), lineCap: .round))
                .frame(width: eyeSize * 1.15, height: eyeSize * 0.65)
        case .sleeping:
            SmileArcShape()
                .stroke(color, style: StrokeStyle(lineWidth: max(1.8, eyeSize * 0.24), lineCap: .round))
                .frame(width: eyeSize * 1.1, height: eyeSize * 0.50)
        default:
            if isBlinking {
                Capsule()
                    .fill(color)
                    .frame(width: eyeSize * 1.05, height: max(2, eyeSize * 0.24))
            } else {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(color)
                        .frame(width: eyeSize, height: eyeSize)
                    Circle()
                        .fill(Color.white)
                        .frame(width: eyeSize * 0.36, height: eyeSize * 0.36)
                        .offset(x: -eyeSize * 0.14, y: eyeSize * 0.14)
                }
            }
        }
    }

    @ViewBuilder
    private func mouthShape(color: Color) -> some View {
        switch mood {
        case .alert:
            Circle()
                .stroke(color, lineWidth: max(1.8, size * 0.022))
                .frame(width: size * 0.08, height: size * 0.08)
        case .sleeping:
            Capsule()
                .fill(color.opacity(0.7))
                .frame(width: size * 0.08, height: max(2, size * 0.022))
        default:
            SmileArcShape()
                .stroke(color, style: StrokeStyle(lineWidth: max(2, size * 0.026), lineCap: .round))
                .frame(width: size * 0.14, height: size * 0.07)
        }
    }

    @ViewBuilder
    private var moodDecorations: some View {
        switch mood {
        case .uploading:
            ZStack {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: size * 0.18, weight: .bold))
                    .foregroundColor(PhotoHubPalette.orange)
                    .offset(x: size * 0.42, y: -size * 0.34 - CGFloat(sparklePhase * 8))
                    .opacity(0.95)
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.14, weight: .bold))
                    .foregroundColor(PhotoHubPalette.warmAmber)
                    .offset(x: -size * 0.44, y: -size * 0.24 + CGFloat(sparklePhase * 5))
            }
        case .celebrate:
            ZStack {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.18, weight: .bold))
                    .foregroundColor(PhotoHubPalette.warmAmber)
                    .offset(x: -size * 0.44, y: -size * 0.32 - CGFloat(sparklePhase * 5))
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.19, weight: .bold))
                    .foregroundColor(PhotoHubPalette.mint)
                    .offset(x: size * 0.44, y: -size * 0.30 - CGFloat(sparklePhase * 4))
            }
        case .sleeping:
            Text("zZ")
                .font(.system(size: size * 0.17, weight: .heavy, design: .rounded))
                .foregroundColor(PhotoHubPalette.orange.opacity(0.75))
                .offset(x: size * 0.38, y: -size * 0.34 - CGFloat(sparklePhase * 6))
        case .alert:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: size * 0.20, weight: .bold))
                .foregroundColor(PhotoHubPalette.warmAmber)
                .offset(x: size * 0.42, y: -size * 0.32)
        case .happy:
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.14, weight: .bold))
                .foregroundColor(PhotoHubPalette.warmAmber.opacity(0.85))
                .offset(x: size * 0.44, y: -size * 0.32 - CGFloat(sparklePhase * 4))
        }
    }

    private func startAnimations() {
        let bobAmount: CGFloat = (mood == .uploading || mood == .celebrate) ? -size * 0.065 : -size * 0.04
        let bobDuration: Double = (mood == .uploading || mood == .celebrate) ? 0.65 : 1.5

        floatOffset = 0
        withAnimation(.easeInOut(duration: bobDuration).repeatForever(autoreverses: true)) {
            floatOffset = bobAmount
        }

        pulseScale = 0.94
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            pulseScale = 1.07
        }

        waveAngle = -14
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            waveAngle = -34
        }

        sparklePhase = 0
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            sparklePhase = 1
        }
    }
}

private struct SmileArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY * 1.25)
        )
        return path
    }
}

private struct HappyArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.35)
        )
        return path
    }
}

// MARK: - Minimal Animated Reusable Controls

struct PhotoHubPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(PhotoHubPalette.orangeGradient, in: Capsule())
            .shadow(color: PhotoHubPalette.orange.opacity(configuration.isPressed ? 0.14 : 0.30), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct PhotoHubSoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(PhotoHubPalette.deepOrange)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(PhotoHubPalette.softPeach, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(PhotoHubPalette.cardBorder, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct AnimatedPulseDot: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.32))
                .frame(width: 14, height: 14)
                .scaleEffect(expanded ? 1.35 : 0.75)
                .opacity(expanded ? 0.1 : 0.75)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
    }
}

struct WarmStatPill: View {
    let icon: String
    let text: String
    var tint: Color = PhotoHubPalette.orange

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

// MARK: - Animated Warm Shimmer & Cloud Skeleton (Matched to Webpage UI)

struct WarmShimmerView: View {
    var cornerRadius: CGFloat = 12
    @State private var phase: CGFloat = -1.0

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(PhotoHubPalette.softPeach)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            PhotoHubPalette.orange.opacity(0.14),
                            Color.white.opacity(0.28),
                            PhotoHubPalette.orange.opacity(0.10),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 1.4)
                    .offset(x: phase * width * 1.4)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }
}

struct CloudLoadingSkeletonView: View {
    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 10) {
                    SunnyMascotView(mood: .uploading, size: 92)
                    Text("Waking up your cloud…")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(PhotoHubPalette.ink)
                    Capsule()
                        .fill(PhotoHubPalette.softPeach)
                        .frame(width: 148, height: 5)
                        .overlay(
                            WarmShimmerView(cornerRadius: 99)
                                .frame(height: 5)
                        )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                WarmShimmerView(cornerRadius: 8)
                    .frame(width: 132, height: 18)

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(0..<12, id: \.self) { _ in
                        WarmShimmerView(cornerRadius: 12)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}
