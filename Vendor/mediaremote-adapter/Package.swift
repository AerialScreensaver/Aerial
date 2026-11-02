// swift-tools-version:5.9
//
// Vendored mediaremote-adapter (https://github.com/ungive/mediaremote-adapter,
// BSD-3-Clause) — see UPSTREAM.md. Xcode builds this dynamic product as
// MediaRemoteAdapter.framework and embeds it in the Companion app. The app
// never calls into it: /usr/bin/perl loads it by path (mediaremote-adapter.pl)
// and resolves the exported `adapter_*` C functions by name, which is why the
// target is compiled with default symbol visibility. Unsafe flags are allowed
// because the package is local.

import PackageDescription

let package = Package(
    name: "MediaRemoteAdapter",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MediaRemoteAdapter", type: .dynamic, targets: ["MediaRemoteAdapter"]),
    ],
    targets: [
        .target(
            name: "MediaRemoteAdapter",
            path: ".",
            // `test.m` (the upstream `test` command) needs the separate
            // MediaPlayer-linked test client we do not ship; Aerial probes
            // with `get` instead.
            exclude: ["mediaremote-adapter.pl", "LICENSE", "UPSTREAM.md", "src/adapter/test.m"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                // Code coverage: Xcode's test action instruments package C
                // targets but does not link the profile runtime into a
                // dynamic product, so the link fails on
                // ___llvm_profile_runtime. Nothing here is under test.
                .unsafeFlags(["-fobjc-arc", "-fvisibility=default",
                              "-fno-profile-instr-generate", "-fno-coverage-mapping"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
