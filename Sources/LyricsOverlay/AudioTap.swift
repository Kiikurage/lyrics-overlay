import Accelerate
import AppKit
import CoreAudio

/// Spotify.app の出力を Core Audio のプロセスタップで拾い、
/// 簡易的な周波数スペクトルにして渡す。
///
/// 仮想オーディオデバイス(BlackHole 等)は使わない。macOS 14.2 以降の
/// `AudioHardwareCreateProcessTap` なら、ユーザーの出力先設定を変えずに
/// 特定プロセスの音だけを取れる。音はこれまでどおり既定の出力へ流れ続ける。
///
/// 初回に「システム音声の録音」の許可ダイアログが出る。拒否された場合は
/// 単に何も届かないだけで、歌詞表示には影響しない。
final class AudioTap {
    /// バンド数。細かくしすぎると倍音が 1 本ずつ分離して櫛状になり、
    /// 逆に形が読めなくなる。包絡が見える程度に粗く取る。
    static let bandCount = 40

    /// 解析結果。メインスレッドで呼ばれる。
    var onAnalysis: ((AudioSnapshot) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "audio.tap")

    private let analyzer = SpectrumAnalyzer(bandCount: AudioTap.bandCount)
    private var lastEmit: TimeInterval = 0
    /// 最後に「音が入っている」バッファを受け取った時刻。
    /// 許可が無いと呼ばれるが無音になるので、届いているかの判定に使う。
    private var lastAudio: TimeInterval = 0

    /// 直近 2 秒以内に音が届いているか。
    var isReceivingAudio: Bool {
        ProcessInfo.processInfo.systemUptime - lastAudio < 2
    }

    deinit { stop() }

    /// Spotify 内の音量(0〜100)を伝える。解析でこのぶんを打ち消す。
    func setVolume(_ volume: Double) {
        queue.async { [analyzer] in analyzer.volume = volume }
    }

    /// 曲が変わったときに、テンポの推定をやり直す。
    func resetTempo() {
        queue.async { [analyzer] in analyzer.resetTempo() }
    }

    // MARK: - 開始と終了

    /// - Returns: タップを開始できたか。Spotify が起動していなければ失敗する。
    @discardableResult
    func start() -> Bool {
        stop()
        guard let pid = spotifyPID() else { return false }
        guard let processObject = processObject(for: pid) else {
            log("Spotify のプロセスオブジェクトが引けない")
            return false
        }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "LyricsOverlay"
        description.isPrivate = true
        // 音を止めてしまっては元も子もないので、そのまま流す。
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            log("タップを作れない: \(status)")
            return false
        }

        guard let outputUID = defaultOutputUID() else { return false }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LyricsOverlay Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            log("集約デバイスを作れない: \(status)")
            return false
        }

        guard let format = tapFormat() else { return false }
        analyzer.prepare(sampleRate: format.mSampleRate)

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, input, _, _, _ in
            self?.handle(input)
        }
        guard status == noErr, let procID else {
            log("IOProc を作れない: \(status)")
            return false
        }
        status = AudioDeviceStart(aggregateID, procID)
        if status != noErr {
            log("開始できない: \(status)")
            return false
        }
        return true
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - 解析

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        if peak(of: buffers) > 0.0005 {
            lastAudio = ProcessInfo.processInfo.systemUptime
        }
        guard let snapshot = analyzer.consume(buffers) else { return }

        // 表示は画面の更新に合わせて 60fps まで。ここを間引くと、
        // 解析が速くなってもその間隔ぶんの遅れが乗る。
        let now = ProcessInfo.processInfo.systemUptime
        guard snapshot.beat || now - lastEmit >= 1.0 / 60 else { return }
        lastEmit = now
        DispatchQueue.main.async { [weak self] in self?.onAnalysis?(snapshot) }
    }

    private func peak(of buffers: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.bindMemory(to: Float.self, capacity: count)
            // 全部見る必要はないので粗く拾う。
            for index in stride(from: 0, to: count, by: 16) {
                peak = max(peak, abs(samples[index]))
            }
            break
        }
        return peak
    }

    // MARK: - Core Audio の問い合わせ

    private func spotifyPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.spotify.client")
            .first?.processIdentifier
    }

    /// PID から、Core Audio が扱うプロセスオブジェクトの ID を引く。
    private func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr
        else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private func tapFormat() -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr
        else {
            log("タップの形式が取れない")
            return nil
        }
        return format
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("AudioTap: \(message)\n".data(using: .utf8)!)
    }
}
