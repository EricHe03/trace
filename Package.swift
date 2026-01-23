// swift-tools-version: 6.0

#if canImport(AppleProductTypes)
import AppleProductTypes
#endif
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

let package = Package(
    name: "Trace",
    platforms: [
        .iOS("16.0")
    ],
    products: appProducts + [
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
    ],
    targets: [
        // ═══════════════════════════════════════════════════════
        // Foundation Layer
        // ═══════════════════════════════════════════════════════

        /// TraceCore: Shared models, storage, and logging
        /// Dependencies: None
        .target(
            name: "TraceCore",
            dependencies: ["TraceCompression"],
            path: "TraceCore"
        ),

        /// TraceCompression: Compression/decompression algorithms
        /// Dependencies: None
        .target(
            name: "TraceCompression",
            path: "TraceCompression"
        ),

        // ═══════════════════════════════════════════════════════
        // Infrastructure Layer
        // ═══════════════════════════════════════════════════════

        /// TraceSecurity: Certificate management and TLS handling
        /// Dependencies: TraceCore, TraceNetworking
        .target(
            name: "TraceSecurity",
            dependencies: ["TraceCore", "TraceNetworking"],
            path: "TraceSecurity"
        ),

        /// TraceNetworking: Protocol parsers (HTTP, HTTP2, WebSocket, etc.)
        /// Dependencies: TraceCore
        .target(
            name: "TraceNetworking",
            dependencies: ["TraceCore"],
            path: "TraceNetworking"
        ),

        /// TracePacket: IP/TCP parsing and reassembly
        .target(
            name: "TracePacket",
            dependencies: ["TraceCore"],
            path: "TracePacket"
        ),

        /// HevSocks5Tunnel: C tunnel over SOCKS5 (tun2socks replacement)
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

        /// TraceProxy: MITM proxy and connection management
        /// Dependencies: TraceCore, TraceNetworking, TraceSecurity
        .target(
            name: "TraceProxy",
            dependencies: ["TraceCore", "TraceNetworking", "TraceSecurity", "TraceFeatures"],
            path: "TraceProxy"
        ),

        /// TraceFeatures: Application features (breakpoints, scripts, etc.)
        /// Dependencies: TraceCore, TraceSecurity
        .target(
            name: "TraceFeatures",
            dependencies: ["TraceCore", "TraceSecurity"],
            path: "TraceFeatures"
        ),

        /// TraceUI: Reusable SwiftUI components
        /// Dependencies: TraceCore, TraceFeatures
        .target(
            name: "TraceUI",
            dependencies: ["TraceCore", "TraceFeatures"],
            path: "TraceUI"
        ),

        // ═══════════════════════════════════════════════════════
        // App Targets
        // ═══════════════════════════════════════════════════════

        /// Main App Target
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

        /// VPN Network Extension
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

        /// Widget Extension
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
                "TraceVPN"
            ],
            path: "TraceTests"
        ),
        .testTarget(
            name: "TraceUITests",
            dependencies: ["Trace"],
            path: "TraceUITests"
        )
    ],
    swiftLanguageModes: [
        .v6
    ]
)
