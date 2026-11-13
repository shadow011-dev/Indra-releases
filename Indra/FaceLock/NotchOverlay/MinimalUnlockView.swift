//
//  MinimalUnlockView.swift
//  Indra Face Lock
//
//  Layout: [ lock ][ gap ][ video ]. For `.notch` the gap is the physical
//  cutout (nothing may be drawn there); for `.pill` it's just negative space.

import SwiftUI

struct MinimalUnlockView: View {
    let media: ScanMedia
    /// Owned by the caller (not derived from `media`) so the glyph and video can be offset from each other.
    let isUnlocked: Bool
    /// Inset from the silhouette's left/right edges. The caller adds the
    /// notch's flare allowance into this where it applies.
    let edgeInset: CGFloat
    var lockIconSize: CGFloat = NotchGeometry.minimalLockIconSize
    var mediaWidth: CGFloat = NotchGeometry.minimalMediaWidth
    var mediaVerticalInset: CGFloat = NotchGeometry.minimalMediaVerticalInset
    /// Applied to the video only; defaults to identity so most callers can ignore it.
    var pulseScale: CGFloat = 1
    var pulseOpacity: Double = 1
    /// v485: false while the notch is closed / closing, true once it opens. The lock and the video glide out of the notch
    /// (the lock to the left, the video to the right) as the body widens, the lock first and the video a beat later.
    var revealed: Bool = true
    var travel: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: lockIconSize, weight: .semibold))
                .foregroundStyle(FaceLockTheme.textPrimary)
                // The explicit `.animation` below is required: the phase change that flips
                // `isUnlocked` isn't itself wrapped in an animation transaction.
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .animation(
                    .smooth(duration: NotchGeometry.minimalLockAnimationDuration),
                    value: isUnlocked
                )
                .frame(width: mediaWidth)
                .offset(x: revealed ? 0 : travel)
                .scaleEffect(revealed ? 1 : 0.5)
                .opacity(revealed ? 1 : 0)
                .animation(revealed ? NotchMotion.hudOpen.delay(0.05) : FaceScanMotion.contentOut, value: revealed)

            Spacer(minLength: 0)

            ScanAnimationView(media: media)
                .padding(.vertical, mediaVerticalInset)
                .frame(width: mediaWidth)
                // Scoped to the video alone — the lock icon on the left
                // must stay steady while this breathes.
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
                .offset(x: revealed ? 0 : -travel)
                .scaleEffect(revealed ? 1 : 0.5)
                .opacity(revealed ? 1 : 0)
                .animation(revealed ? NotchMotion.hudOpen.delay(0.14) : FaceScanMotion.contentOut, value: revealed)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, edgeInset)
    }
}
