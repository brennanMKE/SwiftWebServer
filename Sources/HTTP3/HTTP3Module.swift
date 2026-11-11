import QPACK
import HTTPCore

/// Optional HTTP/3 protocol support (RFC 9114).
///
/// The pure codecs: QUIC varints (``QUICVarint``, ``VarintParser``), the frame codec
/// (``H3FrameParser``, ``H3FrameEncoder``), settings, unidirectional stream types and the
/// RFC 9114 error codes (``HTTP3Error``). The state machines: ``H3Connection`` (control
/// streams, SETTINGS, stream classification) and ``H3RequestStream`` (request frame order).
/// The runner: ``HTTP3``, a `MultiplexedConnectionProtocol` that maps request streams to an
/// `HTTPHandler`.
public enum HTTP3Module {
    /// The module name.
    public static let name = "HTTP3"

    /// Direct dependencies; referencing them checks the target graph at compile time.
    public static let dependencies: [String] = [QPACKModule.name, HTTPCoreModule.name]
}
