import AVFoundation
import Foundation

public enum AudioFileError: Error {
    case unreadable(URL)
}

/// Reads any CoreAudio-supported file (wav, caf, m4a, …) as 16 kHz mono Float32.
public enum AudioFile {
    public static func read16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                      interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length))
        else { throw AudioFileError.unreadable(url) }
        try file.read(into: inBuf)
        return try Resampler.convert(inBuf, to: dst)
    }
}

/// Converts PCM buffers to 16 kHz mono Float32.
public enum Resampler {
    public static func convert(_ buf: AVAudioPCMBuffer, to dst: AVAudioFormat) throws -> [Float] {
        if buf.format == dst, let ch = buf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        }
        guard let conv = AVAudioConverter(from: buf.format, to: dst) else { return [] }
        let ratio = dst.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let err { throw err }
        guard let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
