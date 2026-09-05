// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-hummingbird project authors

public import HTTPAPIs
public import HTTPTypes
public import WireMVC

import AsyncAlgorithms
public import BasicContainers
public import NIOCore

/// What a natively mounted route refuses to serve.
public enum WireMVCHummingbirdError: Error, CustomStringConvertible {
    /// The handler returned without writing a response, which no route may do.
    case handlerFinishedWithoutResponding

    public var description: String {
        switch self {
        case .handlerFinishedWithoutResponding:
            "A WireMVC route handler returned without sending a response."
        }
    }
}

/// A copyable `HTTPResponseSender` over Hummingbird's response, with two paths.
///
/// `sendAndFinish` — what every typed route takes — hands the whole response over at once, so the route
/// closure can return a buffered `Response` and nothing outlives it. `send(_:)` starts a streamed
/// response, which necessarily does outlive it; see ``ResponseChannel``.
public struct HummingbirdResponseSender: HTTPResponseSender {
    public typealias Writer = HummingbirdWriter

    let channel: ResponseChannel

    public mutating func sendInformational(_ response: HTTPResponse) async throws {}

    public consuming func send(_ response: HTTPResponse) async throws -> HummingbirdWriter {
        channel.streamed(response)
        return HummingbirdWriter(channel: channel)
    }

    public consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        channel.complete(response, HummingbirdWriter.drain(&buffer))
    }
}

/// Writes streamed body chunks onto the channel, where the route's response body reads them.
public struct HummingbirdWriter: CallerAsyncWriter {
    public typealias WriteElement = UInt8
    public typealias WriteFailure = Never
    public typealias FinalElement = HTTPFields?

    let channel: ResponseChannel

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        // Rendezvous: this suspends until the response body takes the chunk, so a producer faster than the
        // peer is slowed rather than buffered.
        await channel.body.send(Self.drain(&buffer))
    }

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let last = Self.drain(&buffer)
        if last.readableBytes > 0 { await channel.body.send(last) }
        channel.body.finish()
    }

    /// Moves a `~Copyable` buffer's bytes into a `ByteBuffer`, which is Hummingbird's currency.
    static func drain<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ buffer: inout Buffer
    ) -> ByteBuffer where Buffer.Element: ~Copyable {
        var bytes = ByteBuffer()
        bytes.reserveCapacity(buffer.count)
        var consumer = buffer.consumeAll()
        while let byte = consumer.next() { bytes.writeInteger(byte) }
        return bytes
    }
}
