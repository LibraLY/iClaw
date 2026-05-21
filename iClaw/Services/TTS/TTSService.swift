import Foundation
import AVFoundation
import nuisdk

/// TTS 服务 - 封装阿里云 CosyVoice SDK
final class TTSService: NSObject {
    /// 单例
    static let shared = TTSService()

    /// 当前配置
    private var currentConfig: TTSConfiguration?
    /// 是否正在播放
    private(set) var isPlaying: Bool = false
    /// 正在播放的消息 ID
    private(set) var currentPlayingMessageId: UUID?
    /// 会话 ID
    private var currentSessionId: String = ""

    // MARK: - 流式播放相关
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var isEngineRunning: Bool = false
    private var isDraining: Bool = false
    private var playingBufferCount: Int = 0
    private var synthesisStarted: Bool = false

    // MARK: - 流式 TTS 状态
    /// 是否正在流式合成中
    private(set) var isStreaming: Bool = false
    /// 流式合成已累积的文本
    private var streamingText: String = ""
    /// 流式 TTS 是否已启动
    private var streamStarted: Bool = false

    private override init() {
        super.init()
    }

    // MARK: - 流式合成接口

    /// 开始流式 TTS 合成
    /// - Parameters:
    ///   - config: TTS 配置
    ///   - deviceId: 设备 ID
    ///   - messageId: 消息 ID（用于跟踪）
    /// - Throws: TTSError
    func startStreaming(
        config: TTSConfiguration,
        deviceId: String,
        messageId: UUID? = nil
    ) async throws {
        guard config.isValid else {
            throw TTSError.invalidConfiguration
        }

        currentConfig = config
        isStreaming = true
        currentPlayingMessageId = messageId
        streamingText = ""
        streamStarted = false
        playingBufferCount = 0
        isDraining = false

        let effectiveSampleRate = 22050
        setupAudioEngine(sampleRate: effectiveSampleRate)

        let ticket = config.buildTicket(deviceId: deviceId)
        let parameters = buildStreamingParameters(config: config, sampleRate: effectiveSampleRate, format: "pcm")
        currentSessionId = UUID().uuidString

        guard let tts = StreamInputTts.get_instance() else {
            isStreaming = false
            throw TTSError.sdkError(code: -1)
        }
        tts.delegate = self

        let result = tts.start(
            ticket,
            parameters: parameters,
            sessionId: currentSessionId,
            logLevel: NUI_LOG_LEVEL_ERROR,
            saveLog: false
        )

        if result != SUCCESS {
            isStreaming = false
            throw TTSError.sdkError(code: Int(result))
        }

        streamStarted = true
    }

    func sendText(_ text: String) async throws {
        guard isStreaming else {
            throw TTSError.notStreaming
        }

        guard streamStarted else {
            return
        }

        guard let tts = StreamInputTts.get_instance() else {
            throw TTSError.sdkError(code: -1)
        }

        let result = tts.send(text)
        if result != SUCCESS {
            throw TTSError.sdkError(code: Int(result))
        }

        streamingText += text
    }

    func stopStreaming() async {
        guard isStreaming else {
            return
        }

        guard let tts = StreamInputTts.get_instance() else {
            isStreaming = false
            return
        }

        tts.asyncStop()
    }

    func cancelStreaming() async {
        guard isStreaming else {
            return
        }

        let tts = StreamInputTts.get_instance()
        tts?.cancel()

        isStreaming = false
        currentPlayingMessageId = nil
        streamingText = ""
        streamStarted = false
    }

    // MARK: - 通用控制

    func stop() {
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        audioEngine = nil
        playerNode = nil
        isEngineRunning = false

        let tts = StreamInputTts.get_instance()
        tts?.cancel()

        isPlaying = false
        isStreaming = false
        currentPlayingMessageId = nil
        streamingText = ""
        streamStarted = false
        synthesisStarted = false
    }

    private func setupAudioEngine(sampleRate: Int) {
        configureAudioSession()

        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        audioFormat = nil

        // 使用 VoiceProcessing 音频引擎进行播放
        // 这样可以在播放 TTS 时同时进行麦克风采集，并启用 AEC
        let vpEngine = VoiceProcessingAudioEngine.shared

        // 配置 VoiceProcessing 引擎
        if !vpEngine.isConfigured {
            guard vpEngine.configure() else {
                print("[TTS] Failed to configure VoiceProcessing engine")
                return
            }
        }

        // 启动引擎
        if !vpEngine.isRunning {
            guard vpEngine.start() else {
                print("[TTS] Failed to start VoiceProcessing engine")
                return
            }
        }

        // 存储格式信息用于后续转换
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            return
        }

        audioFormat = format

        print("[TTS] VoiceProcessing engine ready for playback")
    }

    private func startAudioEngine() throws {
        // 使用 VoiceProcessing 引擎进行播放
        let vpEngine = VoiceProcessingAudioEngine.shared
        guard vpEngine.isConfigured else {
            throw NSError(domain: "TTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "VoiceProcessing engine not configured"])
        }
        isEngineRunning = true
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        // 使用 .voiceChat 模式以启用 VoiceProcessing AEC
        try? audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker, .duckOthers])
        try? audioSession.setActive(true)
    }

    private func scheduleAudioData(_ data: Data) {
        guard let format = audioFormat else {
            return
        }

        // 使用 VoiceProcessing 引擎进行播放
        let vpEngine = VoiceProcessingAudioEngine.shared
        guard vpEngine.isConfigured else {
            print("[TTS] VoiceProcessing engine not configured")
            return
        }

        guard let pcmBuffer = createPCMBuffer(from: data, format: format) else {
            return
        }

        playingBufferCount += 1

        // 调度播放
        vpEngine.schedulePlayback(data: data) { [weak self] in
            DispatchQueue.main.async {
                self?.playingBufferCount -= 1
                self?.checkDrainAndCleanup()
            }
        }
    }

    private func checkDrainAndCleanup() {
        if isDraining && playingBufferCount == 0 {
            cleanup()
        }
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = format.channelCount
        let bytesPerFrame = 2 * Int(channels)
        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)

        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        data.withUnsafeBytes { ptr in
            guard let src = ptr.baseAddress else { return }
            guard let dest = buffer.int16ChannelData?[0] else { return }
            memcpy(dest, src, data.count)
        }
        buffer.frameLength = frameCount

        return buffer
    }

    private func onSynthesisComplete() {
        // 流式模式：标记为 draining，等待缓冲区播放完成
        isDraining = true
        checkDrainAndCleanup()
    }

    private func onSynthesisFailed(errorCode: Int, errorMessage: String) {
        cleanup()
    }

    private func cleanup() {
        // VoiceProcessing 引擎保持运行，不停止
        // (因为 ASR 可能还在使用)
        audioFormat = nil
        isEngineRunning = false
        isDraining = false
        playingBufferCount = 0

        isPlaying = false
        isStreaming = false
        currentPlayingMessageId = nil
        streamingText = ""
        streamStarted = false
        synthesisStarted = false

        print("[TTS] Cleanup complete")
    }

    private func buildStreamingParameters(config: TTSConfiguration, sampleRate: Int, format: String) -> String {
        var params: [String: Any] = [
            "model": config.model,
            "voice": config.voice,
            "format": format,
            "sample_rate": sampleRate,
            "volume": config.volume,
            "rate": config.rate,
            "pitch": config.pitch,
            "language_hints": config.languageHints
        ]

        if let instruction = config.instruction, !instruction.isEmpty {
            params["instruction"] = instruction
        }

        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

// MARK: - StreamInputTtsDelegate

extension TTSService: StreamInputTtsDelegate {
    func onStreamInputTtsEventCallback(
        _ event: StreamInputTtsCallbackEvent,
        taskId taskid: UnsafeMutablePointer<CChar>?,
        sessionId: UnsafeMutablePointer<CChar>?,
        ret_code: Int32,
        error_msg: UnsafeMutablePointer<CChar>?,
        timestamp: UnsafeMutablePointer<CChar>?,
        all_response: UnsafeMutablePointer<CChar>?
    ) {
        switch event {
        case TTS_EVENT_SYNTHESIS_STARTED:
            synthesisStarted = true

        case TTS_EVENT_SYNTHESIS_COMPLETE:
            onSynthesisComplete()

        case TTS_EVENT_TASK_FAILED:
            let errorMsg = error_msg.flatMap { String(cString: $0) } ?? "Unknown error"
            onSynthesisFailed(errorCode: Int(ret_code), errorMessage: errorMsg)

        default:
            break
        }
    }

    func onStreamInputTtsDataCallback(_ buffer: UnsafeMutablePointer<CChar>?, len: Int32) {
        guard let buffer = buffer, len > 0 else { return }
        let data = Data(bytes: buffer, count: Int(len))

        // 流式模式：直接调度播放
        if synthesisStarted {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleAudioData(data)
            }
        }
    }

    func onStreamInputTtsLogTrackCallback(_ level: NuiSdkLogLevel, logMessage: UnsafePointer<CChar>?) {
        guard let message = logMessage else { return }
        let log = String(cString: message)
        print("[TTS Log] \(log)")
    }
}

// MARK: - TTS Error

enum TTSError: LocalizedError {
    case invalidConfiguration
    case alreadyPlaying
    case notStreaming
    case sdkError(code: Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "TTS 配置无效，请检查 API Key 和音色设置"
        case .alreadyPlaying:
            return "正在播放中，请稍后重试"
        case .notStreaming:
            return "未处于流式合成状态"
        case .sdkError(let code):
            return sdkErrorMessage(for: code)
        }
    }

    private func sdkErrorMessage(for code: Int) -> String {
        switch code {
        case 141002:
            return "音色不可用或无权限使用 (错误码：\(code))"
        case 141001:
            return "API Key 无效或已过期 (错误码：\(code))"
        case 141003:
            return "模型不存在或无权限使用 (错误码：\(code))"
        default:
            return "SDK 错误 (代码：\(code))"
        }
    }
}
