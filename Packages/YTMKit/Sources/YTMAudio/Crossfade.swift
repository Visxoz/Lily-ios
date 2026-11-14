import Accelerate
import Foundation

/// Where a crossfade starts in the item fading out and how long it lasts,
/// worked out once both items' silences are known.
struct FadePlan {
    let from: Track
    let start: Int64
    let length: Int64
}

/// A crossfade under way: the item fading out, mixed under the start of the next.
struct Fade {
    let from: Track
    let length: Int64
    /// Frames mixed so far.
    var mixed: Int64 = 0

    var remaining: Int64 { length - mixed }
}

/// The sample arithmetic of fades, as ytm-native's `engine.rs`.
enum Crossfade {
    /// About -60 dBFS: quieter than this, a frame counts as silence.
    static let silence: Float = 0.001

    /// A stereo run of samples; a mono source gives the same channel twice.
    typealias Channels = (left: UnsafePointer<Float>, right: UnsafePointer<Float>)

    static func isSilent(_ channels: Channels, at frame: Int) -> Bool {
        abs(channels.left[frame]) < silence && abs(channels.right[frame]) < silence
    }

    /// Silent frames at the front of `count` frames.
    static func leadingSilence(_ channels: Channels, count: Int) -> Int {
        (0..<count).first { !isSilent(channels, at: $0) } ?? count
    }

    /// The frame after the last that is not silent among `count`, or 0.
    static func soundEnd(_ channels: Channels, count: Int) -> Int {
        ((0..<count).last { !isSilent(channels, at: $0) }).map { $0 + 1 } ?? 0
    }

    /// A gain running straight from one factor to another across a buffer,
    /// so a change of normalisation is heard as a glide, never a click.
    struct Ramp {
        let from: Float
        let to: Float
        /// The buffer's frames.
        let length: Int

        /// The gain at frame `frame` of the buffer.
        func at(_ frame: Int) -> Float {
            from + step * Float(min(frame, length))
        }

        var step: Float { (to - from) / Float(max(length, 1)) }
    }

    /// Writes `count` frames scaled by `gain` into `out` from `offset`, its frame of the ramp.
    static func copy(_ channels: Channels, gain: Ramp, count: Int, into out: UnsafePointer<UnsafeMutablePointer<Float>>, at offset: Int) {
        var step = gain.step
        // Each call moves `start` on, so it is set afresh for the second channel.
        var start = gain.at(offset)
        vDSP_vrampmul(channels.left, 1, &start, &step, out[0] + offset, 1, vDSP_Length(count))
        start = gain.at(offset)
        vDSP_vrampmul(channels.right, 1, &start, &step, out[1] + offset, 1, vDSP_Length(count))
    }

    /// Mixes `count` frames of the item fading out under the one fading in,
    /// frame `at` of a fade `length` frames long, into `out` from `offset`,
    /// its frame of each side's ramp.
    /// Equal-power curves keep the loudness steady through the overlap,
    /// where linear ones dip midway. Either side may have ended, and is silence.
    static func mix(
        incoming: (channels: Channels, gain: Ramp)?,
        outgoing: (channels: Channels, gain: Ramp)?,
        count: Int,
        at position: Int64,
        of length: Int64,
        into out: UnsafePointer<UnsafeMutablePointer<Float>>,
        offset: Int
    ) {
        for frame in 0..<count {
            let angle = Double(position + Int64(frame)) / Double(max(length, 1)) * .pi / 2
            let fadeIn = Float(sin(angle))
            let fadeOut = Float(cos(angle))
            var left: Float = 0
            var right: Float = 0
            if let incoming {
                let gain = incoming.gain.at(offset + frame) * fadeIn
                left += incoming.channels.left[frame] * gain
                right += incoming.channels.right[frame] * gain
            }
            if let outgoing {
                let gain = outgoing.gain.at(offset + frame) * fadeOut
                left += outgoing.channels.left[frame] * gain
                right += outgoing.channels.right[frame] * gain
            }
            out[0][offset + frame] = left
            out[1][offset + frame] = right
        }
    }

    /// Fades the first frames of a buffer in from silence, as the sound
    /// after a start, seek or stall would otherwise step in and click.
    static func fadeIn(_ out: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int, over length: Int) {
        let frames = min(count, length)
        for frame in 0..<frames {
            let gain = Float(frame + 1) / Float(length)
            out[0][frame] *= gain
            out[1][frame] *= gain
        }
    }
}
