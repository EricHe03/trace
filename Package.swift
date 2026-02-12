// swift-tools-version: 6.0

#if canImport(AppleProductTypes)
import AppleProductTypes
#endif
import Foundation
import PackageDescription

let curlVendorSources: [String] = {
    let excludedSources: Set<String> = [
        // We embed curl as an in-process runtime and call operate() directly.
        // Excluding the CLI entrypoint avoids exporting an unnecessary main symbol.
        "src/tool_main.c"
    ]
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sourceListURL = root
        .appendingPathComponent("ThirdParty")
        .appendingPathComponent("curl-shim")
        .appendingPathComponent("curl_vendor_sources.txt")
    guard let contents = try? String(contentsOf: sourceListURL, encoding: .utf8) else {
        return []
    }
    return contents
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { !$0.isEmpty }
        .filter { !excludedSources.contains($0) }
}()

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
    .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7")
]

let traceCompressionDependencies: [Target.Dependency] = [
    .product(name: "libzstd", package: "zstd")
]

let traceSecurityDependencies: [Target.Dependency] = [
    "TraceCore",
    "TraceNetworking",
    .product(name: "X509", package: "swift-certificates"),
    .product(name: "SwiftASN1", package: "swift-asn1")
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
            name: "TraceCurlRuntime",
            targets: ["TraceCurlRuntime"]
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

let packageTargets: [Target] = [
        // ═══════════════════════════════════════════════════════
        // Foundation Layer
        // ═══════════════════════════════════════════════════════

        // TraceCore: Shared models, storage, and logging
        // Dependencies: None
        .target(
            name: "TraceCore",
            dependencies: ["TraceCompression"],
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
        // Dependencies: TraceCore, TraceNetworking
        .target(
            name: "TraceSecurity",
            dependencies: traceSecurityDependencies,
            path: "TraceSecurity"
        ),

        // TraceNetworking: Protocol parsers (HTTP, HTTP2, WebSocket, etc.)
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

        // CMBedTLS: Vendored mbed TLS backend used by curl runtime.
        .target(
            name: "CMBedTLS",
            path: "ThirdParty/mbedtls",
            exclude: [
                "library/CMakeLists.txt",
                "library/Makefile",
                "library/.gitignore"
            ],
            sources: ["library"],
            publicHeadersPath: "include"
        ),

        // CNghttp2: Vendored nghttp2 backend used by curl runtime for HTTP/2.
        .target(
            name: "CNghttp2",
            path: "ThirdParty/nghttp2",
            exclude: [
                "lib/CMakeLists.txt",
                "lib/Makefile.am",
                "lib/Makefile.msvc",
                "lib/config.cmake.in",
                "lib/libnghttp2.pc.in",
                "lib/version.rc.in",
                "lib/includes/CMakeLists.txt",
                "lib/includes/Makefile.am",
                "lib/includes/nghttp2/nghttp2ver.h.in",
                "lib/.gitignore"
            ],
            sources: ["lib"],
            publicHeadersPath: "lib/includes",
            cSettings: [
                .headerSearchPath("lib/includes"),
                .headerSearchPath("../curl-shim/include")
            ]
        ),

        // CCurlVendor: Vendored curl lib/tool sources built in-process.
        .target(
            name: "CCurlVendor",
            dependencies: ["CMBedTLS", "CNghttp2"],
            path: "ThirdParty/curl",
            sources: curlVendorSources,
            publicHeadersPath: "include",
            cSettings: [
                .define("BUILDING_LIBCURL"),
                .define("CURL_HIDDEN_SYMBOLS"),
                .define("HAVE_CONFIG_H"),
                .define("CURL_STATICLIB"),
                .headerSearchPath("include"),
                .headerSearchPath("lib"),
                .headerSearchPath("src"),
                .headerSearchPath("../curl-shim/include"),
                .headerSearchPath("../mbedtls/include"),
                .headerSearchPath("../nghttp2/lib/includes")
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),

        // CCurlShim: C ABI shim for vendored curl integration.
        .target(
            name: "CCurlShim",
            dependencies: ["CCurlVendor"],
            path: "ThirdParty/curl-shim",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../curl/include"),
                .headerSearchPath("../curl/lib"),
                .headerSearchPath("../curl/src")
            ]
        ),

        // TraceCurlRuntime: Swift wrapper around CCurlShim runtime capabilities.
        .target(
            name: "TraceCurlRuntime",
            dependencies: ["CCurlShim"],
            path: "TraceCurlRuntime",
            resources: [
                .copy("Resources/apple-system-roots.pem")
            ]
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
        // Dependencies: TraceCore, TraceNetworking, TraceSecurity
        .target(
            name: "TraceProxy",
            dependencies: ["TraceCore", "TraceNetworking", "TraceSecurity", "TraceFeatures"],
            path: "TraceProxy"
        ),

        // TraceFeatures: Application features (breakpoints, scripts, etc.)
        // Dependencies: TraceCore, TraceSecurity
        .target(
            name: "TraceFeatures",
            dependencies: ["TraceCore", "TraceSecurity", "TraceCurlRuntime"],
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
            dependencies: [
                "TraceCore",
                "TraceSecurity",
                "TraceNetworking",
                "TraceProxy",
                "HevSocks5Tunnel",
                "TracePacket"
            ],
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
