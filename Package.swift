// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import PackageDescription

// A **native** Hummingbird adapter for WireMVC: an `HTTPServerRouteBuilder` that registers collated routes
// straight onto Hummingbird's own `Router`, with no `ServerTransport` and no OpenAPI currency types in
// between.
//
// It exists because the bridge's cost was measured rather than assumed. Serving the same graph on the same
// server, `ServerTransport` costs +16.5 µs and 41 allocations per request over a plain Hummingbird route;
// this costs +3.5 µs and 4. The recovered 13 µs is the bridge's *shape*: crossing into OpenAPI's currency
// types, and the unstructured `Task` plus rendezvous channel that a return-based `register` forces.
//
// A catch-all comes back too. `ServerTransport.register` takes a path string in OpenAPI's `{name}`
// convention and each adapter mangles a wildcard differently, so WireMVC refuses to bridge one; here it is
// Hummingbird's own `**`.
let settings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("LifetimeDependence"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "wire-mvc-hummingbird",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WireMVCHummingbird", targets: ["WireMVCHummingbird"])
    ],
    dependencies: [
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(
            url: "https://github.com/apple/swift-async-algorithms.git",
            exact: "1.1.5",
            traits: ["UnstableAsyncStreaming"]
        ),
    ],
    targets: [
        .target(
            name: "WireMVCHummingbird",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "AsyncStreaming", package: "swift-async-algorithms"),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "WireMVCHummingbirdTests",
            dependencies: [
                "WireMVCHummingbird",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: settings
        ),
    ]
)
