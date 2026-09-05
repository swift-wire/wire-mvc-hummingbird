// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-hummingbird project authors

public import HTTPTypes
public import NIOCore

import AsyncAlgorithms

/// Coordinates a handler with the route closure that has to return a `Response` for it.
///
/// Two shapes, and only one of them costs anything.
///
/// **One-shot.** A typed route builds its whole response before touching the sender, so `sendAndFinish`
/// completes inside the route closure and the head and body are simply read back. Nothing outlives the
/// closure — no task, no channel, no rendezvous. This is the path that measures +3.5 µs and 4 allocations
/// against a plain Hummingbird route, and it is what the great majority of routes take.
///
/// **Streamed.** A handler that calls `send(_:)` and then writes cannot work that way: Hummingbird needs a
/// `Response` returned before the body exists, so the handler must outlive the closure that produced its
/// head. That needs an unstructured task and a rendezvous — the same machinery the `ServerTransport`
/// bridge pays on *every* request, here paid only by the routes that require it.
///
/// A class, `@unchecked Sendable` on the usual terms: the start stream and the body channel do the
/// synchronising, and everything else is touched only by the one task running the handler.
final class ResponseChannel: @unchecked Sendable {
    /// How a response begins, delivered from the handler to the route closure.
    enum Start {
        /// The whole body is known: the closure returns a buffered `Response` and nothing streams.
        case complete(HTTPResponse, ByteBuffer)
        /// The head is known but the body is still being written.
        case streamed(HTTPResponse)
        /// The handler threw before responding — re-thrown so Hummingbird maps it.
        case failed(any Error)
        /// The handler returned without responding, which is invalid.
        case finishedWithoutResponse
    }

    /// Body chunks, on a **rendezvous** channel: each send suspends until Hummingbird's writer takes the
    /// chunk, which is real backpressure rather than an unbounded buffer.
    ///
    /// Built on first use, not per request. Only a streamed response ever touches it, and constructing one
    /// for every one-shot response was measurable — the whole point of this adapter is that the common
    /// path pays for nothing it does not use.
    private var _body: AsyncChannel<ByteBuffer>?
    var body: AsyncChannel<ByteBuffer> {
        if let _body { return _body }
        let created = AsyncChannel<ByteBuffer>()
        _body = created
        return created
    }

    private let starts: AsyncStream<Start>
    private let startContinuation: AsyncStream<Start>.Continuation
    private var responded = false

    init() {
        (starts, startContinuation) = AsyncStream.makeStream(of: Start.self)
    }

    func complete(_ head: HTTPResponse, _ bytes: ByteBuffer) {
        responded = true
        startContinuation.yield(.complete(head, bytes))
        startContinuation.finish()
    }

    func streamed(_ head: HTTPResponse) {
        responded = true
        startContinuation.yield(.streamed(head))
        startContinuation.finish()
    }

    func handlerThrew(_ error: any Error) {
        guard !responded else {
            // The head is already on the wire, so the failure can only be signalled by truncating.
            _body?.finish()
            return
        }
        startContinuation.yield(.failed(error))
        startContinuation.finish()
    }

    func handlerFinished() {
        if responded {
            _body?.finish()
        } else {
            startContinuation.yield(.finishedWithoutResponse)
            startContinuation.finish()
        }
    }

    /// Awaits however the response begins.
    func awaitStart() async -> Start {
        for await start in starts { return start }
        return .finishedWithoutResponse
    }
}
