import Foundation
import os

/// What a background transfer was for, carried on the transfer itself.
///
/// The whole difficulty with background uploads is that the answer can arrive
/// in a process that has no memory of asking the question. The app is suspended
/// mid-PUT, the system finishes the transfer, and hours later it relaunches us
/// to say so — with nothing in memory, no continuation waiting, and only the
/// task to identify what happened.
///
/// So the identity rides on the task. `URLSessionTask.taskDescription` is a
/// string the system persists with the transfer and hands back to whichever
/// process is woken for it, which makes it the one place a job description
/// cannot drift away from the job.
nonisolated struct UploadJob: Codable, Hashable, Sendable {
    /// Which queued message, by the guid it will be sent under.
    var guid: String
    /// Which attachment of it.
    var index: Int
    var step: Step

    /// What finishing means for this transfer.
    nonisolated enum Step: String, Codable, Sendable {
        /// The bytes going to Azure at a pre-signed URL. The one step that
        /// needs nothing from the answer: `m.groupme.com` said what the file
        /// would be called before it was uploaded, so a 200 is the whole story.
        case presignedPut
        /// `image.groupme.com/pictures`, which returns the URL in its body.
        case pictureService
        /// The transcoder, which returns a status URL to poll afterwards.
        case transcode
    }

    /// Where the file will live once the PUT lands. Known in advance, and only
    /// for ``Step/presignedPut``.
    var renderURL: String?
    var thumbnailURL: String?

    var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    init?(taskDescription: String?) {
        guard let data = taskDescription?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(UploadJob.self, from: data)
        else { return nil }
        self = decoded
    }

    init(guid: String, index: Int, step: Step, renderURL: String? = nil, thumbnailURL: String? = nil) {
        self.guid = guid
        self.index = index
        self.step = step
        self.renderURL = renderURL
        self.thumbnailURL = thumbnailURL
    }
}

/// How a transfer ended, whoever is listening.
nonisolated struct UploadOutcome: Sendable {
    var job: UploadJob
    var body: Data
    var status: Int?
    var error: (any Error)?
}

/// Uploads that survive the app being put away.
///
/// An ordinary `URLSession` belongs to the process: lock the phone, the app is
/// suspended a few seconds later, and every transfer in flight stops where it
/// is. A background session belongs to the *system*. It takes a file and a
/// request, carries them out of process, keeps going while the app is
/// suspended, and relaunches the app to deliver the answer if it has to.
///
/// The price is a narrower shape, and every constraint here is one of its
/// rules rather than a preference:
///
/// - **From a file, never from memory.** `uploadTask(with:fromFile:)` is the
///   only form a background session accepts, so a multipart body has to be
///   written out before it can be sent.
/// - **Delegates, not `await`.** There is no `data(for:)`: results arrive on a
///   delegate that may belong to a later launch of the app. The `send` method
///   here still reads as an await, and that await is simply never resumed in a
///   process that gets suspended — which is why finishing must not depend on
///   it. See ``onOrphanedOutcome``.
/// - **One session per identifier, for the life of the app.** Recreating it
///   with the same identifier is how a relaunched process re-adopts transfers
///   that are still running.
actor BackgroundUploads {
    static let shared = BackgroundUploads()

    /// Stable, and it has to be: the system finds a suspended app's transfers by
    /// this string.
    private static let identifier = "sh.dunkirk.GroupMeNot.uploads"

    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "bgupload")
    private let delegate = Delegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        // The whole point. `false` would let a transfer start on a cell
        // connection the moment the user has said not to.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 24 * 3_600
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private init() {}

    /// Adopt any transfers still running from a previous launch, and be ready
    /// for the ones the system is about to report.
    ///
    /// Called once at startup. Touching `session` is the whole of it: creating
    /// it with the same identifier is what re-attaches this process to the
    /// system's copy of the queue.
    func start(handler: @escaping @Sendable (UploadOutcome) -> Void) async {
        delegate.setOrphanHandler(handler)
        _ = session
    }

    /// Send a file, and wait for it here if we are still here.
    ///
    /// The continuation is a convenience for the ordinary case — the app is in
    /// front, the upload takes four seconds, the caller carries on. It is not
    /// the mechanism. If this process is suspended and never resumed, the
    /// transfer still completes and the answer still arrives, at the orphan
    /// handler instead.
    func send(
        _ request: URLRequest, from file: URL, job: UploadJob,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = job.encoded
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.expect(
                    task.taskIdentifier, continuation: continuation, onProgress: onProgress)
                task.resume()
            }
        } onCancel: {
            // Deliberately *not* cancelling the transfer. A cancelled await is
            // this process losing interest, which is not the same as the user
            // wanting the photo unsent; the bytes keep going and the outcome
            // lands as an orphan.
            delegate.stopWaiting(task.taskIdentifier)
        }
    }

    /// The app was woken to be told the queue is empty. Handed straight to the
    /// delegate, which calls it once the last outcome has been delivered.
    func adoptLaunchEvents(_ completion: @escaping @Sendable () -> Void) async {
        _ = session
        delegate.setLaunchCompletion(completion)
    }

    // MARK: - Delegate

    /// Separate from the actor because `URLSession` wants an `NSObject`, and
    /// because these callbacks arrive on the session's own queue whether or not
    /// anybody is waiting for them.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [Int: CheckedContinuation<Data, any Error>] = [:]
        private var progress: [Int: @Sendable (Double) -> Void] = [:]
        private var bodies: [Int: Data] = [:]
        private var orphanHandler: (@Sendable (UploadOutcome) -> Void)?
        private var launchCompletion: (@Sendable () -> Void)?

        func setOrphanHandler(_ handler: @escaping @Sendable (UploadOutcome) -> Void) {
            lock.withLock { orphanHandler = handler }
        }

        func setLaunchCompletion(_ completion: @escaping @Sendable () -> Void) {
            lock.withLock { launchCompletion = completion }
        }

        func expect(
            _ id: Int, continuation: CheckedContinuation<Data, any Error>,
            onProgress: (@Sendable (Double) -> Void)?
        ) {
            lock.withLock {
                waiters[id] = continuation
                progress[id] = onProgress
            }
        }

        /// The caller has gone. Resumed with a cancellation so nothing is left
        /// holding a continuation, and the transfer carries on without it.
        func stopWaiting(_ id: Int) {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
            totalBytesExpectedToSend total: Int64
        ) {
            guard total > 0 else { return }
            let hook = lock.withLock { progress[task.taskIdentifier] }
            hook?(min(Double(totalBytesSent) / Double(total), 1))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
        ) {
            let id = task.taskIdentifier
            let (waiter, body, handler) = lock.withLock {
                let waiter = waiters.removeValue(forKey: id)
                let body = bodies.removeValue(forKey: id) ?? Data()
                progress[id] = nil
                return (waiter, body, orphanHandler)
            }
            let status = (task.response as? HTTPURLResponse)?.statusCode

            if let waiter {
                if let error {
                    waiter.resume(throwing: error)
                } else {
                    waiter.resume(returning: body)
                }
                return
            }

            // Nobody is waiting: either this process was relaunched to be told,
            // or the caller gave up on us. Either way the transfer happened, and
            // what it means has to be worked out from the job on the task.
            guard let job = UploadJob(taskDescription: task.taskDescription) else { return }
            handler?(UploadOutcome(job: job, body: body, status: status, error: error))
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            let completion = lock.withLock {
                let completion = launchCompletion
                launchCompletion = nil
                return completion
            }
            completion?()
        }
    }
}
