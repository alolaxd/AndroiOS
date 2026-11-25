import Foundation

/// Resumable download of a guest file (e.g. the LineageOS disks).
///
/// URLSession calls back on a background queue: a 1 GB download produces tens
/// of thousands of progress callbacks, and running them on the main thread
/// (with a SwiftUI update each) froze the app until long after it finished.
/// Progress reaches the UI at most 4 times a second.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var bytesWritten: Int64 = 0
    @Published private(set) var bytesExpected: Int64 = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var error: String?

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var completion: ((URL?) -> Void)?
    private let delegate = Delegate()

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: queue)
        delegate.owner = self
    }

    func start(_ url: URL, to dest: URL, completion: @escaping (URL?) -> Void) {
        delegate.setDestination(dest)
        self.completion = completion
        error = nil
        isDownloading = true
        progress = 0; bytesWritten = 0; bytesExpected = 0
        if let data = resumeData { task = session.downloadTask(withResumeData: data) } else { task = session.downloadTask(with: url) }
        resumeData = nil
        task?.resume()
    }

    func pause() {
        task?.cancel { [weak self] data in Task { @MainActor in self?.resumeData = data; self?.isDownloading = false } }
    }

    var canResume: Bool { resumeData != nil }

    fileprivate func report(written: Int64, expected: Int64) {
        bytesWritten = written
        bytesExpected = expected
        progress = expected > 0 ? Double(written) / Double(expected) : 0
    }

    fileprivate func finished(_ url: URL?) {
        isDownloading = false
        if url != nil { progress = 1 }
        completion?(url)
    }

    fileprivate func failed(_ error: Error, resumeData: Data?) {
        isDownloading = false
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
        if let resumeData { self.resumeData = resumeData }
    }

    /// URLSession delegate, running on the session's background queue.
    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        weak var owner: DownloadManager?
        private let lock = NSLock()
        private var destination: URL?
        private var lastReport = Date.distantPast

        func setDestination(_ url: URL) { lock.lock(); destination = url; lastReport = .distantPast; lock.unlock() }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            lock.lock()
            let due = now.timeIntervalSince(lastReport) >= 0.25
            if due { lastReport = now }
            lock.unlock()
            guard due else { return }
            Task { @MainActor [weak owner] in owner?.report(written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // Must move synchronously: the temporary file is deleted when this returns.
            lock.lock(); let dest = destination; lock.unlock()
            // An HTTP error page also "finishes"; don't save it as a disk image.
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                                  userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))."])
                Task { @MainActor [weak owner] in owner?.failed(err, resumeData: nil) }
                return
            }
            var result: URL?
            if let dest {
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { result = dest }
            }
            Task { @MainActor [weak owner] in owner?.finished(result) }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            Task { @MainActor [weak owner] in owner?.failed(error, resumeData: data) }
        }
    }
}
