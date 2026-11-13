import CoreGraphics

/// EVERY number that shapes the blur around the open notch lives in this one file.
/// Change a number, press Cmd+R in Xcode, open the notch, look. Repeat until it looks right.
///
/// The blur is strongest right at the notch edge and fades out smoothly with distance.
/// It needs the Screen Recording permission (Settings > Privacy & Security > Screen Recording).
enum BlurTuning {

    // MARK: - 1. How blurry

    /// How blurry the picture is right next to the notch.
    /// 2 = barely blurred, 8 = soft, 14 = very blurry, 20 = frosted glass. Sensible range: 2 ... 20.
    static let blurAmount: CGFloat = 8

    // MARK: - 2. How far it spreads

    /// How far the blur reaches away from the notch (in points, roughly pixels on screen).
    /// 40 = tight halo, 90 = medium, 130 = widest allowed (the blur window is 130 big).
    static let reach: CGFloat = 90

    /// How the blur dies out with distance.
    /// 1.0 = even, straight fade. Higher (2.0, 3.0) = strong near the notch, gone quickly.
    /// Lower (0.7) = stays strong for longer, then drops near the end. Sensible range: 0.7 ... 3.
    static let softness: CGFloat = 1.5

    // MARK: - 3. How see-through the whole blur is

    /// Master strength of the blur layer. 1.0 = full, 0.5 = half-hidden, 0 = invisible.
    /// Lower this if the blur feels too heavy overall. Range: 0 ... 1.
    static let opacity: CGFloat = 1.0

    // MARK: - 4. Dark tint

    /// A soft black glow hugging the notch edge.
    /// 0 = none (pure blur), 0.15 = hint, 0.4 = clearly dark, 0.7 = very dark. Range: 0 ... 1.
    static let darkTint: CGFloat = 0.15

    /// How far the dark tint spreads away from the notch (points). Smaller than `reach` looks best.
    /// 20 = thin, 40 = medium, 80 = wide. Range: 10 ... 130.
    static let darkTintReach: CGFloat = 40

    // MARK: - 5. Dark layer over the whole blurred area

    /// A tiny dark see-through layer over the WHOLE blurred area, fading out together with the blur
    /// (so there is never a visible box edge). `darkTint` above only hugs the notch edge; this one
    /// covers everything the blur covers.
    /// 0 = off, 0.05 = tiny, 0.15 = noticeable, 0.3 = dark. Range: 0 ... 0.5.
    static let backgroundTintOpacity: CGFloat = 0.06
}
