import Foundation
import AVFoundation
import nuisdk

/// ASR 识别结果回调
enum AsrResultType {
    case partial(String)      // 中间识别结果
    case sentence(String)     // 完整句子
    case error(String, Int)   // 错误信息和错误码
    case started              // 识别已启动
    case completed            // 识别完成
}

/// ASR 服务回调
typealias AsrResultHandler = (AsrResultType) -> Void

/// 阿里云 Fun-ASR 实时语音识别服务
final class AsrService: NSObject {

    /// 单例
    static let shared = AsrService()

    /// 结果回调
    var onResult: AsrResultHandler?

    /// 是否正在识别
    private(set) var isRecognizing: Bool = false

    /// 是否已初始化
    private(set) var isInitialized: Bool = false

    /// API Key
    private var apiKey: String = ""

    /// 设备 ID
    private var deviceId: String = ""

    /// 当前会话 ID
    private var currentSessionId: String = ""

    /// 是否静音
    private var isMuted: Bool = false

    /// 音频数据缓冲区 - 用于在 onNuiNeedAudioData 回调中提供数据
    private var audioDataBuffer: Data = Data()
    private var audioDataBufferLock = NSLock()

    /// VoiceProcessing 音频引擎引用 (外部管理 AEC)
    weak var voiceProcessingEngine: VoiceProcessingAudioEngine?

    /// 空计数计数器 - 用于检测音频数据是否持续为空
    private var emptyCount: Int = 0

    private override init() {
        super.init()
    }

    deinit {
        stop()
    }

    // MARK: - 初始化

    /// 初始化 ASR SDK
    /// - Parameters:
    ///   - apiKey: API Key（推荐从服务端获取临时 Token，有效期 60-1800 秒）
    ///   - deviceId: 设备 ID（用于标识用户）
    ///   - url: WebSocket URL（默认：wss://dashscope.aliyuncs.com/api-ws/v1/inference）
    func initialize(apiKey: String, deviceId: String, url: String = "wss://dashscope.aliyuncs.com/api-ws/v1/inference") {
        guard !isInitialized else {
            print("[ASR] Already initialized")
            return
        }

        self.apiKey = apiKey
        self.deviceId = deviceId

        // 构建初始化参数 - 完全对齐 DashFunAsrSpeechTranscriberViewController.genInitParams()
        // 注意：apikey 不在此处设置，在 start() 时通过 dialogParam 传入（支持临时 Token 刷新）
        let params = """
        {
            "url": "\(url)",
            "device_id": "\(deviceId)",
            "service_mode": "1",
            "save_wav": "false",
            "log_track_level": "0",
            "max_log_file_size": 52428800
        }
        """

        guard let nui = NeoNui.get_instance() else {
            print("[ASR] Failed to get NeoNui instance")
            return
        }

        nui.delegate = self

        // 使用 NUI_LOG_LEVEL_DEBUG 以便调试
        let result = nui.nui_initialize(
            params,
            logLevel: NUI_LOG_LEVEL_DEBUG,
            saveLog: false
        )

        if result == SUCCESS {
            isInitialized = true
            print("[ASR] Initialized successfully")
        } else {
            print("[ASR] Initialize failed with code: \(result)")
        }
    }

    // MARK: - 参数设置

    /// 设置 ASR 识别参数
    /// - Parameters:
    ///   - model: 模型名称（默认：fun-asr-realtime）
    ///   - language: 语言代码（默认：["zh"]）
    ///   - sampleRate: 采样率（默认：16000，只支持 16000Hz）
    ///   - format: 音频格式（默认：pcm，注意：opus 表示将用户送入的 pcm 数据压缩成 opus 数据进行传输）
    ///   - semanticPunctuationEnabled: 是否启用语义断句（默认：false 使用 VAD 断句）
    ///   - vocabularyId: 热词 ID（可选）
    func setParams(
        model: String = "fun-asr-realtime",
        language: [String] = ["zh"],
        sampleRate: Int = 16000,
        format: String = "pcm",
        semanticPunctuationEnabled: Bool = false,
        vocabularyId: String? = nil
    ) {
        guard isInitialized else {
            print("[ASR] Not initialized")
            return
        }

        // 完全对齐 DashFunAsrSpeechTranscriberViewController.genParams()
        // 手动构建 JSON 以精确控制参数
        var nlsConfigParts: [String] = [
            "\"sr_format\": \"\(format)\"",
            "\"model\": \"\(model)\"",
            "\"sample_rate\": \(sampleRate)"
        ]

        // language_hints
        let languageJson = language.map { "\"\($0)\"" }.joined(separator: ", ")
        nlsConfigParts.append("\"language_hints\": [\(languageJson)]")

        // semantic_punctuation_enabled
        // false = VAD 断句（语音活动检测），true = 语义断句
        // 对齐参考实现：switchVadMode.on 时为 NO，否则为 YES
        nlsConfigParts.append("\"semantic_punctuation_enabled\": \(semanticPunctuationEnabled ? "true" : "false")")

        // vocabulary_id (可选)
        if let vocabId = vocabularyId {
            nlsConfigParts.append("\"vocabulary_id\": \"\(vocabId)\"")
        }

        let nlsConfigJson = nlsConfigParts.joined(separator: ", ")

        // service_type: 4 = SERVICE_TYPE_SPEECH_TRANSCRIBER
        let paramsJson = "{ \"service_type\": 4, \"nls_config\": { \(nlsConfigJson) } }"

        print("[ASR] Setting params: \(paramsJson)")

        guard let nui = NeoNui.get_instance() else {
            return
        }

        let result = nui.nui_set_params(paramsJson)
        if result != SUCCESS {
            print("[ASR] Set params failed with code: \(result)")
        }
    }

    // MARK: - 启动/停止识别

    /// 启动 ASR 识别
    /// - Parameter vadMode: VAD 模式（默认：MODE_P2T）
    func start(vadMode: NuiVadMode = MODE_P2T) {
        guard isInitialized else {
            print("[ASR] Not initialized, call initialize() first")
            return
        }

        guard !isRecognizing else {
            print("[ASR] Already recognizing")
            return
        }

        guard let nui = NeoNui.get_instance() else {
            return
        }

        // 先设置 recognizing 状态，这样音频引擎的 tap callback 才能正常工作
        isRecognizing = true
        currentSessionId = UUID().uuidString
        print("[ASR] Starting with session: \(currentSessionId)")

        // 先设置参数，再启动识别 - 对齐参考实现
        // 注意：参考实现在 showStart() 中先调用 nui_set_params，再调用 nui_dialog_start
        let paramsJson = buildParamsJson()
        print("[ASR] nui set params \(paramsJson)")
        let setResult = nui.nui_set_params(paramsJson)
        if setResult != SUCCESS {
            print("[ASR] Set params failed with code: \(setResult)")
        }

        // 构建 dialog 参数
        // 注意：apikey 在这里传入，支持临时 Token 刷新
        // 临时 Token 有效期 60-1800 秒，建议在 Token 快过期前从服务端刷新
        let dialogParams = """
        {
            "apikey": "\(apiKey)"
        }
        """

        // 对齐参考实现：不主动启动音频引擎
        // 等待 onNuiAudioStateChanged(STATE_OPEN) 回调后再启动录音
        // 参考实现流程：
        // 1. nui_dialog_start
        // 2. SDK 触发 onNuiAudioStateChanged(STATE_OPEN)
        // 3. 在回调中启动录音

        // 调用 nui_dialog_start(MODE_P2T) - 对齐参考实现
        let result = nui.nui_dialog_start(vadMode, dialogParam: dialogParams)

        if result == SUCCESS {
            print("[ASR] Started with session: \(currentSessionId)")
            onResult?(.started)
        } else {
            print("[ASR] Start failed with code: \(result)")
            isRecognizing = false
            onResult?(.error("启动失败", Int(result)))
        }
    }

    /// 构建参数 JSON - 对齐 genParams()
    private func buildParamsJson() -> String {
        var nlsConfigParts: [String] = [
            "\"sr_format\": \"pcm\"",
            "\"model\": \"fun-asr-realtime\"",
            "\"sample_rate\": 16000"
        ]
        nlsConfigParts.append("\"language_hints\": [\"zh\"]")
        nlsConfigParts.append("\"semantic_punctuation_enabled\": false")

        let nlsConfigJson = nlsConfigParts.joined(separator: ", ")
        return "{ \"service_type\": 4, \"nls_config\": { \(nlsConfigJson) } }"
    }

    /// 停止 ASR 识别
    /// - Parameter waitForResult: 是否等待完整结果（默认：true）
    func stop(waitForResult: Bool = true) {
        guard isRecognizing else {
            return
        }

        guard let nui = NeoNui.get_instance() else {
            isRecognizing = false
            return
        }

        // 对齐参考实现：先调用 nui_dialog_cancel(false)
        // false 表示停止但等待完整结果返回
        let result = nui.nui_dialog_cancel(!waitForResult)

        if result == SUCCESS {
            isRecognizing = false
            print("[ASR] Stopped")
        } else {
            print("[ASR] Stop failed with code: \(result)")
        }

        // 再停止音频引擎 - 对齐参考实现
        stopAudioEngine()
    }

    /// 取消识别（不等待结果）
    func cancel() {
        stop(waitForResult: false)
    }

    // MARK: - 音频引擎控制

    /// 设置静音状态
    func setMuted(_ muted: Bool) {
        isMuted = muted
        // 同步静音状态到 VoiceProcessing 引擎
        voiceProcessingEngine?.isMuted = muted
        print("[ASR] Muted: \(muted)")
    }

    /// 配置 VoiceProcessing 音频引擎输入
    func setupVoiceProcessingInput() {
        // 获取 VoiceProcessing 引擎单例
        guard let vpEngine = VoiceProcessingAudioEngine.shared else {
            print("[ASR] VoiceProcessing engine not available")
            return
        }

        // 配置引擎
        if !vpEngine.isConfigured {
            guard vpEngine.configure() else {
                print("[ASR] Failed to configure VoiceProcessing engine")
                return
            }
        }

        // 设置输入数据回调
        vpEngine.onInputData = { [weak self] buffer in
            self?.sendAudioData(buffer)
        }

        // 启动引擎
        if !vpEngine.isRunning {
            guard vpEngine.start() else {
                print("[ASR] Failed to start VoiceProcessing engine")
                return
            }
        }

        // 引用引擎
        voiceProcessingEngine = vpEngine

        print("[ASR] VoiceProcessing input configured and started")
    }

    /// 音频引擎是否正在运行
    private var isAudioEngineRunning: Bool {
        audioEngine?.isRunning ?? false
    }

    /// 启动音频引擎捕获麦克风数据
    private func startAudioEngine() {
        guard !isMuted else {
            print("[ASR] Audio engine start skipped - muted")
            return
        }

        // 如果已配置 VoiceProcessing，使用它
        if let vpEngine = voiceProcessingEngine, vpEngine.isRunning {
            print("[ASR] Using VoiceProcessing engine (AEC enabled)")
            return
        }

        // 否则使用传统的 AVAudioEngine
        startLegacyAudioEngine()
    }

    /// 启动传统 AVAudioEngine (不带 AEC)
    private func startLegacyAudioEngine() {
        // 避免重复启动
        guard !isAudioEngineRunning else {
            print("[ASR] Audio engine already running")
            return
        }

        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
            try audioSession.setActive(true)
            // Set preferred sample rate to 16000 for ASR
            try audioSession.setPreferredSampleRate(16000)
            try audioSession.setPreferredIOBufferDuration(0.01)
        } catch {
            print("[ASR] Failed to setup audio session: \(error)")
            return
        }

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine?.inputNode

        guard let engine = audioEngine, let input = inputNode else {
            print("[ASR] Failed to create audio engine")
            return
        }

        // Get the input format (device native format, typically 48kHz)
        let inputFormat = input.inputFormat(forBus: 0)
        print("[ASR] Input format: \(inputFormat)")

        // Use the input node's output format instead of forcing 16kHz
        // This avoids format mismatch errors on devices that don't support 16kHz directly
        let tapFormat = input.outputFormat(forBus: 0)
        print("[ASR] Tap format: \(tapFormat)")

        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
            guard let self = self else { return }
            guard !self.isMuted else { return }
            guard self.isRecognizing else {
                print("[ASR] Tap callback skipped - not recognizing")
                return
            }

            // Convert to 16kHz if needed and send audio data to buffer
            self.sendAudioData(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            print("[ASR] Audio engine started")
        } catch {
            print("[ASR] Failed to start audio engine: \(error)")
        }
    }

    /// 停止音频引擎
    private func stopAudioEngine() {
        // 如果使用 VoiceProcessing，只停止 ASR 输入回调，不停止引擎本身
        // (因为 TTS 可能还在使用)
        if voiceProcessingEngine != nil {
            voiceProcessingEngine?.onInputData = nil
            print("[ASR] VoiceProcessing input callback removed")
        }

        // 停止传统引擎
        audioEngine?.stop()
        audioEngine = nil
        print("[ASR] Audio engine stopped")
    }

    /// 发送音频数据到 SDK - 将数据存入缓冲区
    private func sendAudioData(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted else { return }
        guard isRecognizing else {
            print("[ASR] sendAudioData skipped - not recognizing")
            return
        }

        let inputSampleRate = buffer.format.sampleRate
        let targetSampleRate: Double = 16000

        // Print audio format info for debugging
        print("[ASR] sendAudioData: input=\(inputSampleRate)Hz, frames=\(buffer.frameLength), channels=\(buffer.format.channelCount), commonFormat=\(buffer.format.commonFormat))")

        // Convert to 16kHz if input is not 16kHz
        let convertedBuffer: AVAudioPCMBuffer
        if abs(inputSampleRate - targetSampleRate) > 1.0 {
            // Need to convert sample rate
            guard let converter = AVAudioConverter(from: buffer.format, to: AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!) else {
                print("[ASR] Failed to create audio converter")
                return
            }

            // Print output format info
            let outputFormat = converter.outputFormat
            print("[ASR] Output format: \(outputFormat.sampleRate)Hz, channels=\(outputFormat.channelCount), commonFormat=\(outputFormat.commonFormat)")

            let ratio = Float(targetSampleRate / inputSampleRate)
            let convertedFrameCount = AVAudioFrameCount(Float(buffer.frameLength) * ratio)
            guard let convertedBufferTemp = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: convertedFrameCount) else {
                print("[ASR] Failed to create converted buffer")
                return
            }

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
            let status = converter.convert(to: convertedBufferTemp, error: &error, withInputFrom: inputBlock)
            if status == .error || error != nil {
                print("[ASR] Audio conversion failed: \(error?.localizedDescription ?? "unknown error")")
                return
            }

            print("[ASR] Converted: \(buffer.frameLength) -> \(convertedBufferTemp.frameLength) frames")
            convertedBuffer = convertedBufferTemp
        } else {
            // Already 16kHz, no conversion needed
            convertedBuffer = buffer
        }

        // Convert to 16-bit PCM format for SDK
        // SDK expects 16-bit signed integer PCM data at 16kHz, mono
        guard let audioData = convertedBuffer.audioBufferList.pointee.mBuffers.mData else {
            print("[ASR] No audio data in buffer")
            return
        }

        let frameCount = Int(convertedBuffer.frameLength)
        let channels = Int(convertedBuffer.audioBufferList.pointee.mBuffers.mNumberChannels)
        let format = convertedBuffer.format

        // Create 16-bit PCM data
        var pcmData = Data(capacity: frameCount * channels * 2)  // 2 bytes per 16-bit sample

        if format.commonFormat == .pcmFormatInt16 {
            // Already 16-bit PCM, just copy
            let length = Int(convertedBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)
            pcmData.append(Data(bytes: audioData, count: length))
            print("[ASR] Using existing 16-bit PCM data: \(length) bytes")
        } else if format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64 {
            // Convert from float to 16-bit PCM
            let isFloat32 = format.commonFormat == .pcmFormatFloat32
            let bufferPtr = convertedBuffer.floatChannelData![0]
            var int16Sample: Int16

            for i in 0..<frameCount {
                // Convert float [-1.0, 1.0] to Int16 [-32768, 32767]
                let sample = bufferPtr[i]
                int16Sample = max(-32768, min(32767, Int16(sample * 32767.0)))
                pcmData.append(Data(bytes: &int16Sample, count: 2))
            }
            print("[ASR] Converted from Float to 16-bit PCM: \(pcmData.count) bytes")
        } else {
            // Fallback: try to read as 16-bit
            let length = Int(convertedBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)
            pcmData.append(Data(bytes: audioData, count: length))
            print("[ASR] Fallback: using raw buffer data: \(length) bytes")
        }

        // 将音频数据添加到缓冲区
        audioDataBufferLock.lock()
        audioDataBuffer.append(pcmData)

        // 记录缓冲区大小
        let bufferSize = audioDataBuffer.count
        audioDataBufferLock.unlock()

        print("[ASR] Buffer size: \(bufferSize) bytes")
    }

    // MARK: - 资源释放

    /// 释放 SDK 资源
    func release() {
        stop()

        guard let nui = NeoNui.get_instance() else {
            return
        }

        let result = nui.nui_release()
        if result == SUCCESS {
            isInitialized = false
            print("[ASR] Released")
        }
    }
}

// MARK: - NeoNuiSdkDelegate

extension AsrService: NeoNuiSdkDelegate {

    @objc(onNuiEventCallback:dialog:kwsResult:asrResult:ifFinish:retCode:)
    func onNuiEventCallback(
        _ nuiEvent: NuiCallbackEvent,
        dialog: Int64,
        kwsResult: UnsafeMutablePointer<CChar>?,
        asrResult: UnsafeMutablePointer<CChar>?,
        ifFinish finish: Bool,
        retCode code: Int32
    ) {
        // 获取 nui 实例用于解析响应
        guard let nui = NeoNui.get_instance() else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 辅助函数：从 nui_get_all_response 解析 JSON
            // 对齐参考实现的 parseSentenceText 逻辑
            func parseSentenceText() -> String? {
                guard let response = nui.nui_get_all_response() else {
                    return nil
                }
                let jsonResponse = String(cString: response)

                guard let data = jsonResponse.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = json["payload"] as? [String: Any],
                      let output = payload["output"] as? [String: Any],
                      let sentence = output["sentence"] as? [String: Any],
                      let text = sentence["text"] as? String else {
                    return nil
                }

                return text.isEmpty ? nil : text
            }

            // 对齐参考实现的日志格式
            print("[ASR] onNuiEventCallback event \(nuiEvent.rawValue) finish \(finish)")

            if nuiEvent == EVENT_TRANSCRIBER_STARTED {
                // asr_result 在此包含 task_id，task_id 有助于排查问题，请用户进行记录保存
                let startedInfo = "EVENT_TRANSCRIBER_STARTED: \(asrResult.flatMap { String(cString: $0) } ?? "")"
                print("[ASR] \(startedInfo)")
                self.appendEventResult("EVENT_TRANSCRIBER_STARTED")
                self.onResult?(.started)

            } else if nuiEvent == EVENT_TRANSCRIBER_COMPLETE {
                print("[ASR] EVENT_TRANSCRIBER_COMPLETE")
                self.appendEventResult("EVENT_TRANSCRIBER_COMPLETE")
                self.isRecognizing = false
                self.onResult?(.completed)

            } else if nuiEvent == EVENT_SENTENCE_START {
                print("[ASR] EVENT_SENTENCE_START")
                self.appendEventResult("EVENT_SENTENCE_START")

            } else if nuiEvent == EVENT_ASR_PARTIAL_RESULT || nuiEvent == EVENT_SENTENCE_END {
                // 中间识别结果或句子结束
                if let text = parseSentenceText() {
                    print("[ASR] ASR RESULT: \(text) finish \(finish)")
                    self.appendEventResult(text)

                    if nuiEvent == EVENT_ASR_PARTIAL_RESULT {
                        self.onResult?(.partial(text))
                    } else {
                        self.onResult?(.sentence(text))
                    }
                }

                if nuiEvent == EVENT_SENTENCE_END {
                    self.appendEventResult("EVENT_SENTENCE_END")
                }

            } else if nuiEvent == EVENT_VAD_START {
                print("[ASR] EVENT_VAD_START")
                self.appendEventResult("EVENT_VAD_START")

            } else if nuiEvent == EVENT_VAD_END {
                print("[ASR] EVENT_VAD_END")
                self.appendEventResult("EVENT_VAD_END")

            } else if nuiEvent == EVENT_ASR_ERROR {
                // asr_result 在 EVENT_ASR_ERROR 中为错误信息，搭配错误码 code 和其中的 task_id 更易排查问题
                let errorMsg = asrResult.flatMap { String(cString: $0) } ?? "识别错误"
                let fullErrorMessage = "EVENT_ASR_ERROR error[\(code)], all mesg[\(nui.nui_get_all_response().flatMap { String(cString: $0) } ?? "")]"
                print("[ASR] \(fullErrorMessage)")
                self.appendEventResult(fullErrorMessage)
                self.onResult?(.error(errorMsg, Int(code)))

                // 出错时尝试重启录音
                self.stopAudioEngine()
                self.startAudioEngine()

            } else if nuiEvent == EVENT_MIC_ERROR {
                print("[ASR] MIC ERROR")
                // 重启录音
                self.stopAudioEngine()
                self.startAudioEngine()
            }
        }
    }

    /// 音频数据请求回调 - SDK 需要更多音频数据
    @objc(onNuiNeedAudioData:length:)
    func onNuiNeedAudioData(_ audioData: UnsafeMutablePointer<CChar>?, length len: Int32) -> Int32 {
        guard let audioData = audioData else {
            return 0
        }

        guard len > 0 else {
            return 0
        }

        audioDataBufferLock.lock()
        defer { audioDataBufferLock.unlock() }

        // 安全检查：确保缓冲区有数据且范围有效
        guard audioDataBuffer.count > 0 else {
            // 缓冲区为空，记录空计数
            emptyCount += 1
            if emptyCount >= 50 {
                print("[ASR] _recordedVoiceData length = 0! empty 50times.")
                emptyCount = 0
            }
            return 0
        }

        let recorderLen = min(Int(len), audioDataBuffer.count)

        // 直接使用 withUnsafeBytes 复制数据，避免 subdata 可能的崩溃
        audioDataBuffer.withUnsafeBytes { srcBytes in
            let srcPtr = srcBytes.baseAddress!.assumingMemoryBound(to: CChar.self)
            audioData.assign(from: srcPtr, count: recorderLen)
        }

        // 移除已使用的数据 - 对齐参考实现的 setData 逻辑
        audioDataBuffer.removeFirst(recorderLen)

        print("[ASR] onNuiNeedAudioData: sent \(recorderLen) bytes, buffer now has \(audioDataBuffer.count) bytes")
        return Int32(recorderLen)
    }

    /// 音频状态变化回调
    @objc(onNuiAudioStateChanged:)
    func onNuiAudioStateChanged(_ state: NuiAudioState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 对齐参考实现 DashFunAsrSpeechTranscriberViewController.onNuiAudioStateChanged
            if state == STATE_CLOSE {
                print("[ASR] Audio state: CLOSE - stop recording")
                self.appendEventResult("RECORDER STATE_CLOSE")
                self.stopAudioEngine()
            } else if state == STATE_PAUSE {
                print("[ASR] Audio state: PAUSE - stop recording")
                self.appendEventResult("RECORDER STATE_PAUSE")
                self.stopAudioEngine()
            } else if state == STATE_OPEN {
                print("[ASR] Audio state: OPEN - start recording")
                self.appendEventResult("RECORDER STATE_OPEN")
                // 清空录音数据
                self.audioDataBufferLock.lock()
                self.audioDataBuffer.removeAll()
                self.audioDataBufferLock.unlock()
                // 启动录音 - 这是真正启动录音的地方（对齐参考实现）
                self.startAudioEngine()
            }
        }
    }

    /// 添加事件记录 - 用于调试
    private func appendEventResult(_ result: String) {
        print("[ASR] Event: \(result)")
    }

    /// RMS 变化回调（音频音量）
    func onNuiRmsChanged(_ rms: Float) {
        // 可选：用于显示音量波形
    }

    /// 助手事件回调（未使用）
    func onNuiAssistEventCallback(
        _ nuiEvent: NuiCallbackEvent,
        info: UnsafeMutablePointer<CChar>?,
        infoLen: Int32,
        buffer: UnsafeMutablePointer<CChar>?,
        len: Int32
    ) {
        // 未使用
    }

    /// 日志回调
    func onNuiLogTrackCallback(_ level: NuiSdkLogLevel, logMessage: UnsafePointer<CChar>?) {
        guard let message = logMessage else { return }
        let log = String(cString: message)
        print("[ASR Log] \(log)")
    }

    /// 文件转录事件回调（未使用）
    func onFileTransEventCallback(
        _ nuiEvent: NuiCallbackEvent,
        asrResult: UnsafeMutablePointer<CChar>?,
        taskId: UnsafeMutablePointer<CChar>?,
        ifFinish finish: Bool,
        retCode code: Int32
    ) {
        // 未使用
    }

    /// 文件转录日志回调（未使用）
    func onFileTransLogTrackCallback(_ level: NuiSdkLogLevel, logMessage: UnsafePointer<CChar>?) {
        // 未使用
    }
}
