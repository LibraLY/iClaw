import Foundation
import AVFoundation

/// VoiceProcessing 音频引擎 - 使用 AVAudioEngine + VoiceProcessing 实现回声消除 (AEC)
///
/// 核心特性:
/// - 启用 VoiceProcessing 实现硬件级回声消除 (AEC)
/// - 同时支持音频输入 (麦克风) 和输出 (扬声器)
/// - 自动增益控制 (AGC) 和噪声抑制
/// - 与 ASR 和 TTS 服务无缝集成
///
/// 使用流程:
/// 1. 调用 configure() 配置音频会话和引擎
/// 2. 设置 inputHandler 接收麦克风数据 (用于 ASR)
/// 3. 设置 outputHandler 获取输出数据 (用于 TTS 播放)
/// 4. 调用 start() 启动引擎
/// 5. 调用 stop() 停止引擎
final class VoiceProcessingAudioEngine {

    // MARK: - 单例

    static let shared = VoiceProcessingAudioEngine()

    // MARK: - 属性

    /// 是否已配置
    private(set) var isConfigured: Bool = false

    /// 是否正在运行
    private(set) var isRunning: Bool = false

    /// 是否启用 VoiceProcessing (AEC)
    private(set) var isVoiceProcessingEnabled: Bool = false

    /// 是否静音 (麦克风输入)
    var isMuted: Bool = false {
        didSet {
            if isMuted != oldValue {
                print("[VoiceProcessingAudioEngine] Muted: \(isMuted)")
            }
        }
    }

    // MARK: - 音频引擎

    private let audioEngine = AVAudioEngine()

    /// 输入节点 (麦克风)
    private var inputNode: AVAudioInputNode { audioEngine.inputNode }

    /// 输出节点 (扬声器)
    private var outputNode: AVAudioOutputNode { audioEngine.outputNode }

    /// 主混音节点
    private var mainMixerNode: AVAudioMixerNode { audioEngine.mainMixerNode }

    // MARK: - 回调

    /// 输入音频数据回调 (用于 ASR)
    /// 参数：AVAudioPCMBuffer (16kHz, 单声道，16-bit PCM)
    var onInputData: ((AVAudioPCMBuffer) -> Void)?

    /// 输出音量控制 (0.0 - 1.0)
    var outputVolume: Float = 1.0 {
        didSet {
            mainMixerNode.outputVolume = outputVolume
        }
    }

    // MARK: - 音频格式

    /// 目标采样率 (ASR 需要 16kHz)
    private let targetSampleRate: Double = 16000

    /// 输入节点的原始格式
    private var inputFormat: AVAudioFormat?

    /// 转换后的格式 (16kHz, 单声道)
    private var outputFormat: AVAudioFormat?

    /// 音频转换器 (用于将输入转换为 16kHz)
    private var inputConverter: AVAudioConverter?

    // MARK: - 配置

    /// 配置音频会话和引擎
    /// - Returns: 是否配置成功
    @discardableResult
    func configure() -> Bool {
        guard !isConfigured else {
            print("[VoiceProcessingAudioEngine] Already configured")
            return true
        }

        // 1. 配置音频会话 - 使用 .voiceChat 模式启用 AEC
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,  // 关键：启用 VoiceProcessing 需要此模式
                options: [
                    .allowBluetooth,      // 允许蓝牙设备
                    .defaultToSpeaker,    // 默认使用扬声器
                    .allowBluetoothA2DP   // 允许蓝牙 A2DP (高质量音频)
                ]
            )
            try audioSession.setActive(true)

            // 设置首选采样率和缓冲区时长
            try audioSession.setPreferredSampleRate(targetSampleRate)
            try audioSession.setPreferredIOBufferDuration(0.01)  // 10ms 低延迟

            print("[VoiceProcessingAudioEngine] Audio session configured with mode: .voiceChat")
        } catch {
            print("[VoiceProcessingAudioEngine] Failed to configure audio session: \(error)")
            return false
        }

        // 2. 创建输出格式 (16kHz, 单声道, 16-bit PCM)
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        outputFormat = AVAudioFormat(streamDescription: &outputASBD)

        // 3. 准备音频转换器
        inputFormat = inputNode.inputFormat(forBus: 0)
        if let inputFormat = inputFormat, let outputFormat = outputFormat {
            inputConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
            print("[VoiceProcessingAudioEngine] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")
            print("[VoiceProcessingAudioEngine] Output format: \(outputFormat.sampleRate)Hz, \(outputFormat.channelCount) channels")
        }

        // 4. 安装输入 Tap (捕获麦克风数据)
        installInputTap()

        isConfigured = true
        print("[VoiceProcessingAudioEngine] Configured successfully")
        return true
    }

    // MARK: - 启动/停止

    /// 启动音频引擎
    /// - Returns: 是否启动成功
    @discardableResult
    func start() -> Bool {
        guard isConfigured else {
            print("[VoiceProcessingAudioEngine] Not configured, call configure() first")
            return false
        }

        guard !isRunning else {
            print("[VoiceProcessingAudioEngine] Already running")
            return true
        }

        do {
            // 1. 启用 VoiceProcessing (关键：必须同时启用输入和输出)
            try inputNode.setVoiceProcessingEnabled(true)
            try outputNode.setVoiceProcessingEnabled(true)
            isVoiceProcessingEnabled = true
            print("[VoiceProcessingAudioEngine] VoiceProcessing enabled (AEC active)")

            // 2. 准备并启动引擎
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
            print("[VoiceProcessingAudioEngine] Audio engine started")
            return true
        } catch {
            print("[VoiceProcessingAudioEngine] Failed to start: \(error)")
            isVoiceProcessingEnabled = false
            return false
        }
    }

    /// 停止音频引擎
    func stop() {
        guard isRunning else {
            return
        }

        audioEngine.stop()
        isRunning = false
        isVoiceProcessingEnabled = false

        print("[VoiceProcessingAudioEngine] Audio engine stopped")
    }

    /// 重置音频引擎 (用于重新配置)
    func reset() {
        stop()

        // 禁用 VoiceProcessing
        try? inputNode.setVoiceProcessingEnabled(false)
        try? outputNode.setVoiceProcessingEnabled(false)
        isVoiceProcessingEnabled = false

        // 移除输入 Tap
        inputNode.removeTap(onBus: 0)

        isConfigured = false
        print("[VoiceProcessingAudioEngine] Reset complete")
    }

    // MARK: - 输入处理

    /// 安装输入 Tap
    private func installInputTap() {
        guard let converter = inputConverter else {
            print("[VoiceProcessingAudioEngine] Converter not available")
            return
        }

        // 使用 nil 格式，让系统选择最佳格式
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
            guard let self = self else { return }
            guard !self.isMuted else { return }
            guard let onData = self.onInputData else { return }

            // 转换为 16kHz 单声道
            if let convertedBuffer = self.convert(buffer: buffer, using: converter) {
                onData(convertedBuffer)
            }
        }

        print("[VoiceProcessingAudioEngine] Input tap installed")
    }

    /// 转换音频格式
    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let inputSampleRate = buffer.format.sampleRate
        let targetSampleRate = self.targetSampleRate

        // 如果采样率已经是 16kHz 且是单声道，直接返回
        if abs(inputSampleRate - targetSampleRate) < 1.0 && buffer.format.channelCount == 1 {
            // 检查是否已经是 16-bit PCM
            if buffer.format.commonFormat == .pcmFormatInt16 {
                return buffer
            }
        }

        let outputFormat = converter.outputFormat
        let ratio = Float(targetSampleRate / inputSampleRate)
        let convertedFrameCount = AVAudioFrameCount(Float(buffer.frameLength) * ratio)

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: convertedFrameCount
        ) else {
            print("[VoiceProcessingAudioEngine] Failed to create converted buffer")
            return nil
        }

        // 转换
        var inputBlockIsRunning = true
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputBlockIsRunning {
                outStatus.pointee = .haveData
                inputBlockIsRunning = false
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error || error != nil {
            print("[VoiceProcessingAudioEngine] Audio conversion failed: \(error?.localizedDescription ?? "unknown error")")
            return nil
        }

        return convertedBuffer
    }

    // MARK: - 输出控制

    /// 调度音频数据播放 (用于 TTS)
    /// - Parameters:
    ///   - data: PCM 音频数据 (16-bit, 16kHz, 单声道)
    ///   - completion: 播放完成回调
    func schedulePlayback(data: Data, completion: (() -> Void)? = nil) {
        guard let format = outputFormat else {
            print("[VoiceProcessingAudioEngine] Output format not available")
            completion?()
            return
        }

        guard let buffer = createPCMBuffer(from: data, format: format) else {
            print("[VoiceProcessingAudioEngine] Failed to create PCM buffer")
            completion?()
            return
        }

        // 使用玩家节点调度播放
        let playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: mainMixerNode, format: format)

        playerNode.scheduleBuffer(buffer, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.audioEngine.detach(playerNode)
                completion?()
            }
        })

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// 创建 PCM 缓冲区
    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = format.channelCount
        let bytesPerFrame = 2 * Int(channels)  // 16-bit = 2 bytes
        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)

        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
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

    // MARK: - 状态检查

    /// 检查 VoiceProcessing 是否可用
    func checkVoiceProcessingAvailability() -> (available: Bool, message: String) {
        let audioSession = AVAudioSession.sharedInstance()

        // 检查当前模式
        if audioSession.mode != .voiceChat {
            return (false, "Audio session mode must be .voiceChat")
        }

        // 检查类别
        if audioSession.category != .playAndRecord {
            return (false, "Audio session category must be .playAndRecord")
        }

        return (true, "VoiceProcessing available")
    }

    deinit {
        stop()
        print("[VoiceProcessingAudioEngine] Deinitialized")
    }
}
