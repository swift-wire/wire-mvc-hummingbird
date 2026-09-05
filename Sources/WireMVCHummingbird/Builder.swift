// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import HTTPTypes
public import Hummingbird
public import WireMVC

import BasicContainers

/// An `HTTPServerRouteBuilder` that registers WireMVC's collated routes on Hummingbird's own `Router`.
///
/// The whole per-request path, for a one-shot response:
///
/// 1. Hummingbird matches the route and calls the closure with its `Request` and context.
/// 2. The closure builds a reader over the request body and a sender over a collector.
/// 3. The WireMVC handler runs **to completion** and puts head and body in the collector.
/// 4. The closure returns a `Response` built from them.
///
/// Nothing outlives the closure, so there is no task, no channel and no rendezvous — and nothing crosses
/// into OpenAPI's currency types on the way. Those are the two costs the `ServerTransport` bridge pays.
public struct WireMVCHummingbirdRouteBuilder<Context: RequestContext>: HTTPServerRouteBuilder {
    // The adapter is the top of its own stack, so it puts the courier on itself — the same thing the
    // `ServerTransport` bridge does, and what carries the response-header registry down to each route.
    public typealias RequestContext = WireMVCContext<HummingbirdRequestContext>
    public typealias Reader = HummingbirdReader
    public typealias ResponseSender = HummingbirdResponseSender

    let router: Router<Context>

    public init(router: Router<Context>) {
        self.router = router
    }

    public mutating func register(
        method: HTTPRequest.Method,
        path: String,
        handler:
            @escaping @Sendable (
                HTTPRequest,
                consuming WireMVCContext<HummingbirdRequestContext>,
                [String: Substring],
                consuming sending HummingbirdReader,
                consuming sending HummingbirdResponseSender
            ) async throws -> Void
    ) {
        router.on(RouterPath(Self.hummingbirdPath(from: path)), method: method) {
            request,
            context -> Response in
            let channel = ResponseChannel()
            var pathParameters: [String: Substring] = [:]
            for (name, value) in context.parameters {
                pathParameters[String(name)] = Substring(value)
            }

            // Unstructured, and only because a streamed response needs the handler to outlive this
            // closure: Hummingbird wants a `Response` back before the body exists. For a one-shot
            // response the handler finishes before `awaitStart()` returns, so nothing is left running —
            // the task is a formality the fast path pays a `Task` allocation for and nothing else.
            let handlerTask = Task {
                do {
                    try await handler(
                        request.head,
                        WireMVCContext(
                            base: HummingbirdRequestContext(),
                            responseHeaders: ResponseHeaderRegistry()
                        ),
                        pathParameters,
                        HummingbirdReader(request.body),
                        HummingbirdResponseSender(channel: channel)
                    )
                    channel.handlerFinished()
                } catch {
                    channel.handlerThrew(error)
                }
            }

            // `Task {}` inherits task-locals and priority but **not** cancellation, so a client that goes
            // away before the head exists would otherwise leave the handler running for a response nobody
            // will read.
            let start = await withTaskCancellationHandler {
                await channel.awaitStart()
            } onCancel: {
                handlerTask.cancel()
            }

            switch start {
            case let .complete(head, body):
                return Response(
                    status: head.status,
                    headers: head.headerFields,
                    body: .init(byteBuffer: body)
                )

            case let .streamed(head):
                // The body pulls chunks off the rendezvous channel as Hummingbird's writer takes them, so
                // backpressure reaches the handler. Cancelling the task when the body is dropped stops a
                // producer writing into a response the peer has abandoned.
                return Response(
                    status: head.status,
                    headers: head.headerFields,
                    body: ResponseBody { writer in
                        defer { handlerTask.cancel() }
                        for await chunk in channel.body {
                            try await writer.write(chunk)
                        }
                        try await writer.finish(nil)
                    }
                )

            case let .failed(error):
                throw error

            case .finishedWithoutResponse:
                throw WireMVCHummingbirdError.handlerFinishedWithoutResponding
            }
        }
    }

    /// WireMVC spells parameters `{name}` and catch-alls `{name*}`; Hummingbird spells them `:name` and
    /// `**`. A catch-all is expressible on this path where `ServerTransport.register` could not express it
    /// at all — the capability the bridge subtracts, recovered for free by mounting natively.
    static func hummingbirdPath(from path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map { segment -> String in
            guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return String(segment) }
            let name = segment.dropFirst().dropLast()
            return name.hasSuffix("*") ? "**" : ":\(name)"
        }
        return segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
    }
}
