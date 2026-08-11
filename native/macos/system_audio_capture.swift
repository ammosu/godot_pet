import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

private enum CaptureFailure: Error, CustomStringConvertible, LocalizedError {
    case badArguments
    case noDisplay
    case audioFormat
    case audioFile(OSStatus)

    var description: String {
        switch self {
        case .badArguments:
            return "usage: system_audio_capture <wav> <stop> <ready> <error> <sample-rate> <channels>"
        case .noDisplay:
            return "找不到可以擷取的顯示器。"
        case .audioFormat:
            return "系統音訊格式無法讀取。"
        case .audioFile(let status):
            return "系統音訊檔案無法建立或寫入（\(status)）。"
        }
    }

    var errorDescription: String? { description }
}

@available(macOS 13.0, *)
private final class SystemAudioWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputURL: URL
    private let sampleRate: Double
    private let channels: UInt32
    private let errorURL: URL
    private let lock = NSLock()
    private var audioFile: ExtAudioFileRef?
    private var stoppedError: Error?

    init(outputURL: URL, sampleRate: Double, channels: UInt32, errorURL: URL) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.channels = channels
        self.errorURL = errorURL
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        stoppedError = error
        lock.unlock()
        writeError(error.localizedDescription)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        lock.lock()
        defer { lock.unlock() }

        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let inputFormatPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            else { throw CaptureFailure.audioFormat }

            if audioFile == nil {
                try openFile(clientFormat: inputFormatPointer.pointee)
            }

            var requiredSize = 0
            var retainedBlock: CMBlockBuffer?
            let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &requiredSize,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retainedBlock
            )
            guard sizeStatus == noErr, requiredSize > 0 else {
                throw CaptureFailure.audioFile(sizeStatus)
            }

            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: requiredSize,
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { storage.deallocate() }
            let buffers = storage.bindMemory(to: AudioBufferList.self, capacity: 1)

            let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: buffers,
                bufferListSize: requiredSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retainedBlock
            )
            guard listStatus == noErr else { throw CaptureFailure.audioFile(listStatus) }

            let frames = UInt32(CMSampleBufferGetNumSamples(sampleBuffer))
            guard let file = audioFile else { throw CaptureFailure.audioFormat }
            let writeStatus = ExtAudioFileWrite(file, frames, buffers)
            guard writeStatus == noErr else { throw CaptureFailure.audioFile(writeStatus) }
        } catch {
            writeError(String(describing: error))
        }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        if let file = audioFile {
            let status = ExtAudioFileDispose(file)
            audioFile = nil
            if status != noErr { throw CaptureFailure.audioFile(status) }
        }
        if let error = stoppedError { throw error }
    }

    private func openFile(clientFormat: AudioStreamBasicDescription) throws {
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: channels * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * 2,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var file: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )
        guard status == noErr, let created = file else {
            throw CaptureFailure.audioFile(status)
        }

        var mutableClientFormat = clientFormat
        status = withUnsafePointer(to: &mutableClientFormat) {
            ExtAudioFileSetProperty(
                created,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                $0
            )
        }
        guard status == noErr else {
            ExtAudioFileDispose(created)
            throw CaptureFailure.audioFile(status)
        }
        audioFile = created
    }

    private func writeError(_ message: String) {
        try? message.write(to: errorURL, atomically: true, encoding: .utf8)
    }
}

@main
private struct SystemAudioCaptureMain {
    static func main() async {
        guard #available(macOS 13.0, *) else {
            fputs("System audio capture requires macOS 13 or later.\n", stderr)
            exit(2)
        }

        let arguments = CommandLine.arguments
        guard arguments.count == 7,
              let sampleRate = Double(arguments[5]),
              let channelCount = UInt32(arguments[6]) else {
            fputs("\(CaptureFailure.badArguments)\n", stderr)
            exit(2)
        }

        let outputURL = URL(fileURLWithPath: arguments[1])
        let stopURL = URL(fileURLWithPath: arguments[2])
        let readyURL = URL(fileURLWithPath: arguments[3])
        let errorURL = URL(fileURLWithPath: arguments[4])
        let fileManager = FileManager.default
        for marker in [stopURL, readyURL, errorURL] {
            try? fileManager.removeItem(at: marker)
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else { throw CaptureFailure.noDisplay }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(sampleRate)
            configuration.channelCount = Int(channelCount)
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3

            let writer = SystemAudioWriter(
                outputURL: outputURL,
                sampleRate: sampleRate,
                channels: channelCount,
                errorURL: errorURL
            )
            let stream = SCStream(filter: filter, configuration: configuration, delegate: writer)
            let queue = DispatchQueue(label: "net.anfusolutions.godotpet.system-audio")
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            try "ready".write(to: readyURL, atomically: true, encoding: .utf8)

            while !fileManager.fileExists(atPath: stopURL.path) {
                try await Task.sleep(for: .milliseconds(100))
            }

            try await stream.stopCapture()
            try await Task.sleep(for: .milliseconds(100))
            try writer.finish()
        } catch {
            let message = error.localizedDescription.isEmpty
                ? String(describing: error)
                : error.localizedDescription
            try? message.write(to: errorURL, atomically: true, encoding: .utf8)
            fputs("\(message)\n", stderr)
            exit(1)
        }
    }
}
