import AVFoundation
import MediaToolbox

nonisolated private struct AudioEqualizerBiquadCoefficients {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    static let passthrough = AudioEqualizerBiquadCoefficients(
        b0: 1,
        b1: 0,
        b2: 0,
        a1: 0,
        a2: 0
    )

    static func peaking(
        centerFrequency: Double,
        gain: Float,
        sampleRate: Double
    ) -> AudioEqualizerBiquadCoefficients {
        guard sampleRate > 0,
              centerFrequency > 0,
              centerFrequency < sampleRate * 0.49,
              abs(gain) > 0.0001 else {
            return .passthrough
        }

        let amplitude = pow(10, Double(gain) / 40)
        let angularFrequency = 2 * Double.pi * centerFrequency / sampleRate
        let alpha = sin(angularFrequency) / (2 * 1.4)
        let cosine = cos(angularFrequency)
        let a0 = 1 + alpha / amplitude

        return AudioEqualizerBiquadCoefficients(
            b0: Float((1 + alpha * amplitude) / a0),
            b1: Float((-2 * cosine) / a0),
            b2: Float((1 - alpha * amplitude) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha / amplitude) / a0)
        )
    }
}

nonisolated private struct AudioEqualizerBiquadDelay {
    var first: Float = 0
    var second: Float = 0
}

nonisolated final class AudioEqualizerTapContext {
    private let centerFrequencies = AudioEqualizerBand.allCases.map(
        \.centerFrequency
    )

    private let sharedConfiguration: SharedAudioEqualizerConfiguration
    private let autoMixEqualizerState:
        SharedAutoMixEqualizerState
    private let spectrumAnalyzer:
        PlaybackAudioSpectrumAnalyzer
    private var sampleRate = 0.0
    private var channelCount = 0
    private var isSupportedFormat = false
    private var appliedRevision: UInt64?
    private var appliedAutoMixRevision: UInt64?
    private var isBypassed = true
    private var preampMultiplier: Float = 1
    private var coefficients = Array(
        repeating: AudioEqualizerBiquadCoefficients.passthrough,
        count: AudioEqualizerBand.count
    )
    private var delays: [AudioEqualizerBiquadDelay] = []

    init(
        sharedConfiguration:
            SharedAudioEqualizerConfiguration,
        autoMixEqualizerState:
            SharedAutoMixEqualizerState,
        sharedSpectrum: SharedPlaybackAudioSpectrum
    ) {
        self.sharedConfiguration = sharedConfiguration
        self.autoMixEqualizerState =
            autoMixEqualizerState
        spectrumAnalyzer = PlaybackAudioSpectrumAnalyzer(
            sharedSpectrum: sharedSpectrum
        )
    }

    func prepare(format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        channelCount = max(Int(format.mChannelsPerFrame), 1)
        isSupportedFormat = format.mFormatID == kAudioFormatLinearPCM
            && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        delays = Array(
            repeating: AudioEqualizerBiquadDelay(),
            count: channelCount * AudioEqualizerBand.count
        )
        spectrumAnalyzer.prepare(
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        appliedRevision = nil
        appliedAutoMixRevision = nil
        isBypassed = true
        refreshConfigurationIfNeeded()
    }

    func unprepare() {
        spectrumAnalyzer.reset()
        delays.removeAll(keepingCapacity: false)
        appliedRevision = nil
        appliedAutoMixRevision = nil
        isSupportedFormat = false
    }

    func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: CMItemCount,
        flags: MTAudioProcessingTapFlags
    ) {
        guard isSupportedFormat, frameCount > 0 else { return }

        if flags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
            resetDelays()
            spectrumAnalyzer.reset()
        }
        refreshConfigurationIfNeeded()
        spectrumAnalyzer.process(
            bufferList: bufferList,
            frameCount: Int(frameCount)
        )
        guard !isBypassed else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channelBase = 0

        for buffer in buffers {
            guard let data = buffer.mData else {
                channelBase += Int(buffer.mNumberChannels)
                continue
            }

            let channelsInBuffer = max(Int(buffer.mNumberChannels), 1)
            let availableSampleCount = Int(buffer.mDataByteSize)
                / MemoryLayout<Float>.stride
            let requestedSampleCount = Int(frameCount) * channelsInBuffer
            let sampleCount = min(availableSampleCount, requestedSampleCount)
            let samples = data.assumingMemoryBound(to: Float.self)

            if channelsInBuffer == 1 {
                processNoninterleaved(
                    samples: samples,
                    sampleCount: sampleCount,
                    channel: channelBase
                )
            } else {
                processInterleaved(
                    samples: samples,
                    sampleCount: sampleCount,
                    channelCount: channelsInBuffer,
                    channelBase: channelBase
                )
            }
            channelBase += channelsInBuffer
        }
    }

    private func refreshConfigurationIfNeeded() {
        let configuration = sharedConfiguration.snapshot()
        let autoMixAdjustment =
            autoMixEqualizerState.snapshot()
        guard appliedRevision
                != configuration.revision
                || appliedAutoMixRevision
                    != autoMixAdjustment.revision else {
            return
        }

        let wasBypassed = isBypassed
        appliedRevision = configuration.revision
        appliedAutoMixRevision =
            autoMixAdjustment.revision
        isBypassed =
            configuration.isBypassed
                && autoMixAdjustment.isFlat
        preampMultiplier = pow(
            10,
            (
                configuration.isEnabled
                ? configuration.preamp
                : 0
            ) / 20
        )

        for index in coefficients.indices {
            let userGain =
                configuration.isEnabled
                ? configuration.bandGains[index]
                : 0
            let autoMixGain =
                autoMixGain(
                    for:
                        centerFrequencies[index],
                    adjustment:
                        autoMixAdjustment
                )
            coefficients[index] = AudioEqualizerBiquadCoefficients.peaking(
                centerFrequency: centerFrequencies[index],
                gain:
                    min(
                        max(
                            userGain
                                + autoMixGain,
                            -24
                        ),
                        12
                    ),
                sampleRate: sampleRate
            )
        }

        if wasBypassed != isBypassed {
            resetDelays()
        }
    }

    private func autoMixGain(
        for centerFrequency: Double,
        adjustment:
            AutoMixEqualizerAdjustment
    ) -> Float {
        switch centerFrequency {
        case ...250:
            adjustment.lowGain
        case 250..<4_000:
            adjustment.midGain
        default:
            adjustment.highGain
        }
    }

    private func processNoninterleaved(
        samples: UnsafeMutablePointer<Float>,
        sampleCount: Int,
        channel: Int
    ) {
        guard channel < channelCount else { return }
        for sampleIndex in 0..<sampleCount {
            samples[sampleIndex] = process(
                sample: samples[sampleIndex],
                channel: channel
            )
        }
    }

    private func processInterleaved(
        samples: UnsafeMutablePointer<Float>,
        sampleCount: Int,
        channelCount: Int,
        channelBase: Int
    ) {
        guard channelCount > 0 else { return }
        let frameCount = sampleCount / channelCount
        for frameIndex in 0..<frameCount {
            for localChannel in 0..<channelCount {
                let channel = channelBase + localChannel
                guard channel < self.channelCount else { continue }
                let sampleIndex = frameIndex * channelCount + localChannel
                samples[sampleIndex] = process(
                    sample: samples[sampleIndex],
                    channel: channel
                )
            }
        }
    }

    private func process(sample: Float, channel: Int) -> Float {
        var output = sample * preampMultiplier
        let bandCount = AudioEqualizerBand.count
        let delayOffset = channel * bandCount

        for bandIndex in 0..<bandCount {
            let coefficient = coefficients[bandIndex]
            let delayIndex = delayOffset + bandIndex
            var delay = delays[delayIndex]
            let filtered = coefficient.b0 * output + delay.first
            delay.first = coefficient.b1 * output
                - coefficient.a1 * filtered
                + delay.second
            delay.second = coefficient.b2 * output
                - coefficient.a2 * filtered
            delays[delayIndex] = delay
            output = filtered
        }
        return output
    }

    private func resetDelays() {
        for index in delays.indices {
            delays[index] = AudioEqualizerBiquadDelay()
        }
    }
}
