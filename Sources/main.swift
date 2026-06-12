import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Vision

struct PostureConfig {
    let minimumReminderInterval: TimeInterval = 25 * 60
    let maximumReminderInterval: TimeInterval = 45 * 60
    let longSittingThreshold: TimeInterval = 35 * 60
    let minimumObservationWindow: TimeInterval = 3 * 60
    let maximumObservationWindow: TimeInterval = 5 * 60
    let minimumObservationPhotos = 10
    let presenceProbeDuration: TimeInterval = 12
    let presenceProbeMinimumPhotos = 2
    let presenceProbeInterval: TimeInterval = 60
    let absenceCancelSampleCount = 2
    let snoozeInterval: TimeInterval = 5 * 60
    let shortPauseInterval: TimeInterval = 60 * 60
}

enum PostureIssue: String, CaseIterable, Hashable, Codable {
    case lowHead = "低头"
    case hunchedBack = "含胸/驼背"
    case leaning = "身体左右歪斜"
    case unchanged = "姿势长时间无变化"
    case longSitting = "久坐"
}

struct FramePostureSample {
    let personPresent: Bool
    let bodyDetected: Bool
    let faceDetected: Bool
    let lowHeadScore: Double
    let hunchScore: Double
    let leanScore: Double
    let confidence: Double
    let poseSignature: [Double]
}

struct PostureResult {
    var issues: Set<PostureIssue>
    let personPresent: Bool
    let cancelledBecauseAway: Bool
    let postureUnchanged: Bool
    let observationDuration: TimeInterval
    let framesAnalyzed: Int
    let confidence: Double
    let motionScore: Double
    let detail: String
    let imageData: Data?
    let sampleImageDatas: [Data]

    var issueText: String {
        let ordered = PostureIssue.allCases.filter { issues.contains($0) }
        return ordered.map(\.rawValue).joined(separator: "、")
    }
}

enum ReminderSoundMode: String, CaseIterable {
    case speech = "speech"
    case audio = "audio"

    var title: String {
        switch self {
        case .speech:
            return "朗读文案"
        case .audio:
            return "播放自定义音频"
        }
    }
}

enum ReminderDeliveryMode: String, CaseIterable {
    case speechAndPopup = "speechAndPopup"
    case speechOnly = "speechOnly"
    case popupOnly = "popupOnly"

    var title: String {
        switch self {
        case .speechAndPopup:
            return "语音 + 弹窗"
        case .speechOnly:
            return "仅语音"
        case .popupOnly:
            return "仅弹窗"
        }
    }

    var usesSound: Bool {
        self == .speechAndPopup || self == .speechOnly
    }

    var usesPopup: Bool {
        self == .speechAndPopup || self == .popupOnly
    }
}

enum ReminderTriggerMode: String, CaseIterable {
    case personVisible = "personVisible"
    case timeElapsed = "timeElapsed"

    var title: String {
        switch self {
        case .personVisible:
            return "观察到人像才触发"
        case .timeElapsed:
            return "按时间触发"
        }
    }
}

enum ObservationTimeMode: String, CaseIterable {
    case fixed = "fixed"
    case random = "random"

    var title: String {
        switch self {
        case .fixed:
            return "指定时间"
        case .random:
            return "随机时间"
        }
    }
}

final class ReminderPreferences {
    static let promptTemplateKey = "posture.promptTemplate"
    static let reminderDeliveryModeKey = "posture.reminderDeliveryMode"
    static let reminderTriggerModeKey = "posture.reminderTriggerMode"
    static let soundModeKey = "posture.soundMode"
    static let customAudioPathKey = "posture.customAudioPath"
    static let observationTimeModeKey = "posture.observationTimeMode"
    static let fixedObservationWindowMinutesKey = "posture.fixedObservationWindowMinutes"
    static let minimumObservationWindowMinutesKey = "posture.minimumObservationWindowMinutes"
    static let maximumObservationWindowMinutesKey = "posture.maximumObservationWindowMinutes"
    static let minimumObservationPhotosKey = "posture.minimumObservationPhotos"
    private static let legacyMinimumObservationDelayMinutesKey = "posture.minimumObservationDelayMinutes"
    private static let legacyMaximumObservationDelayMinutesKey = "posture.maximumObservationDelayMinutes"

    static let defaultPromptTemplate = """
    检测到：{issues}。
    触发方式：{reason}。
    本轮观察约 {minutes} 分钟，采样 {sampleCount} 张，姿态变化 {motionScore}。
    观察详情：{detail}
    现在站起来活动 3 分钟，放松肩颈和腰背。
    """

    var promptTemplate: String {
        get {
            let value = UserDefaults.standard.string(forKey: Self.promptTemplateKey) ?? Self.defaultPromptTemplate
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultPromptTemplate : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.promptTemplateKey)
        }
    }

    var reminderDeliveryMode: ReminderDeliveryMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.reminderDeliveryModeKey) ?? ReminderDeliveryMode.speechAndPopup.rawValue
            return ReminderDeliveryMode(rawValue: raw) ?? .speechAndPopup
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.reminderDeliveryModeKey)
        }
    }

    var reminderTriggerMode: ReminderTriggerMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.reminderTriggerModeKey) ?? ReminderTriggerMode.personVisible.rawValue
            return ReminderTriggerMode(rawValue: raw) ?? .personVisible
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.reminderTriggerModeKey)
        }
    }

    var soundMode: ReminderSoundMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.soundModeKey) ?? ReminderSoundMode.speech.rawValue
            return ReminderSoundMode(rawValue: raw) ?? .speech
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.soundModeKey)
        }
    }

    var customAudioPath: String? {
        get {
            let value = UserDefaults.standard.string(forKey: Self.customAudioPathKey)
            return value?.isEmpty == true ? nil : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.customAudioPathKey)
        }
    }

    var customAudioURL: URL? {
        guard let customAudioPath else { return nil }
        return URL(fileURLWithPath: customAudioPath)
    }

    var observationTimeMode: ObservationTimeMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.observationTimeModeKey) ?? ObservationTimeMode.random.rawValue
            return ObservationTimeMode(rawValue: raw) ?? .random
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.observationTimeModeKey)
        }
    }

    var fixedObservationWindowMinutes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.fixedObservationWindowMinutesKey)
            return value == 0 ? minimumObservationWindowMinutes : clampMinutes(value)
        }
        set {
            UserDefaults.standard.set(clampMinutes(newValue), forKey: Self.fixedObservationWindowMinutesKey)
        }
    }

    var minimumObservationWindowMinutes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.minimumObservationWindowMinutesKey)
            if value != 0 {
                return clampMinutes(value)
            }
            let legacyValue = UserDefaults.standard.integer(forKey: Self.legacyMinimumObservationDelayMinutesKey)
            return legacyValue == 0 ? 25 : clampMinutes(legacyValue)
        }
        set {
            UserDefaults.standard.set(clampMinutes(newValue), forKey: Self.minimumObservationWindowMinutesKey)
        }
    }

    var maximumObservationWindowMinutes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.maximumObservationWindowMinutesKey)
            if value != 0 {
                return max(minimumObservationWindowMinutes, clampMinutes(value))
            }
            let legacyValue = UserDefaults.standard.integer(forKey: Self.legacyMaximumObservationDelayMinutesKey)
            return legacyValue == 0 ? 45 : max(minimumObservationWindowMinutes, clampMinutes(legacyValue))
        }
        set {
            UserDefaults.standard.set(max(minimumObservationWindowMinutes, clampMinutes(newValue)), forKey: Self.maximumObservationWindowMinutesKey)
        }
    }

    var minimumObservationPhotos: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.minimumObservationPhotosKey)
            return value == 0 ? 10 : clampPhotoCount(value)
        }
        set {
            UserDefaults.standard.set(clampPhotoCount(newValue), forKey: Self.minimumObservationPhotosKey)
        }
    }

    func renderedPrompt(result: PostureResult, reason: String) -> String {
        let issues = result.issueText.isEmpty ? "需要活动" : result.issueText
        let minutes = max(1, Int(result.observationDuration / 60))
        let motion = String(format: "%.1f%%", result.motionScore * 100)

        return promptTemplate
            .replacingOccurrences(of: "{issues}", with: issues)
            .replacingOccurrences(of: "{minutes}", with: "\(minutes)")
            .replacingOccurrences(of: "{sampleCount}", with: "\(result.framesAnalyzed)")
            .replacingOccurrences(of: "{motionScore}", with: motion)
            .replacingOccurrences(of: "{detail}", with: result.detail)
            .replacingOccurrences(of: "{reason}", with: reason)
    }

    private func clampMinutes(_ value: Int) -> Int {
        max(1, min(24 * 60, value))
    }

    private func clampPhotoCount(_ value: Int) -> Int {
        max(1, min(240, value))
    }
}

struct ReminderRecord: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let issues: [PostureIssue]
    let reason: String
    let detail: String
    let imageFilename: String?
    let imageFolderName: String?

    var issueText: String {
        issues.isEmpty ? "定时活动提醒" : issues.map(\.rawValue).joined(separator: "、")
    }
}

struct ObservationImageSave {
    let folderName: String
    let representativeImageFilename: String?
}

final class ObservationImageCapture {
    private let fileManager = FileManager.default
    private let tempFolderURL: URL
    private let imagesURL: URL
    private let folderNameProvider: (Date) -> String
    private let lock = NSLock()
    private var sampleCount = 0
    private var isFinalized = false

    init(tempFolderURL: URL, imagesURL: URL, folderNameProvider: @escaping (Date) -> String) {
        self.tempFolderURL = tempFolderURL
        self.imagesURL = imagesURL
        self.folderNameProvider = folderNameProvider
        try? fileManager.createDirectory(at: tempFolderURL, withIntermediateDirectories: true)
    }

    func append(imageData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinalized else { return }
        sampleCount += 1
        let filename = String(format: "sample-%02d.jpg", sampleCount)
        let url = tempFolderURL.appendingPathComponent(filename)
        try? imageData.write(to: url, options: .atomic)
    }

    func finalize(endedAt: Date, representativeImageData: Data?) -> ObservationImageSave? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinalized else { return nil }
        isFinalized = true

        if let representativeImageData {
            let representativeURL = tempFolderURL.appendingPathComponent("representative.jpg")
            try? representativeImageData.write(to: representativeURL, options: .atomic)
        }

        guard sampleCount > 0 || representativeImageData != nil else {
            try? fileManager.removeItem(at: tempFolderURL)
            return nil
        }

        let folderName = folderNameProvider(endedAt)
        let finalURL = imagesURL.appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: tempFolderURL, to: finalURL)
        } catch {
            try? fileManager.createDirectory(at: finalURL, withIntermediateDirectories: true)
            if let entries = try? fileManager.contentsOfDirectory(at: tempFolderURL, includingPropertiesForKeys: nil) {
                for entry in entries {
                    let targetURL = finalURL.appendingPathComponent(entry.lastPathComponent)
                    try? fileManager.removeItem(at: targetURL)
                    try? fileManager.moveItem(at: entry, to: targetURL)
                }
            }
            try? fileManager.removeItem(at: tempFolderURL)
        }

        let representativeImageFilename = representativeImageData == nil
            ? "\(folderName)/sample-01.jpg"
            : "\(folderName)/representative.jpg"
        return ObservationImageSave(folderName: folderName, representativeImageFilename: representativeImageFilename)
    }
}

final class HistoryStore {
    static let retentionDaysKey = "posture.retentionDays"

    private let fileManager = FileManager.default
    let rootURL: URL
    let imagesURL: URL
    private let recordsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    var retentionDays: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.retentionDaysKey)
            return value == 0 ? 7 : value
        }
        set {
            UserDefaults.standard.set(max(1, min(3650, newValue)), forKey: Self.retentionDaysKey)
        }
    }

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = appSupport.appendingPathComponent("PostureBreakReminder", isDirectory: true)
        imagesURL = rootURL.appendingPathComponent("images", isDirectory: true)
        recordsURL = rootURL.appendingPathComponent("records.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    func loadRecords() -> [ReminderRecord] {
        guard let data = try? Data(contentsOf: recordsURL) else { return [] }
        let records = (try? decoder.decode([ReminderRecord].self, from: data)) ?? []
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    func addRecord(
        result: PostureResult,
        reason: String,
        imageSave: ObservationImageSave?
    ) -> ReminderRecord {
        let id = UUID().uuidString
        let record = ReminderRecord(
            id: id,
            createdAt: Date(),
            issues: PostureIssue.allCases.filter { result.issues.contains($0) },
            reason: reason,
            detail: result.detail,
            imageFilename: imageSave?.representativeImageFilename,
            imageFolderName: imageSave?.folderName
        )

        var records = loadRecords()
        records.insert(record, at: 0)
        save(records: records)
        pruneExpired()
        return record
    }

    func beginObservationImageCapture() -> ObservationImageCapture {
        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        let inProgressURL = imagesURL.appendingPathComponent(".in-progress", isDirectory: true)
        try? fileManager.createDirectory(at: inProgressURL, withIntermediateDirectories: true)
        let tempURL = inProgressURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ObservationImageCapture(
            tempFolderURL: tempURL,
            imagesURL: imagesURL,
            folderNameProvider: { [weak self] endedAt in
                self?.uniqueObservationFolderName(endedAt: endedAt) ?? UUID().uuidString
            }
        )
    }

    func saveObservationImages(result: PostureResult, endedAt: Date = Date()) -> ObservationImageSave? {
        guard !result.sampleImageDatas.isEmpty || result.imageData != nil else { return nil }
        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)

        let folderName = uniqueObservationFolderName(endedAt: endedAt)
        let folderURL = imagesURL.appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var representativeImageFilename: String?
        for (index, imageData) in result.sampleImageDatas.enumerated() {
            let filename = String(format: "sample-%02d.jpg", index + 1)
            let url = folderURL.appendingPathComponent(filename)
            try? imageData.write(to: url, options: .atomic)
            if representativeImageFilename == nil {
                representativeImageFilename = "\(folderName)/\(filename)"
            }
        }

        if let imageData = result.imageData {
            let filename = "representative.jpg"
            let url = folderURL.appendingPathComponent(filename)
            try? imageData.write(to: url, options: .atomic)
            representativeImageFilename = "\(folderName)/\(filename)"
        }

        return ObservationImageSave(folderName: folderName, representativeImageFilename: representativeImageFilename)
    }

    func pruneExpired() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let records = loadRecords()
        let kept = records.filter { $0.createdAt >= cutoff }
        let removed = records.filter { $0.createdAt < cutoff }

        for record in removed {
            if let imageFilename = record.imageFilename {
                try? fileManager.removeItem(at: imageURL(filename: imageFilename))
            }
            if let imageFolderName = record.imageFolderName {
                try? fileManager.removeItem(at: imagesURL.appendingPathComponent(imageFolderName, isDirectory: true))
            }
        }

        pruneExpiredImageFolders(cutoff: cutoff)
        save(records: kept)
    }

    func deleteAllRecords() {
        try? fileManager.removeItem(at: imagesURL)
        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        save(records: [])
    }

    func imageURL(filename: String) -> URL {
        imagesURL.appendingPathComponent(filename)
    }

    private func uniqueObservationFolderName(endedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = formatter.string(from: endedAt)
        var folderName = baseName
        var suffix = 2
        while fileManager.fileExists(atPath: imagesURL.appendingPathComponent(folderName, isDirectory: true).path) {
            folderName = "\(baseName)-\(suffix)"
            suffix += 1
        }
        return folderName
    }

    private func pruneExpiredImageFolders(cutoff: Date) {
        guard let folderURLs = try? fileManager.contentsOfDirectory(
            at: imagesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        for folderURL in folderURLs {
            let values = try? folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let baseName = String(folderURL.lastPathComponent.prefix(19))
            guard let endedAt = formatter.date(from: baseName), endedAt < cutoff else { continue }
            try? fileManager.removeItem(at: folderURL)
        }
    }

    private func save(records: [ReminderRecord]) {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        guard let data = try? encoder.encode(sorted) else { return }
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? data.write(to: recordsURL, options: .atomic)
    }
}

final class CameraPostureSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "posture.session.queue")
    private let sampleQueue = DispatchQueue(label: "posture.sample.queue")
    private let sampleQueueKey = DispatchSpecificKey<Bool>()
    private let imageContext = CIContext()
    private let minimumUsableFrameBrightness = 0.015

    private var isConfigured = false
    private var isCapturing = false
    private var samples: [FramePostureSample] = []
    private var sampleImageDatas: [Data] = []
    private var bestImageData: Data?
    private var bestImageConfidence = 0.0
    private var startedAt = Date()
    private var requestedDuration: TimeInterval = 0
    private var minimumPhotoSamples = 1
    private var absenceCancelSampleCount = 2
    private var absentSampleStreak = 0
    private var cancelledBecauseAway = false
    private var waitingForSample = false
    private var sampleInterval: TimeInterval = 5
    private var nextSampleAt = Date.distantPast
    private var currentSampleStartedAt = Date.distantPast
    private var maximumExtensionUntil = Date.distantPast
    private var sampleImageHandler: ((Data) -> Void)?
    private var nextSampleHandler: ((Date?) -> Void)?
    private var completion: ((PostureResult) -> Void)?
    private var captureGeneration = 0

    override init() {
        super.init()
        sampleQueue.setSpecific(key: sampleQueueKey, value: true)
    }

    func observeFor(
        seconds: TimeInterval,
        minimumPhotos: Int,
        absenceCancelSampleCount: Int,
        sampleImageHandler: ((Data) -> Void)? = nil,
        nextSampleHandler: ((Date?) -> Void)? = nil,
        completion: @escaping (PostureResult) -> Void
    ) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture(
                seconds: seconds,
                minimumPhotos: minimumPhotos,
                absenceCancelSampleCount: absenceCancelSampleCount,
                sampleImageHandler: sampleImageHandler,
                nextSampleHandler: nextSampleHandler,
                completion: completion
            )
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startCapture(
                            seconds: seconds,
                            minimumPhotos: minimumPhotos,
                            absenceCancelSampleCount: absenceCancelSampleCount,
                            sampleImageHandler: sampleImageHandler,
                            nextSampleHandler: nextSampleHandler,
                            completion: completion
                        )
                    } else {
                        completion(Self.permissionDeniedResult())
                    }
                }
            }
        case .denied, .restricted:
            completion(Self.permissionDeniedResult())
        @unknown default:
            completion(Self.permissionDeniedResult())
        }
    }

    private func startCapture(
        seconds: TimeInterval,
        minimumPhotos: Int,
        absenceCancelSampleCount: Int,
        sampleImageHandler: ((Data) -> Void)?,
        nextSampleHandler: ((Date?) -> Void)?,
        completion: @escaping (PostureResult) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isCapturing else { return }

            do {
                try self.configureIfNeeded()
            } catch {
                DispatchQueue.main.async {
                    completion(PostureResult(
                        issues: [],
                        personPresent: false,
                        cancelledBecauseAway: false,
                        postureUnchanged: false,
                        observationDuration: 0,
                        framesAnalyzed: 0,
                        confidence: 0,
                        motionScore: 0,
                        detail: "无法启动摄像头：\(error.localizedDescription)",
                        imageData: nil,
                        sampleImageDatas: []
                    ))
                }
                return
            }

            let generation = self.sampleQueue.sync { () -> Int in
                self.samples.removeAll()
                self.sampleImageDatas.removeAll()
                self.bestImageData = nil
                self.bestImageConfidence = 0
                self.absentSampleStreak = 0
                self.cancelledBecauseAway = false
                self.waitingForSample = false
                self.minimumPhotoSamples = max(1, minimumPhotos)
                self.absenceCancelSampleCount = max(1, absenceCancelSampleCount)
                self.requestedDuration = seconds
                self.startedAt = Date()
                self.sampleInterval = max(3, seconds / Double(max(1, minimumPhotos - 1)))
                self.nextSampleAt = .distantPast
                self.maximumExtensionUntil = self.startedAt.addingTimeInterval(seconds + min(60, seconds * 0.35))
                self.captureGeneration += 1
                return self.captureGeneration
            }

            self.sampleImageHandler = sampleImageHandler
            self.nextSampleHandler = nextSampleHandler
            self.completion = completion
            self.isCapturing = true
            self.scheduleNextSample(after: 0, generation: generation)

            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.finishCaptureWhenReady(generation: generation)
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        else {
            session.commitConfiguration()
            throw NSError(domain: "PostureBreakReminder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "没有找到可用摄像头"
            ])
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "PostureBreakReminder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "摄像头输入不可用"
            ])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "PostureBreakReminder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "摄像头输出不可用"
            ])
        }
        session.addOutput(output)

        session.commitConfiguration()
        isConfigured = true
    }

    private func finishCapture() {
        sessionQueue.async { [weak self] in
            guard let self, self.isCapturing else { return }
            self.isCapturing = false
            if self.session.isRunning {
                self.session.stopRunning()
            }

            let result = self.sampleQueue.sync { () -> PostureResult in
                self.waitingForSample = false
                let result = self.makeResult()
                self.samples.removeAll()
                self.sampleImageDatas.removeAll()
                self.bestImageData = nil
                self.bestImageConfidence = 0
                return result
            }

            let completion = self.completion
            self.completion = nil
            self.sampleImageHandler = nil
            let nextSampleHandler = self.nextSampleHandler
            self.nextSampleHandler = nil

            DispatchQueue.main.async {
                nextSampleHandler?(nil)
                completion?(result)
            }
        }
    }

    func cancel() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isCapturing = false
            if self.session.isRunning {
                self.session.stopRunning()
            }

            self.sampleQueue.sync {
                self.waitingForSample = false
                self.samples.removeAll()
                self.sampleImageDatas.removeAll()
                self.bestImageData = nil
                self.bestImageConfidence = 0
                self.cancelledBecauseAway = false
                self.absentSampleStreak = 0
                self.nextSampleAt = .distantPast
                self.captureGeneration += 1
            }

            self.completion = nil
            self.sampleImageHandler = nil
            let nextSampleHandler = self.nextSampleHandler
            self.nextSampleHandler = nil
            DispatchQueue.main.async {
                nextSampleHandler?(nil)
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isCapturing else { return }
        let now = Date()
        guard waitingForSample, now >= nextSampleAt, !cancelledBecauseAway else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let brightness = frameBrightness(from: pixelBuffer)
        guard brightness >= minimumUsableFrameBrightness else { return }

        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .upMirrored,
            options: [:]
        )

        do {
            try handler.perform([bodyRequest, faceRequest])
            let bodyObservation = bodyRequest.results?.first
            let faceDetected = !(faceRequest.results ?? []).isEmpty
            let sample = analyze(bodyObservation: bodyObservation, faceDetected: faceDetected)
            waitingForSample = false
            samples.append(sample)
            nextSampleAt = now.addingTimeInterval(sampleInterval)

            if sample.personPresent {
                absentSampleStreak = 0
            } else {
                absentSampleStreak += 1
                if absentSampleStreak >= absenceCancelSampleCount {
                    cancelledBecauseAway = true
                    DispatchQueue.main.async { [weak self] in
                        self?.finishCapture()
                    }
                }
            }

            if let imageData = jpegData(from: pixelBuffer) {
                sampleImageDatas.append(imageData)
                sampleImageHandler?(imageData)
                if sample.personPresent, sample.confidence >= bestImageConfidence {
                    bestImageData = imageData
                    bestImageConfidence = sample.confidence
                }
            }

            stopSessionBetweenSamples()
            scheduleNextSampleAfterCurrent()
        } catch {
            // Dropping one failed frame is better than stopping the reminder loop.
        }
    }

    private func analyze(
        bodyObservation: VNHumanBodyPoseObservation?,
        faceDetected: Bool
    ) -> FramePostureSample {
        guard let bodyObservation else {
            return FramePostureSample(
                personPresent: faceDetected,
                bodyDetected: false,
                faceDetected: faceDetected,
                lowHeadScore: 0,
                hunchScore: 0,
                leanScore: 0,
                confidence: faceDetected ? 0.45 : 0,
                poseSignature: []
            )
        }

        let points = (try? bodyObservation.recognizedPoints(.all)) ?? [:]

        func point(_ name: VNHumanBodyPoseObservation.JointName, minimumConfidence: Float = 0.35) -> CGPoint? {
            guard let recognizedPoint = points[name], recognizedPoint.confidence >= minimumConfidence else {
                return nil
            }
            return recognizedPoint.location
        }

        let nose = point(.nose)
        let neck = point(.neck)
        let leftShoulder = point(.leftShoulder)
        let rightShoulder = point(.rightShoulder)
        let visibleCorePoints = [nose, neck, leftShoulder, rightShoulder].compactMap { $0 }
        let bodyDetected = visibleCorePoints.count >= 2
        let poseSignature = [
            nose,
            neck,
            leftShoulder,
            rightShoulder
        ].flatMap { candidate -> [Double] in
            guard let point = candidate else { return [-1, -1] }
            return [Double(point.x), Double(point.y)]
        }

        var lowHeadScore = 0.0
        if let nose, let neck {
            let headRise = Double(nose.y - neck.y)
            lowHeadScore = clamp((0.16 - headRise) / 0.16)
        } else if bodyDetected && !faceDetected {
            lowHeadScore = 0.55
        }

        var hunchScore = 0.0
        var leanScore = 0.0
        if let neck, let leftShoulder, let rightShoulder {
            let shoulderMidY = Double((leftShoulder.y + rightShoulder.y) / 2)
            let neckRise = Double(neck.y) - shoulderMidY
            hunchScore = clamp((0.075 - neckRise) / 0.075)

            let shoulderTilt = abs(Double(leftShoulder.y - rightShoulder.y))
            leanScore = clamp((shoulderTilt - 0.055) / 0.11)
        }

        let averageConfidence = visibleCorePoints.isEmpty ? 0.2 : min(1.0, 0.45 + Double(visibleCorePoints.count) * 0.12)

        return FramePostureSample(
            personPresent: bodyDetected || faceDetected,
            bodyDetected: bodyDetected,
            faceDetected: faceDetected,
            lowHeadScore: lowHeadScore,
            hunchScore: hunchScore,
            leanScore: leanScore,
            confidence: averageConfidence,
            poseSignature: poseSignature
        )
    }

    private func finishCaptureWhenReady(generation: Int) {
        let state = sampleQueue.sync {
            (
                isCurrent: isCapturing && captureGeneration == generation,
                shouldWait: !cancelledBecauseAway && samples.count < minimumPhotoSamples && Date() < maximumExtensionUntil,
                waitingForSample: waitingForSample
            )
        }
        guard state.isCurrent else { return }
        if state.shouldWait {
            if !state.waitingForSample {
                scheduleNextSample(after: 0, generation: generation)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(3, min(10, sampleInterval))) { [weak self] in
                self?.finishCaptureWhenReady(generation: generation)
            }
            return
        }

        finishCapture()
    }

    private func scheduleNextSampleAfterCurrent() {
        let state = isOnSampleQueue ? nextSampleDelayLocked() : sampleQueue.sync { nextSampleDelayLocked() }
        if let delay = state.delay {
            scheduleNextSample(after: delay, generation: state.generation)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.nextSampleHandler?(nil)
            }
        }
    }

    private var isOnSampleQueue: Bool {
        DispatchQueue.getSpecific(key: sampleQueueKey) == true
    }

    private func nextSampleDelayLocked() -> (delay: TimeInterval?, generation: Int) {
        guard isCapturing, !cancelledBecauseAway, samples.count < minimumPhotoSamples else {
            return (nil, captureGeneration)
        }
        let nextDueAt = startedAt.addingTimeInterval(sampleInterval * Double(samples.count))
        return (max(1, nextDueAt.timeIntervalSinceNow), captureGeneration)
    }

    private func scheduleNextSample(after delay: TimeInterval, generation: Int) {
        let dueAt = Date().addingTimeInterval(delay)
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentCapture(generation: generation) == true else { return }
            self?.nextSampleHandler?(dueAt)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startSingleSample(generation: generation)
        }
    }

    private func startSingleSample(generation: Int) {
        let shouldStart = sampleQueue.sync { () -> Bool in
            guard isCapturing, captureGeneration == generation, !cancelledBecauseAway, !waitingForSample else { return false }
            waitingForSample = true
            currentSampleStartedAt = Date()
            nextSampleAt = .distantPast
            return true
        }
        guard shouldStart else { return }

        sessionQueue.async { [weak self] in
            guard let self, self.isCapturing else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.handleSingleSampleTimeout(generation: generation)
        }
    }

    private func handleSingleSampleTimeout(generation: Int) {
        let shouldFinish = sampleQueue.sync { () -> Bool in
            guard isCapturing, captureGeneration == generation, waitingForSample else { return false }
            waitingForSample = false
            samples.append(FramePostureSample(
                personPresent: false,
                bodyDetected: false,
                faceDetected: false,
                lowHeadScore: 0,
                hunchScore: 0,
                leanScore: 0,
                confidence: 0,
                poseSignature: []
            ))
            absentSampleStreak += 1
            if absentSampleStreak >= absenceCancelSampleCount {
                cancelledBecauseAway = true
            }
            return cancelledBecauseAway
        }

        stopSessionBetweenSamples()
        if shouldFinish {
            finishCapture()
        } else {
            scheduleNextSampleAfterCurrent()
        }
    }

    private func isCurrentCapture(generation: Int) -> Bool {
        sampleQueue.sync {
            isCapturing && captureGeneration == generation
        }
    }

    private func stopSessionBetweenSamples() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func makeResult() -> PostureResult {
        guard !samples.isEmpty else {
            return PostureResult(
                issues: [],
                personPresent: false,
                cancelledBecauseAway: false,
                postureUnchanged: false,
                observationDuration: Date().timeIntervalSince(startedAt),
                framesAnalyzed: 0,
                confidence: 0,
                motionScore: 0,
                detail: "没有采集到可分析画面",
                imageData: nil,
                sampleImageDatas: sampleImageDatas
            )
        }

        let presentSamples = samples.filter(\.personPresent)
        let bodySamples = samples.filter(\.bodyDetected)
        let personPresent = !cancelledBecauseAway && presentSamples.count >= max(1, samples.count / 4)
        var issues = Set<PostureIssue>()
        let motionScore = maxPoseMotion(bodySamples)
        let postureUnchanged = bodySamples.count >= min(8, minimumPhotoSamples)
            && motionScore < 0.035
            && !cancelledBecauseAway

        if cancelledBecauseAway {
            let detail = "观察窗口内检测到你离开座位，本轮提醒已取消；采样 \(samples.count) 张；在位 \(presentSamples.count) 张。"
            return PostureResult(
                issues: [],
                personPresent: false,
                cancelledBecauseAway: true,
                postureUnchanged: false,
                observationDuration: Date().timeIntervalSince(startedAt),
                framesAnalyzed: samples.count,
                confidence: 0,
                motionScore: 0,
                detail: detail,
                imageData: bestImageData,
                sampleImageDatas: sampleImageDatas
            )
        }

        if bodySamples.count >= 2 {
            if proportion(bodySamples, where: { $0.lowHeadScore >= 0.58 }) >= 0.45 {
                issues.insert(.lowHead)
            }
            if proportion(bodySamples, where: { $0.hunchScore >= 0.58 }) >= 0.45 {
                issues.insert(.hunchedBack)
            }
            if proportion(bodySamples, where: { $0.leanScore >= 0.55 }) >= 0.45 {
                issues.insert(.leaning)
            }
        }

        if postureUnchanged {
            issues.insert(.unchanged)
        }

        let confidence = samples.map(\.confidence).reduce(0, +) / Double(samples.count)
        let minutes = max(1, Int(Date().timeIntervalSince(startedAt) / 60))
        let detail = "观察 \(minutes) 分钟；采样 \(samples.count) 张；人体 \(bodySamples.count) 张；在位 \(presentSamples.count) 张；最大姿态变化 \(Int(motionScore * 1000) / 10)%；置信度 \(Int(confidence * 100))%"

        return PostureResult(
            issues: issues,
            personPresent: personPresent,
            cancelledBecauseAway: false,
            postureUnchanged: postureUnchanged,
            observationDuration: Date().timeIntervalSince(startedAt),
            framesAnalyzed: samples.count,
            confidence: confidence,
            motionScore: motionScore,
            detail: detail,
            imageData: bestImageData,
            sampleImageDatas: sampleImageDatas
        )
    }

    private static func permissionDeniedResult() -> PostureResult {
        PostureResult(
            issues: [],
            personPresent: false,
            cancelledBecauseAway: false,
            postureUnchanged: false,
            observationDuration: 0,
            framesAnalyzed: 0,
            confidence: 0,
            motionScore: 0,
            detail: "没有摄像头权限。请到 系统设置 > 隐私与安全性 > 相机 允许本应用访问。",
            imageData: nil,
            sampleImageDatas: []
        )
    }

    private func proportion(
        _ samples: [FramePostureSample],
        where predicate: (FramePostureSample) -> Bool
    ) -> Double {
        guard !samples.isEmpty else { return 0 }
        let matched = samples.filter(predicate).count
        return Double(matched) / Double(samples.count)
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func maxPoseMotion(_ samples: [FramePostureSample]) -> Double {
        guard let baseline = samples.first?.poseSignature, !baseline.isEmpty else { return 1 }
        return samples.dropFirst().map { poseDistance(baseline, $0.poseSignature) }.max() ?? 0
    }

    private func poseDistance(_ first: [Double], _ second: [Double]) -> Double {
        let count = min(first.count, second.count)
        guard count > 0 else { return 1 }

        var total = 0.0
        var matched = 0
        for index in 0..<count {
            guard first[index] >= 0, second[index] >= 0 else { continue }
            total += abs(first[index] - second[index])
            matched += 1
        }

        guard matched > 0 else { return 1 }
        return total / Double(matched)
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.upMirrored)
        guard let cgImage = imageContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    private func frameBrightness(from pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return 0 }

        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        let xSteps = 16
        let ySteps = 9
        var total = 0.0
        var count = 0

        for yStep in 0..<ySteps {
            let y = min(height - 1, max(0, height * (yStep * 2 + 1) / (ySteps * 2)))
            for xStep in 0..<xSteps {
                let x = min(width - 1, max(0, width * (xStep * 2 + 1) / (xSteps * 2)))
                let offset = y * bytesPerRow + x * 4
                let blue = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let red = Double(pixels[offset + 2])
                total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                count += 1
            }
        }

        return count == 0 ? 0 : total / Double(count) / 255
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class MainWindowController: NSWindowController {
    var onCheckNow: (() -> Void)?
    var onToggleMonitoring: (() -> Void)?
    var onPauseOneHour: (() -> Void)?
    var onPauseTomorrow: (() -> Void)?
    var onMarkActive: (() -> Void)?
    var onOpenHistoryFolder: (() -> Void)?
    var onDeleteAllHistory: (() -> Void)?
    var onRetentionChanged: ((Int) -> Void)?
    var onObservationTimeChanged: ((ObservationTimeMode, Int, Int, Int, Int) -> Void)?
    var onPromptSaved: ((String) -> Void)?
    var onReminderDeliveryModeChanged: ((ReminderDeliveryMode) -> Void)?
    var onReminderTriggerModeChanged: ((ReminderTriggerMode) -> Void)?
    var onSoundModeChanged: ((ReminderSoundMode) -> Void)?
    var onSelectAudio: (() -> Void)?
    var onTestSound: (() -> Void)?
    var onResetPrompt: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let nextCheckLabel = NSTextField(labelWithString: "")
    private let nextPhotoLabel = NSTextField(labelWithString: "")
    private let retentionDaysField = NSTextField()
    private let observationModePopup = NSPopUpButton()
    private let minimumDelayField = NSTextField()
    private let maximumDelayField = NSTextField()
    private let minimumPhotosField = NSTextField()
    private let observationToLabel = NSTextField(labelWithString: "到")
    private let observationUnitLabel = NSTextField(labelWithString: "分钟内拍够至少 10 张")
    private let deliveryModePopup = NSPopUpButton()
    private let triggerModePopup = NSPopUpButton()
    private let soundModePopup = NSPopUpButton()
    private let audioPathLabel = NSTextField(labelWithString: "未选择自定义音频")
    private let promptTextView = NSTextView()
    private let toggleButton = NSButton(title: "暂停提醒", target: nil, action: nil)
    private let historyListView = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "还没有提醒记录")
    private var historyListConstraints: [NSLayoutConstraint] = []
    private var historyStore: HistoryStore?
    private var preferences: ReminderPreferences?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "不要久坐"
        window.minSize = NSSize(width: 820, height: 680)
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(historyStore: HistoryStore, preferences: ReminderPreferences) {
        self.historyStore = historyStore
        self.preferences = preferences
        retentionDaysField.stringValue = "\(historyStore.retentionDays)"

        observationModePopup.removeAllItems()
        for mode in ObservationTimeMode.allCases {
            observationModePopup.addItem(withTitle: mode.title)
            observationModePopup.lastItem?.representedObject = mode.rawValue
        }
        updateObservationTimeFields(
            mode: preferences.observationTimeMode,
            fixed: preferences.fixedObservationWindowMinutes,
            minimum: preferences.minimumObservationWindowMinutes,
            maximum: preferences.maximumObservationWindowMinutes
        )
        minimumPhotosField.stringValue = "\(preferences.minimumObservationPhotos)"

        deliveryModePopup.removeAllItems()
        for mode in ReminderDeliveryMode.allCases {
            deliveryModePopup.addItem(withTitle: mode.title)
            deliveryModePopup.lastItem?.representedObject = mode.rawValue
        }
        updateReminderDeliveryMode(preferences.reminderDeliveryMode)

        triggerModePopup.removeAllItems()
        for mode in ReminderTriggerMode.allCases {
            triggerModePopup.addItem(withTitle: mode.title)
            triggerModePopup.lastItem?.representedObject = mode.rawValue
        }
        updateReminderTriggerMode(preferences.reminderTriggerMode)

        soundModePopup.removeAllItems()
        for mode in ReminderSoundMode.allCases {
            soundModePopup.addItem(withTitle: mode.title)
            soundModePopup.lastItem?.representedObject = mode.rawValue
        }
        if let item = soundModePopup.itemArray.first(where: { $0.representedObject as? String == preferences.soundMode.rawValue }) {
            soundModePopup.select(item)
        }
        promptTextView.string = preferences.promptTemplate
        updateAudioPathLabel(path: preferences.customAudioPath)
    }

    func updateState(
        isMonitoring: Bool,
        pausedUntil: Date?,
        nextCheckAt: Date?,
        nextPhotoAt: Date?,
        isObserving: Bool,
        waitingForReturn: Bool
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let minimumPhotos = preferences?.minimumObservationPhotos ?? 10

        if isObserving {
            statusLabel.stringValue = "状态：观察中，正在窗口内分散采集至少 \(minimumPhotos) 张"
            toggleButton.title = "暂停提醒"
        } else if waitingForReturn {
            statusLabel.stringValue = "状态：等待你回到电脑前"
            toggleButton.title = "暂停提醒"
        } else if isMonitoring {
            statusLabel.stringValue = "状态：运行中"
            toggleButton.title = "暂停提醒"
        } else if let pausedUntil {
            statusLabel.stringValue = "状态：已暂停到 \(formatter.string(from: pausedUntil))"
            toggleButton.title = "恢复提醒"
        } else {
            statusLabel.stringValue = "状态：已暂停"
            toggleButton.title = "恢复提醒"
        }

        if let nextCheckAt, isObserving {
            nextCheckLabel.stringValue = "观察结束：\(formatter.string(from: nextCheckAt))"
        } else if let nextCheckAt, waitingForReturn {
            nextCheckLabel.stringValue = "下次回席探测：\(formatter.string(from: nextCheckAt))"
        } else if let nextCheckAt, isMonitoring {
            nextCheckLabel.stringValue = "下次观察开始：\(formatter.string(from: nextCheckAt))"
        } else {
            nextCheckLabel.stringValue = "下次检查：暂停中"
        }

        if let nextPhotoAt, isObserving || waitingForReturn {
            nextPhotoLabel.stringValue = "下次拍照：\(formatter.string(from: nextPhotoAt))"
        } else if isObserving || waitingForReturn {
            nextPhotoLabel.stringValue = "下次拍照：等待可用画面"
        } else {
            nextPhotoLabel.stringValue = "下次拍照：未观察"
        }
    }

    func reloadHistory(records: [ReminderRecord], historyStore: HistoryStore) {
        NSLayoutConstraint.deactivate(historyListConstraints)
        historyListConstraints.removeAll()
        historyListView.subviews.forEach { view in
            view.removeFromSuperview()
        }

        if records.isEmpty {
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            historyListView.addSubview(emptyLabel)
            historyListConstraints = [
                emptyLabel.leadingAnchor.constraint(equalTo: historyListView.leadingAnchor),
                emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: historyListView.trailingAnchor),
                emptyLabel.topAnchor.constraint(equalTo: historyListView.topAnchor),
                emptyLabel.bottomAnchor.constraint(equalTo: historyListView.bottomAnchor)
            ]
            NSLayoutConstraint.activate(historyListConstraints)
            return
        }

        var previousBottomAnchor: NSLayoutYAxisAnchor = historyListView.topAnchor
        var topSpacing: CGFloat = 0
        var constraints: [NSLayoutConstraint] = []

        for record in records {
            let recordView = makeRecordView(record: record, historyStore: historyStore)
            historyListView.addSubview(recordView)
            constraints.append(contentsOf: [
                recordView.leadingAnchor.constraint(equalTo: historyListView.leadingAnchor),
                recordView.trailingAnchor.constraint(equalTo: historyListView.trailingAnchor),
                recordView.topAnchor.constraint(equalTo: previousBottomAnchor, constant: topSpacing)
            ])
            previousBottomAnchor = recordView.bottomAnchor
            topSpacing = 12
        }

        constraints.append(previousBottomAnchor.constraint(equalTo: historyListView.bottomAnchor))
        historyListConstraints = constraints
        NSLayoutConstraint.activate(historyListConstraints)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let scrollContainer = NSScrollView()
        scrollContainer.hasVerticalScroller = true
        scrollContainer.hasHorizontalScroller = false
        scrollContainer.drawsBackground = false
        scrollContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollContainer)

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.documentView = documentView

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(root)

        NSLayoutConstraint.activate([
            scrollContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: documentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            root.widthAnchor.constraint(equalTo: scrollContainer.contentView.widthAnchor)
        ])

        let title = NSTextField(labelWithString: "姿态与久坐提醒")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.alignment = .left

        let subtitle = NSTextField(labelWithString: "本地短时摄像头识别；提醒记录和截图只保存在这台电脑。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .left

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.spacing = 4
        header.alignment = .leading
        addFullWidth(header, to: root)

        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nextCheckLabel.textColor = .secondaryLabelColor
        nextPhotoLabel.textColor = .secondaryLabelColor

        addFullWidth(settingsSection(title: "当前状态", rows: [
            settingsRow(label: "状态", controls: [statusLabel]),
            settingsRow(label: "观察时间", controls: [nextCheckLabel]),
            settingsRow(label: "拍照时间", controls: [nextPhotoLabel])
        ]), to: root)

        let checkButton = button(title: "立即检查姿态", action: #selector(checkNow))
        toggleButton.target = self
        toggleButton.action = #selector(toggleMonitoring)
        let pauseHourButton = button(title: "暂停 1 小时", action: #selector(pauseOneHour))
        let pauseTomorrowButton = button(title: "暂停到明天", action: #selector(pauseTomorrow))
        let activeButton = button(title: "标记为已活动", action: #selector(markActive))
        addFullWidth(settingsSection(title: "主要操作", rows: [
            settingsRow(label: "操作", controls: [checkButton, toggleButton, pauseHourButton, pauseTomorrowButton, activeButton])
        ]), to: root)

        retentionDaysField.placeholderString = "7"
        retentionDaysField.alignment = .right
        retentionDaysField.formatter = positiveIntegerFormatter()
        retentionDaysField.translatesAutoresizingMaskIntoConstraints = false
        retentionDaysField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let daysLabel = NSTextField(labelWithString: "天")
        let saveRetentionButton = button(title: "保存保留天数", action: #selector(retentionChanged))
        let openFolderButton = button(title: "打开保存目录", action: #selector(openHistoryFolder))
        let deleteAllButton = button(title: "清空历史", action: #selector(deleteAllHistory))
        addFullWidth(settingsSection(title: "历史保留", rows: [
            settingsRow(label: "图片保留", controls: [retentionDaysField, daysLabel, saveRetentionButton]),
            settingsRow(label: "保存目录", controls: [openFolderButton, deleteAllButton])
        ]), to: root)

        observationModePopup.target = self
        observationModePopup.action = #selector(observationModeChanged)
        minimumDelayField.placeholderString = "25"
        maximumDelayField.placeholderString = "45"
        minimumPhotosField.placeholderString = "10"
        for field in [minimumDelayField, maximumDelayField, minimumPhotosField] {
            field.alignment = .right
            field.formatter = positiveIntegerFormatter()
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        }
        let saveObservationButton = button(title: "保存观察设置", action: #selector(observationTimeChanged))
        addFullWidth(settingsSection(title: "观察采样", rows: [
            settingsRow(label: "时间", controls: [
                observationModePopup,
                minimumDelayField,
                observationToLabel,
                maximumDelayField,
                observationUnitLabel
            ]),
            settingsRow(label: "最少照片", controls: [minimumPhotosField, NSTextField(labelWithString: "张")]),
            settingsRow(label: "应用", controls: [saveObservationButton])
        ]), to: root)

        deliveryModePopup.target = self
        deliveryModePopup.action = #selector(reminderDeliveryModeChanged)
        triggerModePopup.target = self
        triggerModePopup.action = #selector(reminderTriggerModeChanged)
        soundModePopup.target = self
        soundModePopup.action = #selector(soundModeChanged)
        audioPathLabel.textColor = .secondaryLabelColor
        audioPathLabel.lineBreakMode = .byTruncatingMiddle
        audioPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let selectAudioButton = button(title: "选择音频", action: #selector(selectAudio))
        let testSoundButton = button(title: "测试声音", action: #selector(testSound))
        addFullWidth(settingsSection(title: "提醒方式", rows: [
            settingsRow(label: "触发方式", controls: [triggerModePopup]),
            settingsRow(label: "强提醒", controls: [deliveryModePopup]),
            settingsRow(label: "声音", controls: [soundModePopup, selectAudioButton, testSoundButton, audioPathLabel])
        ]), to: root)

        let promptHint = NSTextField(labelWithString: "可用变量：{issues}=问题，{minutes}=观察分钟，{sampleCount}=采样张数，{motionScore}=姿态变化，{detail}=观察详情，{reason}=触发方式")
        promptHint.font = .systemFont(ofSize: 12)
        promptHint.textColor = .secondaryLabelColor
        promptHint.lineBreakMode = .byWordWrapping
        promptHint.maximumNumberOfLines = 2

        promptTextView.font = .systemFont(ofSize: 15)
        promptTextView.isRichText = false
        promptTextView.allowsUndo = true
        promptTextView.isEditable = true
        promptTextView.isSelectable = true
        promptTextView.importsGraphics = false
        promptTextView.usesFindPanel = true
        promptTextView.backgroundColor = .textBackgroundColor
        promptTextView.textColor = .textColor
        promptTextView.insertionPointColor = .controlAccentColor
        promptTextView.textContainerInset = NSSize(width: 12, height: 10)
        promptTextView.minSize = NSSize(width: 0, height: 120)
        promptTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.autoresizingMask = [.width]
        promptTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        promptTextView.textContainer?.widthTracksTextView = true
        let promptScroll = NSScrollView()
        promptScroll.hasVerticalScroller = true
        promptScroll.hasHorizontalScroller = false
        promptScroll.borderType = .bezelBorder
        promptScroll.drawsBackground = true
        promptScroll.backgroundColor = .textBackgroundColor
        promptScroll.documentView = promptTextView
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true

        let savePromptButton = button(title: "保存文案", action: #selector(savePrompt))
        let resetPromptButton = button(title: "恢复默认文案", action: #selector(resetPrompt))
        addFullWidth(settingsSection(title: "提醒文案", rows: [
            promptHint,
            promptEditorRow(promptScroll: promptScroll),
            settingsRow(label: "操作", controls: [savePromptButton, resetPromptButton])
        ]), to: root)

        historyListView.translatesAutoresizingMaskIntoConstraints = false
        historyListView.setContentHuggingPriority(.required, for: .vertical)
        historyListView.setContentCompressionResistancePriority(.required, for: .vertical)

        addFullWidth(historySection(historyView: historyListView), to: root)
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right)
        ])
    }

    private func settingsSection(title: String, rows: [NSView]) -> NSView {
        let titleLabel = label(title, size: 13, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: rows)
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.alignment = .width

        guard let boxContentView = box.contentView else { return NSStackView(views: [titleLabel]) }
        boxContentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: boxContentView.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: boxContentView.trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: boxContentView.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: boxContentView.bottomAnchor, constant: -12)
        ])

        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(titleLabel)
        section.addSubview(box)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: section.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: section.topAnchor),
            box.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            box.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            box.bottomAnchor.constraint(equalTo: section.bottomAnchor)
        ])
        return section
    }

    private func historySection(historyView: NSView) -> NSView {
        let titleLabel = label("提醒历史", size: 13, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentHuggingPriority(.required, for: .vertical)
        section.setContentCompressionResistancePriority(.required, for: .vertical)
        section.addSubview(titleLabel)
        section.addSubview(historyView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: section.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: section.topAnchor),
            historyView.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            historyView.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            historyView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            historyView.bottomAnchor.constraint(equalTo: section.bottomAnchor)
        ])
        return section
    }

    private func settingsRow(label text: String, controls: [NSView]) -> NSView {
        let titleLabel = label(text, size: 13)
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 112).isActive = true
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let controlsStack = NSStackView(views: controls)
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 8
        controlsStack.alignment = .centerY
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.setHuggingPriority(.defaultLow, for: .horizontal)
        controlsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLabel)
        row.addSubview(controlsStack)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: controlsStack.centerYAnchor),
            controlsStack.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            controlsStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            controlsStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            controlsStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4)
        ])
        return row
    }

    private func promptEditorRow(promptScroll: NSScrollView) -> NSView {
        let titleLabel = label("模板", size: 13)
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 112).isActive = true

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLabel)
        row.addSubview(promptScroll)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: promptScroll.topAnchor, constant: 8),
            promptScroll.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            promptScroll.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            promptScroll.topAnchor.constraint(equalTo: row.topAnchor),
            promptScroll.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    private func makeRecordView(record: ReminderRecord, historyStore: HistoryStore) -> NSView {
        let container = NSBox()
        container.boxType = .custom
        container.cornerRadius = 8
        container.borderWidth = 1
        container.borderColor = .separatorColor
        container.fillColor = .controlBackgroundColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        if let filename = record.imageFilename {
            imageView.image = NSImage(contentsOf: historyStore.imageURL(filename: filename))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let time = label(formatter.string(from: record.createdAt), size: 13, weight: .medium)
        let issues = label("提醒原因：\(record.issueText)", size: 15, weight: .semibold)
        let trigger = label("触发方式：\(record.reason)", size: 13)
        let detail = label(record.detail, size: 13)
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byWordWrapping

        var textViews: [NSView] = [time, issues, trigger, detail]
        if let imageFolderName = record.imageFolderName {
            textViews.append(label("采样文件夹：\(imageFolderName)", size: 12))
        }

        let textStack = NSStackView(views: textViews)
        textStack.orientation = .vertical
        textStack.spacing = 6
        textStack.alignment = .leading

        let row = NSStackView(views: [imageView, textStack])
        row.orientation = .horizontal
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.contentView?.addSubview(row)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: row.widthAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 180),
            imageView.heightAnchor.constraint(equalToConstant: 120),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            row.leadingAnchor.constraint(equalTo: container.contentView!.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.contentView!.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.contentView!.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.contentView!.bottomAnchor)
        ])

        return container
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = weight == .regular ? .secondaryLabelColor : .labelColor
        return field
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func positiveIntegerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 3650
        formatter.allowsFloats = false
        return formatter
    }

    func updateAudioPathLabel(path: String?) {
        if let path, !path.isEmpty {
            audioPathLabel.stringValue = URL(fileURLWithPath: path).lastPathComponent
            audioPathLabel.toolTip = path
        } else {
            audioPathLabel.stringValue = "未选择自定义音频"
            audioPathLabel.toolTip = nil
        }
    }

    func updateSoundMode(_ mode: ReminderSoundMode) {
        if let item = soundModePopup.itemArray.first(where: { $0.representedObject as? String == mode.rawValue }) {
            soundModePopup.select(item)
        }
    }

    func updateReminderDeliveryMode(_ mode: ReminderDeliveryMode) {
        if let item = deliveryModePopup.itemArray.first(where: { $0.representedObject as? String == mode.rawValue }) {
            deliveryModePopup.select(item)
        }
    }

    func updateReminderTriggerMode(_ mode: ReminderTriggerMode) {
        if let item = triggerModePopup.itemArray.first(where: { $0.representedObject as? String == mode.rawValue }) {
            triggerModePopup.select(item)
        }
    }

    func updateObservationTimeFields(mode: ObservationTimeMode, fixed: Int, minimum: Int, maximum: Int) {
        if let item = observationModePopup.itemArray.first(where: { $0.representedObject as? String == mode.rawValue }) {
            observationModePopup.select(item)
        }

        switch mode {
        case .fixed:
            minimumDelayField.stringValue = "\(fixed)"
            maximumDelayField.stringValue = "\(max(minimum, maximum))"
        case .random:
            minimumDelayField.stringValue = "\(minimum)"
            maximumDelayField.stringValue = "\(max(minimum, maximum))"
        }
        updateObservationModeControls()
    }

    func updatePromptTemplate(_ text: String) {
        promptTextView.string = text
    }

    @objc private func checkNow() { onCheckNow?() }
    @objc private func toggleMonitoring() { onToggleMonitoring?() }
    @objc private func pauseOneHour() { onPauseOneHour?() }
    @objc private func pauseTomorrow() { onPauseTomorrow?() }
    @objc private func markActive() { onMarkActive?() }
    @objc private func openHistoryFolder() { onOpenHistoryFolder?() }

    @objc private func savePrompt() {
        onPromptSaved?(promptTextView.string)
    }

    @objc private func resetPrompt() {
        onResetPrompt?()
    }

    @objc private func soundModeChanged() {
        let raw = soundModePopup.selectedItem?.representedObject as? String
        onSoundModeChanged?(ReminderSoundMode(rawValue: raw ?? "") ?? .speech)
    }

    @objc private func reminderDeliveryModeChanged() {
        let raw = deliveryModePopup.selectedItem?.representedObject as? String
        onReminderDeliveryModeChanged?(ReminderDeliveryMode(rawValue: raw ?? "") ?? .speechAndPopup)
    }

    @objc private func reminderTriggerModeChanged() {
        let raw = triggerModePopup.selectedItem?.representedObject as? String
        onReminderTriggerModeChanged?(ReminderTriggerMode(rawValue: raw ?? "") ?? .personVisible)
    }

    @objc private func observationModeChanged() {
        guard let preferences else {
            updateObservationModeControls()
            return
        }

        switch selectedObservationTimeMode() {
        case .fixed:
            minimumDelayField.stringValue = "\(preferences.fixedObservationWindowMinutes)"
        case .random:
            minimumDelayField.stringValue = "\(preferences.minimumObservationWindowMinutes)"
            maximumDelayField.stringValue = "\(preferences.maximumObservationWindowMinutes)"
        }
        updateObservationModeControls()
    }

    @objc private func selectAudio() {
        onSelectAudio?()
    }

    @objc private func testSound() {
        onTestSound?()
    }

    @objc private func retentionChanged() {
        onRetentionChanged?(max(1, retentionDaysField.integerValue))
    }

    @objc private func observationTimeChanged() {
        let mode = selectedObservationTimeMode()
        let primary = max(1, minimumDelayField.integerValue)
        let minimumPhotos = max(1, minimumPhotosField.integerValue)
        minimumPhotosField.stringValue = "\(minimumPhotos)"
        let savedMinimum = preferences?.minimumObservationWindowMinutes ?? primary
        let savedMaximum = preferences?.maximumObservationWindowMinutes ?? max(savedMinimum, primary)

        switch mode {
        case .fixed:
            minimumDelayField.stringValue = "\(primary)"
            onObservationTimeChanged?(mode, primary, savedMinimum, max(savedMinimum, savedMaximum), minimumPhotos)
        case .random:
            let maximum = max(primary, maximumDelayField.integerValue)
            minimumDelayField.stringValue = "\(primary)"
            maximumDelayField.stringValue = "\(maximum)"
            let fixed = preferences?.fixedObservationWindowMinutes ?? primary
            onObservationTimeChanged?(mode, fixed, primary, maximum, minimumPhotos)
        }
        updateObservationModeControls()
    }

    @objc private func deleteAllHistory() {
        let alert = NSAlert()
        alert.messageText = "清空所有提醒历史？"
        alert.informativeText = "这会删除本地保存的历史记录和截图。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            onDeleteAllHistory?()
        }
    }

    private func selectedObservationTimeMode() -> ObservationTimeMode {
        let raw = observationModePopup.selectedItem?.representedObject as? String
        return ObservationTimeMode(rawValue: raw ?? "") ?? .random
    }

    private func updateObservationModeControls() {
        let isRandom = selectedObservationTimeMode() == .random
        observationToLabel.isHidden = !isRandom
        maximumDelayField.isHidden = !isRandom
        let minimumPhotos = max(1, minimumPhotosField.integerValue == 0 ? (preferences?.minimumObservationPhotos ?? 10) : minimumPhotosField.integerValue)
        observationUnitLabel.stringValue = "分钟内拍够至少 \(minimumPhotos) 张"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = PostureConfig()
    private let sampler = CameraPostureSampler()
    private let speaker = AVSpeechSynthesizer()
    private let historyStore = HistoryStore()
    private let preferences = ReminderPreferences()
    private var audioPlayer: AVAudioPlayer?

    private var windowController: MainWindowController?
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var monitoringEnabled = true
    private var pausedUntil: Date?
    private var isObserving = false
    private var waitingForReturn = false
    private var lastBreakAcknowledged = Date()
    private var nextCheckAt: Date?
    private var nextPhotoAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        createApplicationMenu()
        createWindow()
        createStatusItem()
        historyStore.pruneExpired()
        scheduleNextConfiguredCheck()
        refreshUI()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    private func createApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let openWindowItem = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindowFromMenu), keyEquivalent: "o")
        openWindowItem.target = self
        appMenu.addItem(openWindowItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 不要久坐", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 不要久坐", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "粘贴并匹配样式", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V"))
        editMenu.addItem(NSMenuItem(title: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(NSMenuItem.separator())

        let substitutionsItem = NSMenuItem(title: "替换", action: nil, keyEquivalent: "")
        let substitutionsMenu = NSMenu(title: "替换")
        substitutionsMenu.addItem(NSMenuItem(title: "显示替换", action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), keyEquivalent: ""))
        substitutionsMenu.addItem(NSMenuItem.separator())
        substitutionsMenu.addItem(NSMenuItem(title: "智能复制/粘贴", action: #selector(NSTextView.toggleSmartInsertDelete(_:)), keyEquivalent: ""))
        substitutionsMenu.addItem(NSMenuItem(title: "智能引号", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: ""))
        substitutionsMenu.addItem(NSMenuItem(title: "智能破折号", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: ""))
        substitutionsItem.submenu = substitutionsMenu
        editMenu.addItem(substitutionsItem)

        let transformationsItem = NSMenuItem(title: "转换", action: nil, keyEquivalent: "")
        let transformationsMenu = NSMenu(title: "转换")
        transformationsMenu.addItem(NSMenuItem(title: "转为大写", action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: ""))
        transformationsMenu.addItem(NSMenuItem(title: "转为小写", action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: ""))
        transformationsMenu.addItem(NSMenuItem(title: "首字母大写", action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: ""))
        transformationsItem.submenu = transformationsMenu
        editMenu.addItem(transformationsItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func createWindow() {
        let controller = MainWindowController()
        controller.configure(historyStore: historyStore, preferences: preferences)
        controller.onCheckNow = { [weak self] in self?.runPostureCheck(reason: "手动检查", forced: true) }
        controller.onToggleMonitoring = { [weak self] in self?.toggleMonitoring() }
        controller.onPauseOneHour = { [weak self] in self?.pause(for: self?.config.shortPauseInterval ?? 3600) }
        controller.onPauseTomorrow = { [weak self] in self?.pauseUntilTomorrow() }
        controller.onMarkActive = { [weak self] in self?.markBreakDone() }
        controller.onOpenHistoryFolder = { [weak self] in self?.openHistoryFolder() }
        controller.onDeleteAllHistory = { [weak self] in
            self?.historyStore.deleteAllRecords()
            self?.refreshUI()
        }
        controller.onRetentionChanged = { [weak self] days in
            self?.historyStore.retentionDays = days
            self?.historyStore.pruneExpired()
            self?.refreshUI()
        }
        controller.onObservationTimeChanged = { [weak self] mode, fixed, minimum, maximum, minimumPhotos in
            guard let self else { return }
            self.preferences.observationTimeMode = mode
            self.preferences.fixedObservationWindowMinutes = fixed
            self.preferences.minimumObservationWindowMinutes = minimum
            self.preferences.maximumObservationWindowMinutes = maximum
            self.preferences.minimumObservationPhotos = minimumPhotos
            self.windowController?.updateObservationTimeFields(mode: mode, fixed: fixed, minimum: minimum, maximum: maximum)
            self.restartObservationWithCurrentSettings()
            self.refreshUI()
        }
        controller.onPromptSaved = { [weak self] text in
            guard let self else { return }
            self.preferences.promptTemplate = text
            self.clearCustomAudioForPromptChange()
        }
        controller.onReminderDeliveryModeChanged = { [weak self] mode in
            self?.preferences.reminderDeliveryMode = mode
        }
        controller.onReminderTriggerModeChanged = { [weak self] mode in
            guard let self else { return }
            self.preferences.reminderTriggerMode = mode
            if self.isObserving || self.waitingForReturn {
                self.restartObservationWithCurrentSettings()
            }
            self.refreshUI()
        }
        controller.onSoundModeChanged = { [weak self] mode in
            self?.preferences.soundMode = mode
        }
        controller.onSelectAudio = { [weak self] in
            self?.selectCustomAudio()
        }
        controller.onTestSound = { [weak self] in
            self?.testReminderSound()
        }
        controller.onResetPrompt = { [weak self] in
            guard let self else { return }
            self.preferences.promptTemplate = ReminderPreferences.defaultPromptTemplate
            self.windowController?.updatePromptTemplate(self.preferences.promptTemplate)
            self.clearCustomAudioForPromptChange()
        }
        windowController = controller
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Posture"
        item.button?.toolTip = "姿态活动提醒"
        statusItem = item
        refreshMenu()
    }

    private func refreshUI() {
        refreshMenu()
        let records = historyStore.loadRecords()
        windowController?.updateState(
            isMonitoring: monitoringEnabled,
            pausedUntil: pausedUntil,
            nextCheckAt: nextCheckAt,
            nextPhotoAt: nextPhotoAt,
            isObserving: isObserving,
            waitingForReturn: waitingForReturn
        )
        windowController?.reloadHistory(records: records, historyStore: historyStore)
    }

    private func refreshMenu() {
        let menu = NSMenu()
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"

        let stateTitle: String
        if isObserving {
            stateTitle = "状态：观察中"
        } else if waitingForReturn {
            stateTitle = "状态：等待回席"
        } else if monitoringEnabled {
            stateTitle = "状态：运行中"
        } else if let pausedUntil {
            stateTitle = "状态：暂停到 \(formatter.string(from: pausedUntil))"
        } else {
            stateTitle = "状态：已暂停"
        }
        menu.addItem(NSMenuItem(title: stateTitle, action: nil, keyEquivalent: ""))

        if let nextCheckAt, isObserving {
            menu.addItem(NSMenuItem(title: "观察结束：\(formatter.string(from: nextCheckAt))", action: nil, keyEquivalent: ""))
            if let nextPhotoAt {
                menu.addItem(NSMenuItem(title: "下次拍照：\(formatter.string(from: nextPhotoAt))", action: nil, keyEquivalent: ""))
            }
        } else if let nextCheckAt, waitingForReturn {
            menu.addItem(NSMenuItem(title: "回席探测：\(formatter.string(from: nextCheckAt))", action: nil, keyEquivalent: ""))
        } else if let nextCheckAt, monitoringEnabled {
            menu.addItem(NSMenuItem(title: "下次观察开始：\(formatter.string(from: nextCheckAt))", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "打开主窗口", action: #selector(showMainWindowFromMenu), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "立即检查姿态", action: #selector(runManualCheck), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: monitoringEnabled ? "暂停提醒" : "恢复提醒", action: #selector(toggleMonitoring), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "暂停 1 小时", action: #selector(pauseOneHour), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "标记为已活动", action: #selector(markBreakDone), keyEquivalent: "d"))

        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    @objc private func showMainWindowFromMenu() {
        showMainWindow()
    }

    private func showMainWindow() {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func runManualCheck() {
        runPostureCheck(reason: "手动检查", forced: true)
    }

    @objc private func toggleMonitoring() {
        if monitoringEnabled {
            monitoringEnabled = false
            pausedUntil = nil
            isObserving = false
            waitingForReturn = false
            timer?.invalidate()
            timer = nil
            nextCheckAt = nil
            nextPhotoAt = nil
            sampler.cancel()
        } else {
            resumeMonitoring()
        }
        refreshUI()
    }

    @objc private func pauseOneHour() {
        pause(for: config.shortPauseInterval)
    }

    private func pause(for interval: TimeInterval) {
        let until = Date().addingTimeInterval(interval)
        pause(until: until)
    }

    private func pauseUntilTomorrow() {
        let tomorrow = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
        pause(until: tomorrow)
    }

    private func pause(until date: Date) {
        monitoringEnabled = false
        isObserving = false
        waitingForReturn = false
        pausedUntil = date
        nextCheckAt = nil
        nextPhotoAt = nil
        sampler.cancel()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(60, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            self?.resumeMonitoring()
        }
        refreshUI()
    }

    private func resumeMonitoring() {
        monitoringEnabled = true
        pausedUntil = nil
        isObserving = false
        waitingForReturn = false
        nextPhotoAt = nil
        scheduleNextConfiguredCheck()
        refreshUI()
    }

    @objc private func markBreakDone() {
        lastBreakAcknowledged = Date()
        sampler.cancel()
        isObserving = false
        waitingForReturn = false
        nextPhotoAt = nil
        speak("已记录。稍后我会继续提醒你活动。")
        if monitoringEnabled {
            scheduleNextConfiguredCheck()
        }
        refreshUI()
    }

    private func openHistoryFolder() {
        NSWorkspace.shared.open(historyStore.rootURL)
    }

    private func selectCustomAudio() {
        let panel = NSOpenPanel()
        panel.title = "选择提醒音频"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]

        if panel.runModal() == .OK, let url = panel.url {
            preferences.customAudioPath = url.path
            windowController?.updateAudioPathLabel(path: url.path)
            preferences.soundMode = .audio
            windowController?.updateSoundMode(.audio)
        }
    }

    private func clearCustomAudioForPromptChange() {
        preferences.customAudioPath = nil
        preferences.soundMode = .speech
        windowController?.updateAudioPathLabel(path: nil)
        windowController?.updateSoundMode(.speech)
        stopReminderSound()
    }

    private func testReminderSound() {
        let sampleResult = PostureResult(
            issues: [.unchanged, .longSitting],
            personPresent: true,
            cancelledBecauseAway: false,
            postureUnchanged: true,
            observationDuration: 3 * 60,
            framesAnalyzed: 10,
            confidence: 0.82,
            motionScore: 0.012,
            detail: "观察 3 分钟；采样 10 张；人体 10 张；在位 10 张；最大姿态变化 1.2%；置信度 82%",
            imageData: nil,
            sampleImageDatas: []
        )
        let text = preferences.renderedPrompt(result: sampleResult, reason: "测试提醒")
        playReminderSound(text: text)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func scheduleNextConfiguredCheck() {
        guard monitoringEnabled else { return }
        isObserving = false
        waitingForReturn = false
        nextPhotoAt = nil
        scheduleCheck(after: 1)
    }

    private func restartObservationWithCurrentSettings() {
        timer?.invalidate()
        timer = nil
        sampler.cancel()
        isObserving = false
        waitingForReturn = false
        nextCheckAt = nil
        nextPhotoAt = nil
        if monitoringEnabled {
            scheduleNextConfiguredCheck()
        }
    }

    private func nextObservationWindow() -> TimeInterval {
        switch preferences.observationTimeMode {
        case .fixed:
            return TimeInterval(preferences.fixedObservationWindowMinutes * 60)
        case .random:
            let minimum = TimeInterval(preferences.minimumObservationWindowMinutes * 60)
            let maximum = TimeInterval(preferences.maximumObservationWindowMinutes * 60)
            return Double.random(in: minimum...max(minimum, maximum))
        }
    }

    private func scheduleCheck(after interval: TimeInterval) {
        guard monitoringEnabled else { return }
        isObserving = false
        timer?.invalidate()
        nextCheckAt = Date().addingTimeInterval(interval)
        nextPhotoAt = nil
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.runPostureCheck(reason: "定时检查", forced: false)
        }
        refreshUI()
    }

    private func runPostureCheck(reason: String, forced: Bool) {
        guard monitoringEnabled || forced else { return }

        if !forced, let pausedUntil, pausedUntil > Date() {
            pause(until: pausedUntil)
            return
        }

        timer?.invalidate()
        timer = nil
        waitingForReturn = false
        isObserving = true
        let observationWindow = nextObservationWindow()
        nextCheckAt = Date().addingTimeInterval(observationWindow)
        nextPhotoAt = nil
        statusItem?.button?.title = "Checking"
        refreshUI()
        let imageCapture = historyStore.beginObservationImageCapture()
        let absenceCancelSampleCount = preferences.reminderTriggerMode == .timeElapsed
            ? preferences.minimumObservationPhotos + 1
            : config.absenceCancelSampleCount
        sampler.observeFor(
            seconds: observationWindow,
            minimumPhotos: preferences.minimumObservationPhotos,
            absenceCancelSampleCount: absenceCancelSampleCount,
            sampleImageHandler: { imageData in
                imageCapture.append(imageData: imageData)
            },
            nextSampleHandler: { [weak self] date in
                self?.nextPhotoAt = date
                self?.refreshUI()
            }
        ) { [weak self] result in
            self?.handle(result: result, reason: reason, imageCapture: imageCapture)
        }
    }

    private func handle(result: PostureResult, reason: String, imageCapture: ObservationImageCapture?) {
        statusItem?.button?.title = "Posture"
        isObserving = false
        nextPhotoAt = nil
        let imageSave = imageCapture?.finalize(endedAt: Date(), representativeImageData: result.imageData)
            ?? historyStore.saveObservationImages(result: result)
        historyStore.pruneExpired()

        if preferences.reminderTriggerMode == .personVisible, (!result.personPresent || result.cancelledBecauseAway) {
            if monitoringEnabled {
                schedulePresenceProbe()
            } else {
                refreshUI()
            }
            return
        }

        var finalResult = result
        if Date().timeIntervalSince(lastBreakAcknowledged) >= config.longSittingThreshold {
            finalResult.issues.insert(.longSitting)
        }

        _ = historyStore.addRecord(result: finalResult, reason: reason, imageSave: imageSave)
        refreshUI()
        showReminder(result: finalResult, reason: reason)
    }

    private func schedulePresenceProbe() {
        waitingForReturn = true
        isObserving = false
        timer?.invalidate()
        nextCheckAt = Date().addingTimeInterval(config.presenceProbeInterval)
        timer = Timer.scheduledTimer(withTimeInterval: config.presenceProbeInterval, repeats: false) { [weak self] _ in
            self?.runPresenceProbe()
        }
        refreshUI()
    }

    private func runPresenceProbe() {
        guard monitoringEnabled else { return }
        statusItem?.button?.title = "Checking"
        nextPhotoAt = nil
        refreshUI()
        sampler.observeFor(
            seconds: config.presenceProbeDuration,
            minimumPhotos: config.presenceProbeMinimumPhotos,
            absenceCancelSampleCount: config.absenceCancelSampleCount,
            nextSampleHandler: { [weak self] date in
                self?.nextPhotoAt = date
                self?.refreshUI()
            }
        ) { [weak self] result in
            self?.handlePresenceProbe(result: result)
        }
    }

    private func handlePresenceProbe(result: PostureResult) {
        statusItem?.button?.title = "Posture"
        nextPhotoAt = nil
        if result.personPresent, !result.cancelledBecauseAway {
            waitingForReturn = false
            scheduleNextConfiguredCheck()
        } else {
            schedulePresenceProbe()
        }
    }

    private func showReminder(result: PostureResult, reason: String) {
        let issues = result.issueText
        let title = issues.isEmpty ? "该活动一下了" : "该活动一下了：\(issues)"
        let detail: String
        if issues.isEmpty {
            detail = "观察窗口结束。站起来走动、放松肩颈和腰背 3-5 分钟。"
        } else {
            detail = "观察窗口内检测到 \(issues)。建议离开座位，放松肩颈和腰背 3-5 分钟。"
        }

        let reminderText = preferences.renderedPrompt(result: result, reason: reason)
        let deliveryMode = preferences.reminderDeliveryMode

        if deliveryMode.usesSound {
            playReminderSound(text: reminderText)
        }

        guard deliveryMode.usesPopup else {
            if monitoringEnabled {
                scheduleNextConfiguredCheck()
            }
            refreshUI()
            return
        }

        showMainWindow()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = "\(detail)\n\n提醒文案：\(reminderText)\n\n\(result.detail)\n触发原因：\(reason)\n\n已保存到提醒历史。提示：这是本地摄像头启发式观察，不替代医生或康复师建议。"
        alert.addButton(withTitle: "开始活动")
        alert.addButton(withTitle: "5 分钟后提醒")
        alert.addButton(withTitle: "暂停 1 小时")

        let response = alert.runModal()
        stopReminderSound()

        switch response {
        case .alertFirstButtonReturn:
            lastBreakAcknowledged = Date()
            if monitoringEnabled {
                scheduleNextConfiguredCheck()
            }
        case .alertSecondButtonReturn:
            if monitoringEnabled {
                scheduleCheck(after: config.snoozeInterval)
            }
        default:
            pause(for: config.shortPauseInterval)
        }

        refreshUI()
    }

    private func speak(_ text: String) {
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        speaker.speak(utterance)
    }

    private func playReminderSound(text: String) {
        stopReminderSound()

        switch preferences.soundMode {
        case .speech:
            speak(text)
        case .audio:
            if !playCustomAudio() {
                speak(text)
            }
        }
    }

    @discardableResult
    private func playCustomAudio() -> Bool {
        guard let url = preferences.customAudioURL else { return false }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            return true
        } catch {
            return false
        }
    }

    private func stopReminderSound() {
        speaker.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
