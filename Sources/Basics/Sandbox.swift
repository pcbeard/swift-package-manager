/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Foundation
import TSCBasic
import TSCUtility

public enum Sandbox {
    public static func apply(
        command: [String],
        writableDirectories: [AbsolutePath] = [],
        strictness: Strictness = .default
    ) -> [String] {
        #if os(macOS)
        let profile = macOSSandboxProfile(writableDirectories: writableDirectories, strictness: strictness)
        return ["/usr/bin/sandbox-exec", "-p", profile] + command
        #else
        // rdar://40235432, rdar://75636874 tracks implementing sandboxes for other platforms.
        return command
        #endif
    }

    public enum Strictness: Equatable {
        case `default`
        case manifest_pre_53 // backwards compatibility for manifests
        case writableTemporaryDirectory
    }
}

// MARK: - macOS

#if os(macOS)
fileprivate func macOSSandboxProfile(
    writableDirectories: [AbsolutePath],
    strictness: Sandbox.Strictness
) -> String {
    var contents = "(version 1)\n"

    // Deny everything by default.
    contents += "(deny default)\n"

    // Import the system sandbox profile.
    contents += "(import \"system.sb\")\n"

    // Allow reading all files; ideally we'd only allow the package directory and any dependencies,
    // but all kinds of system locations need to be accessible.
    contents += "(allow file-read*)\n"

    // This is needed to launch any processes.
    contents += "(allow process*)\n"

    // The following accesses are only needed when interpreting the manifest (versus running a compiled version).
    if strictness == .manifest_pre_53 {
        // This is required by the Swift compiler.
        contents += "(allow sysctl*)\n"
    }

    // Allow writing only to certain directories.
    var writableDirectoriesExpression = writableDirectories.map {
        "(subpath \(resolveSymlinks($0).quotedAsSubpathForSandboxProfile))"
    }
    // The following accesses are only needed when interpreting the manifest (versus running a compiled version).
    if strictness == .manifest_pre_53 {
        writableDirectoriesExpression += Platform.threadSafeDarwinCacheDirectories.get().map {
            ##"(regex #"^\##($0.pathString)/org\.llvm\.clang.*")"##
        }
    }
    // Optionally allow writing to temporary directories (a lot of use of Foundation requires this).
    else if strictness == .writableTemporaryDirectory {
        // Add `subpath` expressions for the regular and the Foundation temporary directories.
        for tmpDir in ["/tmp", NSTemporaryDirectory()] {
            writableDirectoriesExpression += ["(subpath \(resolveSymlinks(AbsolutePath(tmpDir)).quotedAsSubpathForSandboxProfile))"]
        }
    }

    if writableDirectoriesExpression.count > 0 {
        contents += "(allow file-write*\n"
        for expression in writableDirectoriesExpression {
            contents += "    \(expression)\n"
        }
        contents += ")\n"
    }

    return contents
}

fileprivate extension AbsolutePath {
    /// Private computed property that returns a version of the path as a string quoted for use as a subpath in a .sb sandbox profile.
    var quotedAsSubpathForSandboxProfile: String {
        return "\"" + self.pathString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}

extension TSCUtility.Platform {
    fileprivate static let threadSafeDarwinCacheDirectories = ThreadSafeArrayStore<AbsolutePath>(Self.darwinCacheDirectories())
}
#endif
