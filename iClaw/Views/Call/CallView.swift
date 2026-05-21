import SwiftUI
import AVFoundation
import WebKit

struct CallView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    let session: Session

    @State private var isMuted = false
    @State private var isSpeakerOn = false
    @State private var showScenarioPicker = false
    @State private var showCameraOverlay = false
    @State private var showCameraAnimation = false
    @State private var isFlashlightOn = false

    // Reference to ChatViewModel for sending messages
    @State private var chatViewModel: ChatViewModel?

    // ASR Service for speech recognition
    @State private var asrService: AsrService?

    // ASR accumulation
    @State private var currentSentence: String = ""
    @State private var hasSentCurrentSentence: Bool = false

    var body: some View {
        ZStack {
            // Avatar WebView - full screen background
            if !showCameraOverlay {
                AvatarWebView()
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Top bar (hidden in camera mode)
                if !showCameraOverlay {
                    topBar
                }

                Spacer()

                // Bottom buttons
                bottomButtons
            }

            // Camera overlay - full screen camera preview
            if showCameraOverlay {
                cameraOverlay
            }
        }
        .onAppear {
            setupAudioSession()
            startMicrophone()
            setupASR()
            setupChatViewModel()
        }
        .onDisappear {
            stopMicrophone()
            stopASR()
        }
        .sheet(isPresented: $showScenarioPicker) {
            ScenarioPickerView()
        }
    }

    // MARK: - Camera Overlay
    private var cameraOverlay: some View {
        ZStack {
            // Full screen camera preview
            CameraOverlayView(onDismiss: {
                showCameraOverlay = false
            }, showAnimationView: $showCameraAnimation)
                .ignoresSafeArea()

            // Top bar for camera mode
            if !showCameraAnimation {
                VStack {
                    HStack(alignment: .center) {
                        // Left: Menu button
                        Button {
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }

                        Spacer()

                        // Right: Robot (animation), Flashlight, Camera flip, Text size
                        HStack(spacing: 4) {
                            // Robot button - triggers animation view
                            Button {
                                showCameraAnimation = true
                            } label: {
                                Image(systemName: "face.smiling")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                            }

                            // Flashlight button
                            Button {
                                isFlashlightOn.toggle()
                                // TODO: Implement flashlight toggle
                            } label: {
                                Image(systemName: isFlashlightOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                            }

                            // Camera flip button
                            Button {
                                // TODO: Implement camera flip
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                            }

                            // Text size button - same as normal mode
                            Button {
                                // TODO: Implement text size settings
                            } label: {
                                Text(L10n.Call.textSize)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    Spacer()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !showCameraAnimation {
                bottomButtons
            } else {
                Spacer()
            }
        }
        .transition(.opacity)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(alignment: .center) {
            // Left: Menu button
            Button {
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
            }

            // Center: Scenario picker button - centered in screen
            GeometryReader { geo in
                Button {
                    showScenarioPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 18, weight: .medium))
                        Text(L10n.Call.selectScenario)
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Color.white.opacity(0.5)
                            .cornerRadius(20)
                    )
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .frame(height: 44)

            // Right: Text size button
            Button {
                // TODO: Implement text size settings
            } label: {
                Text(L10n.Call.textSize)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.black)
            }
            .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: - Bottom Buttons
    private var bottomButtons: some View {
        VStack(spacing: 16) {
            // Page indicator
            pageIndicator

            // Status text
            statusSection

            // Buttons
            HStack(spacing: 0) {
                // Microphone button
                Button {
                    toggleMute()
                } label: {
                    ZStack {
                        Circle()
                            .fill(buttonBgColor(isMuted, isMuteButton: true))
                            .frame(width: 72, height: 72)

                        Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(buttonIconColor(isMuted, isMuteButton: true))
                    }
                }
                .frame(maxWidth: .infinity)

                // Share screen button
                Button {
                } label: {
                    ZStack {
                        Circle()
                            .fill(buttonBgColor(false))
                            .frame(width: 72, height: 72)

                        Image(systemName: "rectangle.portrait.and.arrow.up.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(buttonIconColor(false))
                    }
                }
                .frame(maxWidth: .infinity)

                // Video camera button
                Button {
                    showCameraOverlay.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(buttonBgColor(showCameraOverlay))
                            .frame(width: 72, height: 72)

                        Image(systemName: showCameraOverlay ? "video.fill" : "video.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(buttonIconColor(showCameraOverlay))
                    }
                }
                .frame(maxWidth: .infinity)

                // End call button
                Button {
                    dismiss()
                } label: {
                    ZStack {
                        Circle()
                            .fill(buttonBgColor(false))
                            .frame(width: 72, height: 72)

                        Image(systemName: "xmark")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // AI generated label
            aiGeneratedLabel
        }
        .padding(.horizontal, 8)
    }

    // Button background color helper
    private func buttonBgColor(_ isActive: Bool, isMuteButton: Bool = false) -> Color {
        if isMuteButton && isActive {
            // Mute button when muted: always white background
            return Color.white
        }
        if showCameraOverlay {
            // Camera mode: white background for active, semi-transparent for inactive
            return isActive ? Color.white : Color.white.opacity(0.3)
        } else {
            // Normal mode: semi-transparent white background
            return Color.white.opacity(0.5)
        }
    }

    // Button icon color helper
    private func buttonIconColor(_ isActive: Bool, isMuteButton: Bool = false) -> Color {
        if isMuteButton && isActive {
            // Mute button when muted: always red icon
            return .red
        }
        if showCameraOverlay {
            // Camera mode: black icon for active white button, white for others
            return isActive ? .black : .white
        } else {
            // Normal mode: black icon
            return .black
        }
    }

    // MARK: - Page Indicator
    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == 0 ? (showCameraOverlay ? Color.white.opacity(0.3) : Color.primary) : (showCameraOverlay ? Color.white : Color.gray.opacity(0.5)))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Status Section
    private var statusSection: some View {
        Text(isMuted ? L10n.Call.isMuted : L10n.Call.youCanSpeak)
            .font(.system(size: 14))
            .foregroundStyle(showCameraOverlay ? .white : .secondary)
    }

    // MARK: - AI Generated Label
    private var aiGeneratedLabel: some View {
        Text(L10n.Call.aiGenerated)
            .font(.caption)
            .foregroundStyle(showCameraOverlay ? Color.white.opacity(0.5) : Color.gray)
            .padding(.top, 8)
    }

    // MARK: - Audio Session
    private func setupAudioSession() {
        // 配置音频会话以启用 VoiceProcessing (AEC)
        // .voiceChat 模式是关键，它启用系统级回声消除
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            print("[CallView] Audio session configured with .voiceChat mode (AEC enabled)")
        } catch {
            print("[CallView] Failed to setup audio session: \(error)")
        }
    }

    private func startMicrophone() {
        // 请求麦克风权限
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    print("[CallView] Microphone permission granted")
                    // 配置 VoiceProcessing 音频引擎
                    self.setupVoiceProcessingEngine()
                } else {
                    print("[CallView] Microphone permission denied")
                }
            }
        }
    }

    private func stopMicrophone() {
        // 停止 VoiceProcessing 引擎
        VoiceProcessingAudioEngine.shared.stop()
        print("[CallView] VoiceProcessing engine stopped")
    }

    /// 配置 VoiceProcessing 音频引擎
    private func setupVoiceProcessingEngine() {
        let vpEngine = VoiceProcessingAudioEngine.shared

        // 配置引擎
        if !vpEngine.isConfigured {
            guard vpEngine.configure() else {
                print("[CallView] Failed to configure VoiceProcessing engine")
                return
            }
        }

        // 启动引擎 (启用 AEC)
        if !vpEngine.isRunning {
            guard vpEngine.start() else {
                print("[CallView] Failed to start VoiceProcessing engine")
                return
            }
        }

        print("[CallView] VoiceProcessing engine started (AEC active)")
    }

    private func setupChatViewModel() {
        // Create ChatViewModel instance for sending messages to AI
        chatViewModel = ChatViewModel(session: session, modelContext: modelContext)
    }

    private func toggleMute() {
        isMuted.toggle()

        // 静音控制通过 VoiceProcessing 引擎和 ASR 服务同步处理
        if isMuted {
            VoiceProcessingAudioEngine.shared.isMuted = true
            asrService?.setMuted(true)
            print("[CallView] Microphone muted (AEC engine + ASR)")
        } else {
            VoiceProcessingAudioEngine.shared.isMuted = false
            asrService?.setMuted(false)
            print("[CallView] Microphone unmuted (AEC engine + ASR)")
        }
    }

    // MARK: - ASR Setup

    private func setupASR() {
        // Get ASR service instance
        asrService = AsrService.shared

        // Set up result handler
        asrService?.onResult = { result in
            self.handleAsrResult(result)
        }

        // TODO: Replace with your actual API Key
        // 注意：推荐使用从服务端获取的临时 Token（有效期 60-1800 秒）
        let apiKey = "sk-98e6b75479bd4502a6c14b1c7e1ce7c5"
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown_device"

        // 初始化 ASR SDK
        asrService?.initialize(apiKey: apiKey, deviceId: deviceId)

        // 设置 ASR 参数 - 对齐参考实现的 genParams()
        // model: fun-asr-realtime 或 fun-asr-realtime-2025-09-15
        // format: opus 或 pcm（opus 表示将用户送入的 pcm 数据压缩成 opus 数据进行传输）
        // sampleRate: 16000（只支持 16000Hz）
        // semanticPunctuationEnabled: false = VAD 断句，true = 语义断句
        asrService?.setParams(
            model: "fun-asr-realtime",
            language: ["zh"],
            sampleRate: 16000,
            format: "pcm",  // 尝试使用 pcm 格式
            semanticPunctuationEnabled: false
        )

        // 启动 ASR 识别，启用 VoiceProcessing (AEC)
        // useVoiceProcessing: true 表示使用 VoiceProcessing 音频引擎采集麦克风数据
        asrService?.start(useVoiceProcessing: true)
    }

    private func stopASR() {
        asrService?.stop()
        asrService?.release()
    }

    private func handleAsrResult(_ result: AsrResultType) {
        switch result {
        case .partial(let text):
            // 中间结果，更新当前句子
            print("[CallView] Partial: \(text)")
            currentSentence = text
            // 重置标志，允许新一轮发送
            hasSentCurrentSentence = false

        case .sentence(let text):
            // 完整句子，发送给 AI
            print("[CallView] Sentence: \(text)")
            sendToAI(text)
            // 标记已发送，避免在 .completed 中重复发送
            hasSentCurrentSentence = true

        case .error(let message, let code):
            print("[CallView] ASR Error: \(message) (code: \(code))")

        case .started:
            print("[CallView] ASR Started")
            currentSentence = ""
            hasSentCurrentSentence = false

        case .completed:
            print("[CallView] ASR Completed")
            // 如果有未发送的句子，发送
            if !currentSentence.isEmpty && !hasSentCurrentSentence {
                sendToAI(currentSentence)
                hasSentCurrentSentence = true
            }
        }
    }

    private func sendToAI(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let viewModel = chatViewModel else { return }

        print("[CallView] Sending to AI: \(text)")

        // 设置输入文本并发送
        viewModel.inputText = text
        viewModel.sendMessage()
    }
}

// MARK: - Scenario Picker View
struct ScenarioPickerView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(0..<5, id: \.self) { index in
                        Button {
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(L10n.Call.scenarioTitles[index])
                                        .font(.headline)
                                    Text(L10n.Call.scenarioDescriptions[index])
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle(L10n.Call.selectScenario)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    CallView(session: .init(title: "Test Session"))
}

// MARK: - Avatar WebView
struct AvatarWebView: UIViewRepresentable {
    let urlString = "https://192.168.3.204:4001"

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Allow inline media playback
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = true
        webView.backgroundColor = .clear
        webView.isOpaque = false

        // Remove safe area insets
        if #available(iOS 11.0, *) {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        }
        webView.scrollView.contentInset = .zero

        // Load the URL
        if let url = URL(string: urlString) {
            let request = URLRequest(url: url)
            webView.load(request)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No updates needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(urlString: urlString)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let urlString: String

        init(urlString: String) {
            self.urlString = urlString
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Accept self-signed certificates for the target host
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                if let serverTrust = challenge.protectionSpace.serverTrust {
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                    return
                }
            }
            completionHandler(.performDefaultHandling, nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("AvatarWebView did finish loading: \(webView.url?.absoluteString ?? "unknown")")
            // Ensure no content insets
            webView.scrollView.contentInset = .zero
            webView.scrollView.scrollIndicatorInsets = .zero

            // Restore audio session after WebView loads
            restoreAudioSession()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("AvatarWebView did fail navigation: \(error)")
            // Also restore audio session on failure
            restoreAudioSession()
        }

        private func restoreAudioSession() {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Failed to restore audio session: \(error)")
            }
        }
    }
}
