import AppKit
#if !PETLAB
@testable import Nook
#endif

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
        var poses: [PetPose] = []
        for kind in PetDirector.Kind.allCases where kind != .stroll && kind != .home {
            // Every way the gesture can go (a glance to the right or left, a hunt that catches or misses, either way of facing).
            for pick in 0..<6 {
                var player = PetPlayer(layout: .compact, seed: 3 + pick * 17)
                for _ in 0..<pick { player.begin(.wave, layout: .compact(height: height)) }
                player.begin(kind, layout: .compact(height: height))
                var t = 0.0
                while player.director.running?.kind == kind, t < 120 {
                    poses.append(player.pose(now: 1000 + t, layout: .compact(height: height), motion: true, input: PetInput()))
                    t += step
                }
            }
        }
        for style in [PetCheer.hop, .doubleHop, .content] {
            for u in stride(from: 0, through: PetAnimation.cheerLength(style), by: step) { poses.append(PetAnimation.celebrate(u: u, time: u, style: style)) }
        }
        return poses
    }
}

extension PetSim {
    /// A seed for which `kind`, started first, goes the way asked: its variant (a glance to the right or left, a hunt that catches
    /// or misses, a groom of the paw or the chest) and, where it turns round, the side it faces.
    static func seed(for kind: PetDirector.Kind, layout: PetLayout = .compact, variant: Int? = nil, facing: CGFloat? = nil) -> Int {
        for seed in 0..<2000 {
            var director = PetDirector(layout: layout, seed: seed)
            director.start(kind, stage: layout == .compact ? .compact(height: 32) : .header(travel: 100))
            guard let r = director.running else { continue }
            if (variant == nil || r.variant == variant) && (facing == nil || r.facing == facing) { return seed }
        }
        return 0
    }

    /// The frames of one gesture started at once (every frame at `fps`, plus `extra` seconds of the cat settling afterwards), with
    /// the world asked for by `input`.
    static func gesture(_ kind: PetDirector.Kind, in stage: PetRender.Stage, variant: Int? = nil, facing: CGFloat? = nil, extra: Double = 1.2, fps: Double = PetRender.fps,
                        input: @escaping (Double) -> PetInput = { _ in PetInput(idle: 10) }) -> [PetPose] {
        let layout: PetLayout = stage.isHeader ? .header : .compact
        let chosen = seed(for: kind, layout: layout, variant: variant, facing: facing)
        var probe = PetDirector(layout: layout, seed: chosen)
        probe.start(kind, stage: stage.layout.stage)
        let seconds = (probe.running?.length ?? 5) + extra
        return run(stage.layout, seconds: seconds, fps: fps, seed: chosen, before: { $0.begin(kind, layout: stage.layout) }, input: input).map(\.pose)
    }
}
