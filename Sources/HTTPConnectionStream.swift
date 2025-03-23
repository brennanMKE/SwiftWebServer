import Foundation
import Network

//struct HTTPConnectionStream {
//    let connection: NWConnection
//
//    init(connection: NWConnection) {
//        self.connection = connection
//    }
//
//    var values: AsyncStream<StreamValue> {
//        let stream: AsyncStream<StreamValue>
//        let continuation: AsyncStream<StreamValue>.Continuation
//        (stream, continuation) = AsyncStream.makeStream(of: StreamValue.self, bufferingPolicy: .unbounded)
//
//        Task {
//            func receive() {
//                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
//                    if let error {
//                        continuation.yield(.error(error))
//                    } else if let data {
//                        continuation.yield(.data(data))
//                    }
//
//                    if !isComplete {
//                        receive()
//                    }
//                }
//            }
//
//            receive()
//        }
//
//        return stream
//    }
//
//}
