//
//  NotchShape.swift
//  boringNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    /// 0...1 magnetic pull toward the pointer along the bottom edge.
    private var magneticPull: CGFloat
    /// 0...1 horizontal anchor of the magnetic bulge across the island.
    private var magneticX: CGFloat
    /// Extra bottom canvas height reserved so the magnetic bulge can extend
    /// below the island's resting bottom edge without shifting its layout.
    private var bottomReserve: CGFloat

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil,
        magneticPull: CGFloat = 0,
        magneticX: CGFloat = 0.5,
        bottomReserve: CGFloat = 0
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
        self.magneticPull = magneticPull
        self.magneticX = magneticX
        self.bottomReserve = bottomReserve
    }

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            .init(
                .init(topCornerRadius, bottomCornerRadius),
                .init(magneticPull, magneticX)
            )
        }
        set {
            topCornerRadius = newValue.first.first
            bottomCornerRadius = newValue.first.second
            magneticPull = newValue.second.first
            magneticX = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let baseMaxY = rect.maxY - bottomReserve
        let xLeft = rect.minX + topCornerRadius
        let xRight = rect.maxX - topCornerRadius
        let leftFlat = xLeft + bottomCornerRadius
        let rightFlat = xRight - bottomCornerRadius

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: xLeft, y: rect.minY + topCornerRadius),
            control: CGPoint(x: xLeft, y: rect.minY)
        )

        let pull = min(max(magneticPull, 0), 1)
        let maxDepth = min(bottomReserve > 0 ? bottomReserve - 1.5 : 10, 9.5)
        let depth = (pull > 0.003 && (rightFlat - leftFlat) > 12) ? pull * maxDepth : 0

        if depth <= 0 {
            // Standard resting notch shape
            path.addLine(to: CGPoint(x: xLeft, y: baseMaxY - bottomCornerRadius))
            path.addQuadCurve(
                to: CGPoint(x: leftFlat, y: baseMaxY),
                control: CGPoint(x: xLeft, y: baseMaxY)
            )
            path.addLine(to: CGPoint(x: rightFlat, y: baseMaxY))
            path.addQuadCurve(
                to: CGPoint(x: xRight, y: baseMaxY - bottomCornerRadius),
                control: CGPoint(x: xRight, y: baseMaxY)
            )
        } else {
            // Smooth C-infinity Gaussian magnetic displacement across the entire
            // bottom contour (including the left and right rounded corners), so the
            // bulge reaches all the way to the corners without any sharp inflection.
            let bodyWidth = max(1, xRight - xLeft)
            let clampedMX = min(max(magneticX, 0), 1)
            let cx = xLeft + clampedMX * bodyWidth
            let sigma = max(26, min(38, bodyWidth * 0.22))
            let twoSigmaSq = 2 * sigma * sigma

            func displacedPoint(x: CGFloat, baseY: CGFloat, verticalWeight: CGFloat) -> CGPoint {
                let dx = x - cx
                let gauss = exp(-(dx * dx) / twoSigmaSq)
                return CGPoint(x: x, y: baseY + depth * verticalWeight * gauss)
            }

            // 1. Left vertical wall down to the start of the bottom-left corner
            let cornerStartY = baseMaxY - bottomCornerRadius
            path.addLine(to: CGPoint(x: xLeft, y: cornerStartY))

            // 2. Left bottom corner arc (theta: 0 -> pi/2)
            let cornerSteps = 16
            for i in 1...cornerSteps {
                let t = CGFloat(i) / CGFloat(cornerSteps)
                let theta = t * (.pi / 2)
                let x = leftFlat - bottomCornerRadius * cos(theta)
                let baseY = cornerStartY + bottomCornerRadius * sin(theta)
                // sin(theta)^1.5 smoothly ramps vertical displacement from 0 at the
                // vertical side wall to 1 along the corner bottom.
                let weight = pow(sin(theta), 1.5)
                path.addLine(to: displacedPoint(x: x, baseY: baseY, verticalWeight: weight))
            }

            // 3. Flat bottom span (leftFlat -> rightFlat)
            let flatSteps = 44
            for i in 1..<flatSteps {
                let t = CGFloat(i) / CGFloat(flatSteps)
                let x = leftFlat + t * (rightFlat - leftFlat)
                path.addLine(to: displacedPoint(x: x, baseY: baseMaxY, verticalWeight: 1.0))
            }

            // 4. Right bottom corner arc (theta: pi/2 -> 0)
            for i in 0...cornerSteps {
                let t = CGFloat(i) / CGFloat(cornerSteps)
                let theta = (1 - t) * (.pi / 2)
                let x = rightFlat + bottomCornerRadius * cos(theta)
                let baseY = cornerStartY + bottomCornerRadius * sin(theta)
                let weight = pow(sin(theta), 1.5)
                path.addLine(to: displacedPoint(x: x, baseY: baseY, verticalWeight: weight))
            }
        }

        path.addLine(to: CGPoint(x: xRight, y: rect.minY + topCornerRadius))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: xRight, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}

#Preview {
    NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        .frame(width: 200, height: 32)
        .padding(10)
}
