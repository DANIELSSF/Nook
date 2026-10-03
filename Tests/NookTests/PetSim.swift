import AppKit
@testable import Nook

/// Runs the cat's player on simulated time and simulated state, so scheduling, priorities and interruptions can be
/// checked (and rendered) without a window, a display link or a real session.
enum PetSim {
    struct Frame {
        var t: Double
        var pose: PetPose
        var activity: PetDirector.Activity
        var running: PetDirector.Kind?
        var curious: Double
    }

    /// A pointer straight above-right of the cat's head, about 30 points away.
    static let pointer = PetGaze(dx: 0.8, dy: 0.2)

    /// `input` is asked for the state at each frame (time in seconds from 0). `before` can start a gesture at t 0.
    static func run(_ layout: PetPlayer.Layout, seconds: Double, fps: Double = 30, seed: Int = 1, start: Double = 1000,
                    before: ((inout PetPlayer) -> Void)? = nil, input: (Double) -> PetInput = { _ in PetInput() }) -> [Frame] {
        var player = PetPlayer(layout: { if case .compact = layout { return .compact } else { return .header } }(), seed: seed)
        before?(&player)
        var frames: [Frame] = []
        var t = 0.0
        while t <= seconds + 1e-9 {
            let pose = player.pose(now: start + t, layout: layout, motion: true, input: input(t))
            frames.append(Frame(t: t, pose: pose, activity: player.director.activity, running: player.director.running?.kind, curious: player.director.curious))
            t += 1 / fps
        }
        return frames
    }
}

extension PetSim {
    /// Poses from every moment of every gesture the collapsed cat can make, `step` seconds apart: whatever it might
    /// be doing when something happens to it.
    static func compactPoses(step: Double, height: CGFloat = 32) -> [PetPose] {
        let stage = PetStage.compact(height: height)
        var poses: [PetPose] = []
        for kind in PetDirector.Kind.allCases where kind != .stroll && kind != .home {
            var player = PetPlayer(layout: .compact, seed: 3)
            player.begin(kind, layout: .compact(height: height))
            var t = 0.0
            while let running = player.director.running, t < 120 {
                poses.append(player.pose(now: 1000 + t, layout: .compact(height: height), motion: true, input: PetInput()))
                _ = running
                t += step
            }
        }
        for u in stride(from: 0, through: PetAnimation.celebrateLength, by: step) { poses.append(PetAnimation.celebrate(u: u, time: u)) }
        _ = stage
        return poses
    }
}
