// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-hummingbird project authors

public import HTTPAPIs
public import HTTPTypes
public import Hummingbird
public import WireMVC

import AsyncStreaming
public import BasicContainers
public import NIOCore

// Mount WireMVC's collated routes on Hummingbird's own router.
//
// The `ServerTransport` bridge measures +16 µs and 41 allocations per request. Two costs are bundled in
// that: crossing into OpenAPI's currency types (`HTTPBody`, `ServerRequestMetadata`), and the unstructured
// `Task` plus `ResponseChannel` rendezvous that `ServerTransport.register`'s **return-based** shape forces
// — the handler must outlive the closure that produced it, so it cannot be a structured child.
//
// This removes the first cost outright: Hummingbird's `Router` is registered on directly, in its own
// types. It removes the second **for one-shot responses**, which is what a typed route produces: the
// handler runs to completion inside the route closure, writing head and body into a collector, and the
// closure then returns a `Response`. No task, no channel, no rendezvous.
//
// A *streamed* response cannot work that way — the head must be returned before the body exists — so that
// path still needs the handler to outlive the closure. It is not implemented here: this prototype exists
// to price the common path, and pretending to serve the other one would make the number a blend.

/// Hummingbird supplies no per-request capabilities WireMVC reads, so the context is empty — the same
/// shape the `ServerTransport` bridge uses.
public struct HummingbirdRequestContext: HTTPServerCapability.RequestContext {
    public init() {}
}

/// An `AsyncReader` over Hummingbird's `RequestBody`, one read per chunk, so a streaming binding sees
/// bytes before the whole body has arrived.
public struct HummingbirdReader: AsyncReader {
    public typealias ReadElement = UInt8
    public typealias ReadFailure = any Error
    public typealias FinalElement = HTTPFields?
    public typealias Buffer = UniqueArray<UInt8>

    private let source: BodySource

    public init(_ body: RequestBody) { source = BodySource(body) }

    public mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        let chunk: ByteBuffer?
        do {
            chunk = try await source.next()
        } catch {
            throw EitherError.first(error)
        }
        var buffer = chunk.map { Buffer(copying: Array(buffer: $0)) } ?? Buffer()
        do {
            // `.some(nil)` marks end-of-stream with no trailers, which is what Hummingbird delivers.
            return try await body(&buffer, chunk == nil ? .some(nil) : nil)
        } catch {
            throw EitherError.second(error)
        }
    }
}

/// Holds the body iterator across reads. A class because ``HummingbirdReader`` is a struct the handler
/// carries between reads while the position has to survive each one.
private final class BodySource: @unchecked Sendable {
    private var iterator: RequestBody.AsyncIterator?

    init(_ body: RequestBody) { iterator = body.makeAsyncIterator() }

    func next() async throws -> ByteBuffer? {
        guard var iterator else { return nil }
        let chunk = try await iterator.next()
        self.iterator = chunk == nil ? nil : iterator
        return chunk
    }
}
