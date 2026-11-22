import Foundation

/// Resumable download of a guest image file (kernel, initrd, qcow2) from a URL
/// the user provides, e.g. a server where they host Guest/build output.
@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var progress: Double = 0
    @Published private(set) var bytesWritten: Int64 = 0
    @Published private(set) var bytesExpected: Int64 = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var error: String?

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    /// Read from URLSession's delegate callback, which must move the file synchronously.
    nonisolated(unsafe) private var destination: URL?
    private var completion: ((URL?) -> Void)?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    func start(_ url: URL, to dest: URL, completion: @escaping (URL?) -> Void) {
        destination = dest
        self.completion = completion
        error = nil
        isDownloading = true
        if let data = resumeData { task = session.downloadTask(withResumeData: data) } else { task = session.downloadTask(with: url) }
        resumeData = nil
        task?.resume()
    }

    func pause() {
        task?.cancel { [weak self] data in Task { @MainActor in self?.resumeData = data; self?.isDownloading = false } }
    }

    var canResume: Bool { resumeData != nil }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.bytesWritten = totalBytesWritten
            self.bytesExpected = totalBytesExpectedToWrite
            self.progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must move synchronously before returning: the temp file is deleted afterwards.
        let dest = destination
        var result: URL?
        if let dest {
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { result = dest }
        }
        Task { @MainActor in
            self.isDownloading = false
            self.completion?(result)
        }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            self.isDownloading = false
            if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
            if let data { self.resumeData = data }
        }
    }
}
