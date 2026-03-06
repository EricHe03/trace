// swift-tools-version: 6.0

#if canImport(AppleProductTypes)
import AppleProductTypes
#endif
import Foundation
import PackageDescription

#if canImport(AppleProductTypes)
let appProducts: [Product] = [
    .iOSApplication(
        name: "Trace",
        targets: ["Trace"],
        bundleIdentifier: "com.justin.trace",
        teamIdentifier: nil,
        displayVersion: "1.0.0",
        bundleVersion: "1",
        appIcon: .asset("AppIcon"),
        accentColor: .asset("AccentColor"),
        supportedDeviceFamilies: [
            .phone,
            .pad
        ],
        supportedInterfaceOrientations: [
            .portrait,
            .landscapeLeft,
            .landscapeRight,
            .portraitUpsideDown(.when(deviceFamilies: [.pad]))
        ]
    )
]
#else
let appProducts: [Product] = []
#endif

let externalDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.17.1"),
    .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.5.1"),
    .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.0.0")
]

let packageRootPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let quicheBuildRoot = "\(packageRootPath)/build/quiche"
let quicheIncludePath = "\(quicheBuildRoot)/include"
let quicheXCFrameworkRelativePath = "build/quiche/quiche.xcframework"
let quicheXCFrameworkPath = "\(packageRootPath)/\(quicheXCFrameworkRelativePath)"
let quicheDeviceLibraryPath = "\(quicheBuildRoot)/lib/aarch64-apple-ios/libquiche.a"
let quicheSimulatorLibraryPath = "\(quicheBuildRoot)/lib/ios-simulator-universal/libquiche.a"
let quicheStaticLibrariesAvailable = FileManager.default.fileExists(atPath: quicheDeviceLibraryPath) &&
    FileManager.default.fileExists(atPath: quicheSimulatorLibraryPath)
let quicheXCFrameworkAvailable = FileManager.default.fileExists(atPath: quicheXCFrameworkPath)
let quicheHeadersAvailable = FileManager.default.fileExists(atPath: quicheIncludePath)
let quicheArtifactsAvailable = quicheHeadersAvailable && (quicheXCFrameworkAvailable || quicheStaticLibrariesAvailable)
let quicheSDKName = ProcessInfo.processInfo.environment["SDK_NAME"]?.lowercased() ?? ""
let quichePlatformName = ProcessInfo.processInfo.environment["PLATFORM_NAME"]?.lowercased() ?? ""
let quicheEffectivePlatformName = ProcessInfo.processInfo.environment["EFFECTIVE_PLATFORM_NAME"]?.lowercased() ?? ""
let quichePreferredLibraryPath: String = if quicheSDKName.contains("iphonesimulator") ||
    quichePlatformName.contains("iphonesimulator") ||
    quicheEffectivePlatformName.contains("iphonesimulator") {
    quicheSimulatorLibraryPath
} else if quicheSDKName.contains("iphoneos") ||
    quichePlatformName == "iphoneos" ||
    quicheEffectivePlatformName == "-iphoneos" {
    quicheDeviceLibraryPath
} else {
    // Default to simulator archive when platform context is unavailable (for indexing/resolution).
    quicheSimulatorLibraryPath
}

let quicheLinkerFlags = [quichePreferredLibraryPath]

let cquicheFFICSettings: [CSetting] = quicheArtifactsAvailable
    ? [
        .headerSearchPath("../../build/quiche/include"),
        .define("CQUICHE_WITH_QUICHE")
    ]
    : []

let cquicheFFIDependencies: [Target.Dependency] = quicheXCFrameworkAvailable
    ? [
        "QuicheBinary"
    ]
    : []

let cquicheFFILinkerSettings: [LinkerSetting] = (!quicheXCFrameworkAvailable && quicheStaticLibrariesAvailable)
    ? [
        .unsafeFlags(quicheLinkerFlags)
    ]
    : []

let quicheBinaryTargets: [Target] = quicheXCFrameworkAvailable
    ? [
        .binaryTarget(
            name: "QuicheBinary",
            path: quicheXCFrameworkRelativePath
        )
    ]
    : []

let traceCompressionDependencies: [Target.Dependency] = [
    .product(name: "libzstd", package: "zstd")
]

let traceCoreDependencies: [Target.Dependency] = [
    "TraceCompression",
    .product(name: "GRDB", package: "GRDB.swift"),
    .product(name: "AsyncHTTPClient", package: "async-http-client"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
]

let traceSecurityDependencies: [Target.Dependency] = [
    "TraceCore",
    .product(name: "X509", package: "swift-certificates"),
    .product(name: "SwiftASN1", package: "swift-asn1"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOHTTP2", package: "swift-nio-http2"),
    .product(name: "NIOWebSocket", package: "swift-nio"),
    .product(name: "NIOSSL", package: "swift-nio-ssl"),
    .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
]

let traceQUICDependencies: [Target.Dependency] = [
    "TraceCore",
    "CQuicheFFI"
]

let traceProxyDependencies: [Target.Dependency] = [
    "TraceCore",
    "TraceCompression",
    "TraceSecurity",
    "TraceFeatures",
    "TraceQUIC",
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOHTTP2", package: "swift-nio-http2"),
    .product(name: "NIOWebSocket", package: "swift-nio"),
    .product(name: "NIOSSL", package: "swift-nio-ssl"),
    .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
]

let traceFeaturesDependencies: [Target.Dependency] = [
    "TraceCore",
    "TraceSecurity",
    "TraceQUIC",
    .product(name: "AsyncHTTPClient", package: "async-http-client"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio")
]

let traceVPNDependencies: [Target.Dependency] = [
    "TraceCore",
    "TraceSecurity",
    "TraceNetworking",
    "TraceProxy",
    "TraceQUIC",
    "HevSocks5Tunnel",
    "TracePacket",
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
]

let packageProducts: [Product] = appProducts + [
    // ═══════════════════════════════════════════════════════
    // Foundation Layer - Core modules with no/minimal dependencies
    // ═══════════════════════════════════════════════════════
    .library(
        name: "TraceCore",
        targets: ["TraceCore"]
    ),
    .library(
        name: "TraceCompression",
        targets: ["TraceCompression"]
    ),

    // ═══════════════════════════════════════════════════════
    // Infrastructure Layer - Building blocks for higher layers
    // ═══════════════════════════════════════════════════════
    .library(
        name: "TraceSecurity",
        targets: ["TraceSecurity"]
    ),
    .library(
        name: "TraceNetworking",
        targets: ["TraceNetworking"]
    ),
    .library(
        name: "TracePacket",
        targets: ["TracePacket"]
    ),
    .library(
        name: "TraceQUIC",
        targets: ["TraceQUIC"]
    ),
    .library(
        name: "HevSocks5Tunnel",
        targets: ["HevSocks5Tunnel"]
    ),

    // ═══════════════════════════════════════════════════════
    // Feature Layer - High-level functionality
    // ═══════════════════════════════════════════════════════
    .library(
        name: "TraceProxy",
        targets: ["TraceProxy"]
    ),
    .library(
        name: "TraceFeatures",
        targets: ["TraceFeatures"]
    ),
    .library(
        name: "TraceUI",
        targets: ["TraceUI"]
    ),

    // ═══════════════════════════════════════════════════════
    // App Targets
    // ═══════════════════════════════════════════════════════
    .library(
        name: "TraceVPN",
        targets: ["TraceVPN"]
    )
]

let packageTargets: [Target] = quicheBinaryTargets + [
    // ═══════════════════════════════════════════════════════
    // Foundation Layer
    // ═══════════════════════════════════════════════════════

    // TraceCore: Shared models, storage, and logging
    // Dependencies: None
    .target(
        name: "TraceCore",
        dependencies: traceCoreDependencies,
        path: "TraceCore"
    ),

    // TraceCompression: Compression/decompression algorithms
    // Dependencies: None
    .target(
        name: "TraceCompression",
        dependencies: traceCompressionDependencies,
        path: "TraceCompression"
    ),

    // ═══════════════════════════════════════════════════════
    // Infrastructure Layer
    // ═══════════════════════════════════════════════════════

    // TraceSecurity: Certificate management and TLS handling
    // Dependencies: TraceCore
    .target(
        name: "TraceSecurity",
        dependencies: traceSecurityDependencies,
        path: "TraceSecurity"
    ),

    // TraceNetworking: Shared networking primitives (DNS parsing, logging, diagnostics)
    // Dependencies: TraceCore, TraceCompression
    .target(
        name: "TraceNetworking",
        dependencies: ["TraceCore", "TraceCompression"],
        path: "TraceNetworking"
    ),

    // TracePacket: IP/TCP parsing and reassembly
    .target(
        name: "TracePacket",
        dependencies: ["TraceCore"],
        path: "TracePacket"
    ),

    // CQuicheFFI: lightweight C shims that isolate quiche ABI calls.
    .target(
        name: "CQuicheFFI",
        dependencies: cquicheFFIDependencies,
        path: "ThirdParty/CQuicheFFI",
        publicHeadersPath: "include",
        cSettings: cquicheFFICSettings,
        linkerSettings: cquicheFFILinkerSettings
    ),

    // TraceQUIC: QUIC/HTTP3 runtime abstractions and client/MITM orchestration.
    .target(
        name: "TraceQUIC",
        dependencies: traceQUICDependencies,
        path: "TraceQUIC"
    ),

    // HevSocks5Tunnel: C tunnel over SOCKS5 (tun2socks replacement)
    .target(
        name: "HevSocks5Tunnel",
        path: "ThirdParty/hev-socks5-tunnel",
        exclude: [
            "Android.mk",
            "Application.mk",
            "build-apple.sh",
            "build.mk",
            "conf",
            "docker",
            "Dockerfile",
            "module.modulemap",
            "third-part/wintun",
            "third-part/hev-task-system/apps",
            "third-part/hev-task-system/tests",
            "third-part/hev-task-system/src/arch",
            "third-part/hev-task-system/src/kern/io/hev-task-io-reactor-epoll.c",
            "third-part/hev-task-system/src/kern/io/hev-task-io-reactor-iocp.c",
            "src/hev-tunnel-linux.c",
            "src/hev-tunnel-freebsd.c",
            "src/hev-tunnel-netbsd.c",
            "src/hev-tunnel-windows.c",
            "src/hev-jni.c",
            "src/misc/hev-wintun.c",
            "src/misc/hev-list.c",
            "src/core/src/hev-rbtree.c"
        ],
        publicHeadersPath: "include",
        cSettings: [
            .define("ENABLE_LIBRARY"),
            .define("COMMIT_ID", to: "\"local\""),
            .define("YAML_VERSION_MAJOR", to: "0"),
            .define("YAML_VERSION_MINOR", to: "2"),
            .define("YAML_VERSION_PATCH", to: "5"),
            .define("YAML_VERSION_STRING", to: "\"0.2.5\""),
            .define("CONFIG_MEMALLOC_SLICE_ALIGN", to: "64"),
            .define("CONFIG_MEMALLOC_SLICE_MAX_SIZE", to: "4096"),
            .define("CONFIG_MEMALLOC_SLICE_MAX_COUNT", to: "1000"),
            .define("ENABLE_STACK_OVERFLOW_DETECTION"),
            .define("ENABLE_MEMALLOC_SLICE"),
            .define("ENABLE_IO_SPLICE_SYSCALL"),
            .define("CONFIG_STACK_BACKEND", to: "STACK_MMAP"),
            .define("CONFIG_STACK_OVERFLOW_DETECTION", to: "1"),
            .define("CONFIG_SCHED_CLOCK", to: "CLOCK_NONE"),
            .headerSearchPath("include"),
            .headerSearchPath("src"),
            .headerSearchPath("src/misc"),
            .headerSearchPath("src/core/include"),
            .headerSearchPath("third-part/hev-task-system/src"),
            .headerSearchPath("third-part/hev-task-system/include"),
            .headerSearchPath("third-part/lwip/src/include"),
            .headerSearchPath("third-part/lwip/src/ports/include"),
            .headerSearchPath("third-part/yaml/include"),
            .unsafeFlags(["-fno-modules", "-fno-implicit-modules"])
        ],
        linkerSettings: [
            .linkedLibrary("pthread")
        ]
    ),

    // ═══════════════════════════════════════════════════════
    // Feature Layer
    // ═══════════════════════════════════════════════════════

    // TraceProxy: MITM proxy and connection management
    // Dependencies: TraceCore, TraceSecurity
    .target(
        name: "TraceProxy",
        dependencies: traceProxyDependencies,
        path: "TraceProxy"
    ),

    // TraceFeatures: Application features (breakpoints, scripts, etc.)
    // Dependencies: TraceCore, TraceSecurity
    .target(
        name: "TraceFeatures",
        dependencies: traceFeaturesDependencies,
        path: "TraceFeatures"
    ),

    // TraceUI: Reusable SwiftUI components
    // Dependencies: TraceCore, TraceFeatures
    .target(
        name: "TraceUI",
        dependencies: ["TraceCore", "TraceFeatures"],
        path: "TraceUI"
    ),

    // ═══════════════════════════════════════════════════════
    // App Targets
    // ═══════════════════════════════════════════════════════

    // Main App Target
    .executableTarget(
        name: "Trace",
        dependencies: [
            "TraceCore",
            "TraceCompression",
            "TraceSecurity",
            "TraceNetworking",
            "TraceFeatures",
            "TraceQUIC",
            "TraceUI",
            "TraceVPN",
            "TracePacket"
        ],
        path: "Trace",
        resources: [
            .process("Assets.xcassets")
        ]
    ),

    // VPN Network Extension
    .target(
        name: "TraceVPN",
        dependencies: traceVPNDependencies,
        path: "TraceVPN"
    ),

    // Widget Extension
    .target(
        name: "TraceWidget",
        dependencies: ["TraceCore"],
        path: "TraceWidget",
        resources: [
            .process("Assets.xcassets")
        ]
    ),

    // ═══════════════════════════════════════════════════════
    // Test Targets
    // ═══════════════════════════════════════════════════════

    .testTarget(
        name: "TraceTests",
        dependencies: [
            "Trace",
            "TraceCore",
            "TraceCompression",
            "TraceSecurity",
            "TraceNetworking",
            "TraceProxy",
            "TraceFeatures",
            "TraceQUIC",
            .product(name: "libzstd", package: "zstd"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            "TraceVPN",
            "TraceWidget"
        ],
        path: "TraceTests"
    ),
    .testTarget(
        name: "TraceUITests",
        dependencies: ["Trace"],
        path: "TraceUITests"
    )
]

let package = Package(
    name: "Trace",
    platforms: [
        .iOS("16.0")
    ],
    products: packageProducts,
    dependencies: externalDependencies,
    targets: packageTargets,
    swiftLanguageModes: [
        .v6
    ]
)
