import Foundation

actor ExitHandler {
    var continuation: CheckedContinuation<Void, any Error>?
    
    init() {}
    
    func wait() async throws {
        try await withCheckedThrowingContinuation {
            self.continuation = $0
        }
    }
    
    func resume() {
        logger.log(#function)
        if let continuation {
            continuation.resume()
        }
    }

    func cancel() {
        terminate(error: CancellationError())
    }

    func interrupt() {
        logger.log(#function)
        guard let continuation else { return }
        continuation.resume()
    }
    
    func terminate(error: Error? = nil) {
        logger.log(#function)
        guard let continuation else { return }
        if let error {
            logger.warning("Terminating with error: \(error, privacy: .public)")
            continuation.resume(throwing: error)
        } else {
            logger.warning("Terminating")
            continuation.resume()
        }
    }
}
