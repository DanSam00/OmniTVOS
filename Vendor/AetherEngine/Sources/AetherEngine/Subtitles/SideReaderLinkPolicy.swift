import Foundation

/// #240: who gets the source link when the video path and a subtitle side reader want it at once.
///
/// A subtitle side reader is a second, independent connection to the same origin, and on Matroska it
/// is a second full copy of the stream: `matroska_parse_cluster` reads every block off the wire and
/// only `matroska_parse_block` then honours `AVDISCARD_ALL`, so a "subtitle-only" reader still pulls
/// the video and audio bytes (see `reference` note in `AetherEngine+Subtitles`). A session with
/// subtitles on therefore asks the link for roughly twice the media rate. Above about 2x headroom
/// nobody notices. At 1.3x to 1.5x, which is an ordinary Wi-Fi bench in front of a high-bitrate
/// remux, the two readers split the link and the video path misses its deadlines: the reporter of
/// #240 measured the same segment taking 2.2 s alone and 7.5 s alongside the prefetcher, which
/// expired the seek landing budget and started a re-anchor cycle that fed itself (each re-anchor
/// jumps the clock, each clock jump rebuilds the prefetch session, each rebuild takes more link).
///
/// The arbitration is a strict priority, not a share: playback is load-bearing, subtitle lookahead
/// is not. The side reader fetches while the video path does not need the link, which on a fast link
/// is nearly always (the producer parks as soon as its forward buffer is full) and on a starved link
/// is the time between catch-up bursts. Two escapes keep it from being a mute switch: a grace window
/// after each anchor, so a freshly selected track fills even against a busy video path, and a
/// continuous-yield cap, so a video path that never parks (a wedged pump, a host that never reports
/// one) cannot silently disable subtitle lookahead for the rest of the session.
enum SideReaderLinkPolicy {

    /// How long a side reader may fetch unconditionally after it anchors or re-anchors, so the cues
    /// around the new position reach the store even while the video path is busy.
    ///
    /// This used to be a lead floor ("fetch while less than 5 s ahead of the playhead"), which is
    /// wrong in exactly the case the arbitration exists for. On a link that cannot carry two
    /// readers the side reader never gets ahead at all, so its lead stays negative, so the floor
    /// never expires: measured on a 1.4x bench, the reader took 47% of the link with the floor rule
    /// in force and the seek landings did not move. A grace window cannot get stuck that way, and
    /// it protects the case that actually needed protecting, which is the freshly selected track
    /// with nothing in the store yet, not steady-state lookahead.
    static let anchorGraceSeconds: Double = 8

    /// Forward buffer below which the consumer is treated as starving, and above which it is
    /// treated as recovered. Two values, because a single threshold flaps: the buffer crosses it
    /// on every catch-up burst, and a reader that resumes on each crossing keeps taking the link
    /// back from a pipeline that has not actually recovered yet.
    ///
    /// The floor matches `FrameExtractor.yieldMinForwardBufferSeconds`, which already yields
    /// elective thumbnail decodes on the same signal for the same reason.
    static let starvingBelowSeconds: Double = 3
    static let recoveredAtSeconds: Double = 6

    /// Longest continuous yield before the side reader takes the link anyway. Longer than the seek
    /// machinery's whole budget (8 s + 4x4 s extensions + re-anchor waits, #216), so a real seek
    /// never trips it and only a stuck signal does.
    static let maxYieldSeconds: Double = 60

    /// Whether the side reader must leave the link to the video path right now.
    ///
    /// Ordered so each rule is decidable on its own:
    /// 1. the cap fires first, because its whole purpose is to override a signal that is not clearing
    /// 2. a seek in flight yields unconditionally: the landing budget is what this exists to protect
    /// 3. a starving consumer yields unconditionally, ahead of the grace window — see below
    /// 4. inside its anchor grace the reader fetches, so a fresh selection is not left with an empty
    ///    store on a busy link
    /// 5. an actively fetching producer wins the link
    ///
    /// Rule 3 is deliberately above the grace window rather than below it. The grace exists so a
    /// freshly selected track can fill against a *busy* video path, and it assumes the link has
    /// room to spare for eight seconds. On a link with no headroom that assumption inverts: a
    /// starved session re-anchors, every re-anchor re-arms the grace, and the side reader spends
    /// most of the session inside an unconditional fetch window. Measured on a 17-track remux over
    /// a slow origin, the side reader pulled 31 MB against the video path's 8 MB in one 30 s
    /// window while the muxer produced nothing at all and the forward buffer sat at zero.
    ///
    /// Subtitles for video that has stopped playing are worth nothing, so the consumer's buffer
    /// outranks the grace. The cap still sits above this, so a stuck or absent buffer signal cannot
    /// mute lookahead for the rest of the session.
    static func shouldYield(
        seeking: Bool,
        videoProducing: Bool,
        starving: Bool,
        inAnchorGrace: Bool,
        yieldedSeconds: Double,
        maxYieldSeconds: Double = SideReaderLinkPolicy.maxYieldSeconds
    ) -> Bool {
        if yieldedSeconds >= maxYieldSeconds { return false }
        if seeking { return true }
        if starving { return true }
        if inAnchorGrace { return false }
        return videoProducing
    }
}

/// #240: the live view of what the video path is doing, shared with the side readers.
///
/// `videoProducing` is a count, not a flag: a producer restart overlaps an exiting pump with a
/// starting one, and a plain Bool would let the old pump's teardown clear the new pump's claim. Any
/// pull from the source counts, so the readers see "someone is fetching" rather than "producer N is".
final class SideReaderLinkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var seeking = false
    private var producingCount = 0
    private var starving = false

    init() {}

    /// The consumer's forward buffer, sampled at 1 Hz by `LiveTelemetrySampler`.
    ///
    /// `nil` means no reading is available (a path with no AVPlayer, or before the first sample).
    /// That is left as *not* starving on purpose: absent a signal the reader should behave exactly
    /// as it did before this rule existed, rather than being muted by a path that never reports.
    func setForwardBuffer(_ seconds: Double?) {
        guard let seconds else { return }
        lock.lock()
        if starving {
            if seconds >= SideReaderLinkPolicy.recoveredAtSeconds { starving = false }
        } else if seconds < SideReaderLinkPolicy.starvingBelowSeconds {
            starving = true
        }
        lock.unlock()
    }

    /// Wired to `AetherEngine.isSeeking` (programmatic + native scrub, both flags).
    func setSeeking(_ inFlight: Bool) {
        lock.lock()
        seeking = inFlight
        lock.unlock()
    }

    /// A pump started pulling from the source, or resumed after a park.
    func videoFetchBegan() {
        lock.lock()
        producingCount += 1
        lock.unlock()
    }

    /// A pump parked or exited. Balanced with `videoFetchBegan` at every call site.
    func videoFetchEnded() {
        lock.lock()
        producingCount = max(0, producingCount - 1)
        lock.unlock()
    }

    var state: (seeking: Bool, videoProducing: Bool, starving: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (seeking, producingCount > 0, starving)
    }
}

/// #240: the side reader's half of the arbitration, injectable so the loops stay testable.
///
/// Holds the state source plus the tuning, so a reader loop asks one question and the tests can
/// drive every rule without an engine, a producer or a network.
struct SideReaderLinkArbiter: Sendable {
    let state: @Sendable () -> (seeking: Bool, videoProducing: Bool, starving: Bool)
    var anchorGraceSeconds: Double = SideReaderLinkPolicy.anchorGraceSeconds
    var maxYieldSeconds: Double = SideReaderLinkPolicy.maxYieldSeconds
    /// How long the reader keeps the link once the cap has fired, before it starts asking again.
    /// Without a window the valve would be worthless: the cap is evaluated per loop iteration, so it
    /// would hand back one packet and yield for another full cap, which on a video path that never
    /// parks is indistinguishable from having no lookahead at all. A grant window turns it into a
    /// duty cycle (10 s of every 70), which is slow but alive.
    var valveGrantSeconds: Double = 10
    var pollNanoseconds: UInt64 = 250_000_000

    init(gate: SideReaderLinkGate) {
        self.state = { gate.state }
    }

    init(state: @escaping @Sendable () -> (seeking: Bool, videoProducing: Bool, starving: Bool)) {
        self.state = state
    }

    /// Whether the arbiter would hold a reader that has banked nothing yet. Used by the open path,
    /// which has no lead of its own: a session being built has read zero seconds ahead.
    func shouldDeferOpen() -> Bool {
        state().seeking
    }

    func shouldYield(inAnchorGrace: Bool, yieldedSeconds: Double) -> Bool {
        let now = state()
        return SideReaderLinkPolicy.shouldYield(
            seeking: now.seeking,
            videoProducing: now.videoProducing,
            starving: now.starving,
            inAnchorGrace: inAnchorGrace,
            yieldedSeconds: yieldedSeconds,
            maxYieldSeconds: maxYieldSeconds)
    }

    var pollSeconds: Double { Double(pollNanoseconds) / 1_000_000_000 }
}
