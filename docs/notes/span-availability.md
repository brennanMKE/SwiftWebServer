# Span and InlineArray availability (macOS 15 deployment target)

Checked for issue #0069 with Apple Swift 6.4.2 (Xcode toolchain, macOS 27.2 SDK), deployment target `macOS 15`, Swift 6 language mode. The compile check is `Tests/HTTPCoreTests/SpanAvailabilityTests.swift`.

| API | macOS 15 without `#available` |
| --- | --- |
| `Span`, `RawSpan`, `MutableSpan` (types, `count`, `byteCount`, subscripts, `bytes`, `extracting`, `unsafeLoad`) | Yes (back-deployed) |
| `UnsafeBufferPointer.span`, `UnsafeMutableBufferPointer.mutableSpan`, `UnsafeRawBufferPointer.bytes` | Yes |
| `Array.span`, `Array.mutableSpan` (and other stdlib collection span properties) | No, macOS 26 |
| `InlineArray` | No, macOS 26 |

## Consequences

- `HTTPCore` can use `Span`/`RawSpan`/`MutableSpan` in its APIs on macOS 15. Create them from storage we own (for example `ByteBuffer`'s unsafe buffer) via `withUnsafe…BufferPointer { $0.span }`, not from `Array.span`.
- A function that *returns* a span needs a lifetime annotation (`@_lifetime(copy x)` / `@_lifetime(borrow x)`), which still requires `-enable-experimental-feature Lifetimes`. It compiles on this toolchain, but we keep it out of the package: prefer closure-scoped access (`withSpan { … }`) or `~Escapable` types whose lifetimes the compiler infers.
- `InlineArray` is not available unconditionally. Use tuples or fixed-size `UnsafeMutablePointer` storage for small fixed buffers. Code that uses `InlineArray` behind `if #available(macOS 26, *)` must also have a macOS 15 fallback.
