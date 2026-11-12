// The middleware result builder (#0083, docs/ROADMAP.md §5.1–5.2): every optional feature is a
// component in a chain that is one nested generic type, so a component that is not registered
// is not in the compiled chain at all, and the ones that are are called with static dispatch.
//
// Every type here is `@inlinable` (and its stored properties `@usableFromInline`) so the chain
// specializes in the module that builds it: the whole chain then compiles to direct calls.

/// Builds a handler from a list of middlewares that may end in a handler.
///
/// ```swift
/// let app = MiddlewareBuilder.build {
///     AccessLog()
///     if config.compression { Compression() }
///     StaticFiles(root: publicURL)          // the terminal handler
/// }
/// ```
///
/// - Middlewares run in the order written: the first sees the request first and the response
///   last (onion order). Each is free to answer without calling `next` (short-circuit).
/// - The last element may be an ``HTTPHandler``; without one the chain ends in
///   ``NotFoundHandler`` (`404`). A handler anywhere but last does not compile. A component
///   that is both (`StaticFiles`, `Router`, `VirtualHosts`) is the terminal handler when last
///   and a middleware (a miss falls through to `next`) anywhere else.
/// - `if` without `else` gives an ``OptionalMiddleware``: when the condition was false the
///   component is absent and costs one predictable branch per request. `if`/`else` gives an
///   ``EitherMiddleware`` (or ``EitherHandler`` when both branches end in a handler).
/// - Up to 10 elements per block (an `if` body is a block of its own). Middlewares in front of a
///   handler nest to the right as ``MiddlewareChain``s, built once, so a request passes down
///   stored values and nothing is copied or constructed per request. Middlewares with no
///   handler after them (an `if` body) nest as ``ComposedMiddleware``, which builds the
///   `next` of its outer middleware per request (a copy of the rest of the chain).
/// - No existentials and no arrays: the result's type spells out the whole chain, e.g.
///   `CompiledChain<MiddlewareChain<AccessLog, MiddlewareChain<OptionalMiddleware<Compression>, StaticFiles>>>`.
///   ``CompiledChain`` is the one indirect call at the top (see there for why); a lone handler
///   is returned unwrapped.
@resultBuilder
public enum MiddlewareBuilder {
    // MARK: Blocks

    /// An empty block is a middleware that passes every request on.
    @inlinable
    public static func buildBlock() -> PassthroughMiddleware { PassthroughMiddleware() }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware>(_ m0: M0) -> M0 { m0 }

    @inlinable
    public static func buildBlock<H: HTTPHandler>(_ handler: H) -> H { handler }

    // Blocks of 2…10 elements, generated: middlewares ending in a handler nest to the right as
    // `MiddlewareChain<M0, MiddlewareChain<M1, H>>`, so nothing is built per request; a block
    // of middlewares only (the body of an `if`, or a chain with no handler) nests as
    // `ComposedMiddleware<M0, ComposedMiddleware<M1, M2>>`.

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ h: H
    ) -> MiddlewareChain<M0, H> {
        MiddlewareChain(middleware: m0, next: h)
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware>(
        _ m0: M0, _ m1: M1
    ) -> ComposedMiddleware<M0, M1> {
        ComposedMiddleware(outer: m0, inner: m1)
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ m1: M1, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, H>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: h))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2
    ) -> ComposedMiddleware<M0, ComposedMiddleware<M1, M2>> {
        ComposedMiddleware(outer: m0, inner: ComposedMiddleware(outer: m1, inner: m2))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, H>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: h)))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3
    ) -> ComposedMiddleware<M0, ComposedMiddleware<M1, ComposedMiddleware<M2, M3>>> {
        ComposedMiddleware(outer: m0, inner: ComposedMiddleware(outer: m1, inner: ComposedMiddleware(outer: m2, inner: m3)))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, H>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: h))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4
    ) -> ComposedMiddleware<M0, ComposedMiddleware<M1, ComposedMiddleware<M2, ComposedMiddleware<M3, M4>>>> {
        ComposedMiddleware(outer: m0, inner: ComposedMiddleware(outer: m1, inner: ComposedMiddleware(outer: m2, inner: ComposedMiddleware(outer: m3, inner: m4))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, H>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: h)))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5
    ) -> ComposedMiddleware<M0, ComposedMiddleware<M1, ComposedMiddleware<M2, ComposedMiddleware<M3, ComposedMiddleware<M4, M5>>>>> {
        ComposedMiddleware(outer: m0, inner: ComposedMiddleware(outer: m1, inner: ComposedMiddleware(outer: m2, inner: ComposedMiddleware(outer: m3, inner: ComposedMiddleware(outer: m4, inner: m5)))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, MiddlewareChain<M5, H>>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: MiddlewareChain(middleware: m5, next: h))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6
    ) -> ComposedMiddleware<M0, ComposedMiddleware<M1, ComposedMiddleware<M2, ComposedMiddleware<M3, ComposedMiddleware<M4, ComposedMiddleware<M5, M6>>>>>> {
        ComposedMiddleware(outer: m0, inner: ComposedMiddleware(outer: m1, inner: ComposedMiddleware(outer: m2, inner: ComposedMiddleware(outer: m3, inner: ComposedMiddleware(outer: m4, inner: ComposedMiddleware(outer: m5, inner: m6))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, MiddlewareChain<M5, MiddlewareChain<M6, H>>>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: MiddlewareChain(middleware: m5, next: MiddlewareChain(middleware: m6, next: h)))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, M7: HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ m7: M7
    ) -> ComposedMiddleware<M0, ComposedMiddleware<M1, ComposedMiddleware<M2, ComposedMiddleware<M3, ComposedMiddleware<M4, ComposedMiddleware<M5, ComposedMiddleware<M6, M7>>>>>>> {
        ComposedMiddleware(outer: m0, inner: ComposedMiddleware(outer: m1, inner: ComposedMiddleware(outer: m2, inner: ComposedMiddleware(outer: m3, inner: ComposedMiddleware(outer: m4, inner: ComposedMiddleware(outer: m5, inner: ComposedMiddleware(outer: m6, inner: m7)))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, M7: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ m7: M7, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, MiddlewareChain<M5, MiddlewareChain<M6, MiddlewareChain<M7, H>>>>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: MiddlewareChain(middleware: m5, next: MiddlewareChain(middleware: m6, next: MiddlewareChain(middleware: m7, next: h))))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, M7: HTTPMiddleware, M8: HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ m7: M7, _ m8: M8
    ) -> ComposedMiddleware<M0, ComposedMiddleware<M1, ComposedMiddleware<M2, ComposedMiddleware<M3, ComposedMiddleware<M4, ComposedMiddleware<M5, ComposedMiddleware<M6, ComposedMiddleware<M7, M8>>>>>>>> {
        ComposedMiddleware(outer: m0, inner: ComposedMiddleware(outer: m1, inner: ComposedMiddleware(outer: m2, inner: ComposedMiddleware(outer: m3, inner: ComposedMiddleware(outer: m4, inner: ComposedMiddleware(outer: m5, inner: ComposedMiddleware(outer: m6, inner: ComposedMiddleware(outer: m7, inner: m8))))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, M7: HTTPMiddleware, M8: HTTPMiddleware, H: HTTPHandler>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ m7: M7, _ m8: M8, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, MiddlewareChain<M5, MiddlewareChain<M6, MiddlewareChain<M7, MiddlewareChain<M8, H>>>>>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: MiddlewareChain(middleware: m5, next: MiddlewareChain(middleware: m6, next: MiddlewareChain(middleware: m7, next: MiddlewareChain(middleware: m8, next: h)))))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, M7: HTTPMiddleware, M8: HTTPMiddleware, M9: HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ m7: M7, _ m8: M8, _ m9: M9
    ) -> ComposedMiddleware<M0, ComposedMiddleware<M1, ComposedMiddleware<M2, ComposedMiddleware<M3, ComposedMiddleware<M4, ComposedMiddleware<M5, ComposedMiddleware<M6, ComposedMiddleware<M7, ComposedMiddleware<M8, M9>>>>>>>>> {
        ComposedMiddleware(outer: m0, inner: ComposedMiddleware(outer: m1, inner: ComposedMiddleware(outer: m2, inner: ComposedMiddleware(outer: m3, inner: ComposedMiddleware(outer: m4, inner: ComposedMiddleware(outer: m5, inner: ComposedMiddleware(outer: m6, inner: ComposedMiddleware(outer: m7, inner: ComposedMiddleware(outer: m8, inner: m9)))))))))
    }

    // Components that are both a middleware and a handler (`StaticFiles`, `Router`,
    // `VirtualHosts`) match both families above when they are last, so neither is chosen and
    // the call is ambiguous (#0126). These overloads take such a component last; they are more
    // specialized than either family (`H` satisfies both), so overload ranking picks them, and
    // they build what the handler family builds: the last component is the terminal handler.
    // Anywhere else in a block such a component is only matched as a middleware.

    @inlinable
    public static func buildBlock<H: HTTPHandler & HTTPMiddleware>(_ handler: H) -> H { handler }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ h: H
    ) -> MiddlewareChain<M0, H> {
        MiddlewareChain(middleware: m0, next: h)
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, H>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: h))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, H>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: h)))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, H>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: h))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, H>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: h)))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, MiddlewareChain<M5, H>>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: MiddlewareChain(middleware: m5, next: h))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, MiddlewareChain<M5, MiddlewareChain<M6, H>>>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: MiddlewareChain(middleware: m5, next: MiddlewareChain(middleware: m6, next: h)))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, M7: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ m7: M7, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, MiddlewareChain<M5, MiddlewareChain<M6, MiddlewareChain<M7, H>>>>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: MiddlewareChain(middleware: m5, next: MiddlewareChain(middleware: m6, next: MiddlewareChain(middleware: m7, next: h))))))))
    }

    @inlinable
    public static func buildBlock<M0: HTTPMiddleware, M1: HTTPMiddleware, M2: HTTPMiddleware, M3: HTTPMiddleware, M4: HTTPMiddleware, M5: HTTPMiddleware, M6: HTTPMiddleware, M7: HTTPMiddleware, M8: HTTPMiddleware, H: HTTPHandler & HTTPMiddleware>(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4, _ m5: M5, _ m6: M6, _ m7: M7, _ m8: M8, _ h: H
    ) -> MiddlewareChain<M0, MiddlewareChain<M1, MiddlewareChain<M2, MiddlewareChain<M3, MiddlewareChain<M4, MiddlewareChain<M5, MiddlewareChain<M6, MiddlewareChain<M7, MiddlewareChain<M8, H>>>>>>>>> {
        MiddlewareChain(middleware: m0, next: MiddlewareChain(middleware: m1, next: MiddlewareChain(middleware: m2, next: MiddlewareChain(middleware: m3, next: MiddlewareChain(middleware: m4, next: MiddlewareChain(middleware: m5, next: MiddlewareChain(middleware: m6, next: MiddlewareChain(middleware: m7, next: MiddlewareChain(middleware: m8, next: h)))))))))
    }

    // MARK: Conditionals

    @inlinable
    public static func buildOptional<M: HTTPMiddleware>(_ component: M?) -> OptionalMiddleware<M> {
        OptionalMiddleware(component)
    }

    /// An optional terminal handler: `404` when absent.
    @inlinable
    public static func buildOptional<H: HTTPHandler>(_ component: H?) -> EitherHandler<H, NotFoundHandler> {
        if let component { .first(component) } else { .second(NotFoundHandler()) }
    }

    /// An optional component that is both a middleware and a handler: an
    /// ``OptionalMiddleware``, which is then also a handler (`404` when absent), so it can sit
    /// anywhere in a block, last included (#0126).
    @inlinable
    public static func buildOptional<W: HTTPHandler & HTTPMiddleware>(_ component: W?) -> OptionalMiddleware<W> {
        OptionalMiddleware(component)
    }

    /// Branches that are both middlewares and handlers: an ``EitherHandler``, which is then also
    /// a middleware, so it can sit anywhere in a block, last included (#0126).
    @inlinable
    public static func buildEither<First: HTTPHandler & HTTPMiddleware, Second: HTTPHandler & HTTPMiddleware>(
        first component: First
    ) -> EitherHandler<First, Second> {
        .first(component)
    }

    @inlinable
    public static func buildEither<First: HTTPHandler & HTTPMiddleware, Second: HTTPHandler & HTTPMiddleware>(
        second component: Second
    ) -> EitherHandler<First, Second> {
        .second(component)
    }

    @inlinable
    public static func buildEither<First: HTTPMiddleware, Second: HTTPMiddleware>(
        first component: First
    ) -> EitherMiddleware<First, Second> {
        .first(component)
    }

    @inlinable
    public static func buildEither<First: HTTPMiddleware, Second: HTTPMiddleware>(
        second component: Second
    ) -> EitherMiddleware<First, Second> {
        .second(component)
    }

    @inlinable
    public static func buildEither<First: HTTPHandler, Second: HTTPHandler>(
        first component: First
    ) -> EitherHandler<First, Second> {
        .first(component)
    }

    @inlinable
    public static func buildEither<First: HTTPHandler, Second: HTTPHandler>(
        second component: Second
    ) -> EitherHandler<First, Second> {
        .second(component)
    }

    // MARK: Result

    /// Middlewares with no handler end in ``NotFoundHandler``.
    @inlinable
    public static func buildFinalResult<M: HTTPMiddleware>(
        _ component: M
    ) -> CompiledChain<MiddlewareChain<M, NotFoundHandler>> {
        CompiledChain(MiddlewareChain(middleware: component, next: NotFoundHandler()))
    }

    /// A chain is compiled where it is built (see ``CompiledChain``).
    @inlinable
    public static func buildFinalResult<M: HTTPMiddleware, H: HTTPHandler>(
        _ component: MiddlewareChain<M, H>
    ) -> CompiledChain<MiddlewareChain<M, H>> {
        CompiledChain(component)
    }

    @inlinable
    public static func buildFinalResult<First: HTTPHandler, Second: HTTPHandler>(
        _ component: EitherHandler<First, Second>
    ) -> CompiledChain<EitherHandler<First, Second>> {
        CompiledChain(component)
    }

    /// A lone handler is returned as is: `Server { app }` is `Server(handler: app)`.
    @inlinable
    public static func buildFinalResult<H: HTTPHandler>(_ component: H) -> H { component }

    /// A lone component that is both a middleware and a handler is the handler (#0126).
    @inlinable
    public static func buildFinalResult<H: HTTPHandler & HTTPMiddleware>(_ component: H) -> H { component }

    @inlinable
    public static func buildFinalResult<First: HTTPHandler & HTTPMiddleware, Second: HTTPHandler & HTTPMiddleware>(
        _ component: EitherHandler<First, Second>
    ) -> CompiledChain<EitherHandler<First, Second>> {
        CompiledChain(component)
    }

    /// Runs the builder: `MiddlewareBuilder.build { … }` outside an initializer that takes a
    /// builder closure (`Server` has one).
    @inlinable
    public static func build<H: HTTPHandler>(@MiddlewareBuilder _ content: () -> H) -> H {
        content()
    }
}

/// The builder's result: a chain specialized where it was built.
///
/// Protocol runners are generic over the handler but are called through `any
/// ConnectionProtocol`, so they run unspecialized: they call `handle` through the witness
/// table with the handler's type metadata. For a plain handler that costs one indirect call,
/// but an unspecialized chain makes two generic async calls per middleware (its own and the
/// one to `next`), with the value witnesses of every layer. So the builder's
/// `buildFinalResult`, which is inlined into the module that writes the chain, stores a
/// closure compiled there with every type known: the runner makes one more indirect async call
/// (about 12 ns in `sws-bench h1conn`), and inside it the chain's own types inline away,
/// leaving one call per middleware that the optimizer did not inline itself.
public struct CompiledChain<Root: HTTPHandler>: HTTPHandler {
    /// Stored first so its offset does not depend on `Root`.
    @usableFromInline
    let entry: @Sendable (Root, HTTPRequest, RequestContext) async throws -> HTTPResponse
    /// The chain as built.
    public let root: Root

    @inlinable
    public init(_ root: Root) {
        self.root = root
        self.entry = { root, request, context in try await root.handle(request, context: context) }
    }

    @inlinable
    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        try await entry(root, request, context)
    }
}

// MARK: - Chain types

/// A middleware in front of a handler: the handler the builder returns.
public struct MiddlewareChain<Middleware: HTTPMiddleware, Next: HTTPHandler>: HTTPHandler {
    public let middleware: Middleware
    public let next: Next

    @inlinable
    public init(middleware: Middleware, next: Next) {
        self.middleware = middleware
        self.next = next
    }

    @inlinable @inline(__always)
    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        try await middleware.handle(request, context: context, next: next)
    }
}

/// Two middlewares in sequence: `outer` runs first and its `next` is `inner` in front of the
/// rest of the chain.
public struct ComposedMiddleware<Outer: HTTPMiddleware, Inner: HTTPMiddleware>: HTTPMiddleware {
    public let outer: Outer
    public let inner: Inner

    @inlinable
    public init(outer: Outer, inner: Inner) {
        self.outer = outer
        self.inner = inner
    }

    @inlinable @inline(__always)
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        try await outer.handle(request, context: context, next: MiddlewareChain(middleware: inner, next: next))
    }
}

/// A middleware registered under an `if` without `else`: when absent, requests go straight to
/// `next` (one branch, decided once at configuration time, so it predicts perfectly).
public struct OptionalMiddleware<Wrapped: HTTPMiddleware>: HTTPMiddleware {
    public let wrapped: Wrapped?

    @inlinable
    public init(_ wrapped: Wrapped?) {
        self.wrapped = wrapped
    }

    @inlinable @inline(__always)
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        if let wrapped {
            return try await wrapped.handle(request, context: context, next: next)
        }
        return try await next.handle(request, context: context)
    }
}

/// One of two middlewares, chosen at configuration time (`if`/`else`).
public enum EitherMiddleware<First: HTTPMiddleware, Second: HTTPMiddleware>: HTTPMiddleware {
    case first(First)
    case second(Second)

    @inlinable @inline(__always)
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        switch self {
        case .first(let m): try await m.handle(request, context: context, next: next)
        case .second(let m): try await m.handle(request, context: context, next: next)
        }
    }
}

/// An optional component that is also a handler is one: `404` when absent (#0126).
extension OptionalMiddleware: HTTPHandler where Wrapped: HTTPHandler {
    @inlinable @inline(__always)
    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        if let wrapped {
            return try await wrapped.handle(request, context: context)
        }
        return HTTPResponse(status: .notFound)
    }
}

/// One of two terminal handlers, chosen at configuration time (`if`/`else`).
public enum EitherHandler<First: HTTPHandler, Second: HTTPHandler>: HTTPHandler {
    case first(First)
    case second(Second)

    @inlinable @inline(__always)
    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        switch self {
        case .first(let h): try await h.handle(request, context: context)
        case .second(let h): try await h.handle(request, context: context)
        }
    }
}

/// Two branches that are also middlewares make one (#0126).
extension EitherHandler: HTTPMiddleware where First: HTTPMiddleware, Second: HTTPMiddleware {
    @inlinable @inline(__always)
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        switch self {
        case .first(let m): try await m.handle(request, context: context, next: next)
        case .second(let m): try await m.handle(request, context: context, next: next)
        }
    }
}

/// Passes every request on unchanged (an empty builder block).
public struct PassthroughMiddleware: HTTPMiddleware {
    @inlinable
    public init() {}

    @inlinable @inline(__always)
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        try await next.handle(request, context: context)
    }
}

/// The default end of a chain: `404 Not Found` with an empty body.
public struct NotFoundHandler: HTTPHandler {
    @inlinable
    public init() {}

    @inlinable @inline(__always)
    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: .notFound)
    }
}

// MARK: - Inspection

// The server walks a built chain once at startup to find its `ServerComponent`s (an access log
// that is both a middleware and a background flusher) and `RequestStartTimeConsumer`s. Absent
// optional components are `nil` and contribute nothing.

extension CompiledChain: MiddlewareChainContainer {
    public func forEachChainElement(_ body: (Any) -> Void) { body(root) }
}

extension MiddlewareChain: MiddlewareChainContainer {
    public func forEachChainElement(_ body: (Any) -> Void) {
        body(middleware)
        body(next)
    }
}

extension ComposedMiddleware: MiddlewareChainContainer {
    public func forEachChainElement(_ body: (Any) -> Void) {
        body(outer)
        body(inner)
    }
}

extension OptionalMiddleware: MiddlewareChainContainer {
    public func forEachChainElement(_ body: (Any) -> Void) {
        if let wrapped { body(wrapped) }
    }
}

extension EitherMiddleware: MiddlewareChainContainer {
    public func forEachChainElement(_ body: (Any) -> Void) {
        switch self {
        case .first(let m): body(m)
        case .second(let m): body(m)
        }
    }
}

extension EitherHandler: MiddlewareChainContainer {
    public func forEachChainElement(_ body: (Any) -> Void) {
        switch self {
        case .first(let h): body(h)
        case .second(let h): body(h)
        }
    }
}
