/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basics
import LLBuildManifest
import PackageGraph
import PackageModel
import SPMBuildCore
import SPMLLBuild
import TSCBasic
import TSCUtility
import Foundation

public final class BuildOperation: PackageStructureDelegate, SPMBuildCore.BuildSystem, BuildErrorAdviceProvider {

    /// The delegate used by the build system.
    public weak var delegate: SPMBuildCore.BuildSystemDelegate?

    /// The build parameters.
    public let buildParameters: BuildParameters

    /// The closure for loading the package graph.
    let packageGraphLoader: () throws -> PackageGraph
    
    /// The closure for invoking build tool plugins in the package graph.
    let buildToolPluginInvoker: (PackageGraph) throws -> [ResolvedTarget: [BuildToolPluginInvocationResult]]

    /// Whether to sandbox commands from build tool plugins.
    public let disableSandboxForPluginCommands: Bool

    /// The llbuild build delegate reference.
    private var buildSystemDelegate: BuildOperationBuildSystemDelegateHandler?

    /// The llbuild build system reference.
    private var buildSystem: SPMLLBuild.BuildSystem?

    /// If build manifest caching should be enabled.
    public let cacheBuildManifest: Bool

    /// The build plan that was computed, if any.
    public private(set) var buildPlan: BuildPlan?

    /// The build description resulting from planing.
    private let buildDescription = ThreadSafeBox<BuildDescription>()

    /// The loaded package graph.
    private let packageGraph = ThreadSafeBox<PackageGraph>()

    /// The output stream for the build delegate.
    private let outputStream: OutputByteStream

    /// The verbosity level to print out at
    private let logLevel: Basics.Diagnostic.Severity

    /// File system to operate on
    private let fileSystem: TSCBasic.FileSystem

    /// ObservabilityScope with which to emit diagnostics
    private let observabilityScope: ObservabilityScope

    public var builtTestProducts: [BuiltTestProduct] {
        (try? getBuildDescription())?.builtTestProducts ?? []
    }

    public init(
        buildParameters: BuildParameters,
        cacheBuildManifest: Bool,
        packageGraphLoader: @escaping () throws -> PackageGraph,
        buildToolPluginInvoker: @escaping (PackageGraph) throws -> [ResolvedTarget: [BuildToolPluginInvocationResult]],
        disableSandboxForPluginCommands: Bool = false,
        outputStream: OutputByteStream,
        logLevel: Basics.Diagnostic.Severity,
        fileSystem: TSCBasic.FileSystem,
        observabilityScope: ObservabilityScope
    ) {
        self.buildParameters = buildParameters
        self.cacheBuildManifest = cacheBuildManifest
        self.packageGraphLoader = packageGraphLoader
        self.buildToolPluginInvoker = buildToolPluginInvoker
        self.disableSandboxForPluginCommands = disableSandboxForPluginCommands
        self.outputStream = outputStream
        self.logLevel = logLevel
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope.makeChildScope(description: "Build Operation")
    }

    public func getPackageGraph() throws -> PackageGraph {
        try self.packageGraph.memoize {
            try self.packageGraphLoader()
        }
    }
    
    public func getBuildToolPluginInvocationResults(for graph: PackageGraph) throws -> [ResolvedTarget: [BuildToolPluginInvocationResult]] {
        return try self.buildToolPluginInvoker(graph)
    }

    /// Compute and return the latest build description.
    ///
    /// This will try skip build planning if build manifest caching is enabled
    /// and the package structure hasn't changed.
    public func getBuildDescription() throws -> BuildDescription {
        return try self.buildDescription.memoize {
            if self.cacheBuildManifest {
                do {
                    // if buildPackageStructure returns a valid description we use that, otherwise we perform full planning
                    if try self.buildPackageStructure() {
                        // confirm the step above created the build description as expected
                        // we trust it to update the build description when needed
                        let buildDescriptionPath = self.buildParameters.buildDescriptionPath
                        guard self.fileSystem.exists(buildDescriptionPath) else {
                            throw InternalError("could not find build descriptor at \(buildDescriptionPath)")
                        }
                        // return the build description that's on disk.
                        return try BuildDescription.load(from: buildDescriptionPath)
                    }
                } catch {
                    // since caching is an optimization, warn about failing to load the cached version
                    self.observabilityScope.emit(warning: "failed to load the cached build description: \(error)")
                }
            }
            // We need to perform actual planning if we reach here.
            return try self.plan()
        }
    }

    /// Cancel the active build operation.
    public func cancel() {
        buildSystem?.cancel()
    }

    /// Perform a build using the given build description and subset.
    public func build(subset: BuildSubset) throws {
        let buildStartTime = DispatchTime.now()

        // Create the build system.
        let buildDescription = try self.getBuildDescription()
        let buildSystem = try self.createBuildSystem(buildDescription: buildDescription)
        self.buildSystem = buildSystem

        // delegate is only available after createBuildSystem is called
        self.buildSystemDelegate?.buildStart(configuration: self.buildParameters.configuration)

        // Perform the build.
        let llbuildTarget = try computeLLBuildTargetName(for: subset)
        let success = buildSystem.build(target: llbuildTarget)

        let duration = buildStartTime.distance(to: .now())

        self.buildSystemDelegate?.buildComplete(success: success, duration: duration)
        self.delegate?.buildSystem(self, didFinishWithResult: success)
        guard success else { throw Diagnostics.fatalError }

        // Create backwards-compatibility symlink to old build path.
        let oldBuildPath = buildParameters.dataPath.parentDirectory.appending(
            component: buildParameters.configuration.dirname
        )
        if self.fileSystem.exists(oldBuildPath) {
            do { try self.fileSystem.removeFileTree(oldBuildPath) }
            catch {
                self.observabilityScope.emit(warning: "unable to delete \(oldBuildPath), skip creating symbolic link: \(error)")
                return
            }
        }

        do {
            try self.fileSystem.createSymbolicLink(oldBuildPath, pointingAt: buildParameters.buildPath, relative: true)
        } catch {
            self.observabilityScope.emit(warning: "unable to create symbolic link at \(oldBuildPath): \(error)")
        }
    }

    /// Compute the llbuild target name using the given subset.
    func computeLLBuildTargetName(for subset: BuildSubset) throws -> String {
        switch subset {
        case .allExcludingTests:
            return LLBuildManifestBuilder.TargetKind.main.targetName
        case .allIncludingTests:
            return LLBuildManifestBuilder.TargetKind.test.targetName
        default:
            // FIXME: This is super unfortunate that we might need to load the package graph.
            let graph = try getPackageGraph()
            if let result = subset.llbuildTargetName(
                for: graph,
                   config: buildParameters.configuration.dirname,
                   observabilityScope: self.observabilityScope
            ) {
                return result
            }
            throw Diagnostics.fatalError
        }
    }

    /// Create the build plan and return the build description.
    private func plan() throws -> BuildDescription {
        // Load the package graph.
        let graph = try getPackageGraph()
        
        // Invoke any build tool plugins in the graph to generate prebuild commands and build commands.
        let buildToolPluginInvocationResults = try getBuildToolPluginInvocationResults(for: graph)

        // Run any prebuild commands provided by build tool plugins. Any failure stops the build.
        let prebuildCommandResults = try graph.reachableTargets.reduce(into: [:], { partial, target in
            partial[target] = try buildToolPluginInvocationResults[target].map { try self.runPrebuildCommands(for: $0) }
        })
        
        // Create the build plan based, on the graph and any information from plugins.
        let plan = try BuildPlan(
            buildParameters: buildParameters,
            graph: graph,
            buildToolPluginInvocationResults: buildToolPluginInvocationResults,
            prebuildCommandResults: prebuildCommandResults,
            fileSystem: self.fileSystem,
            observabilityScope: self.observabilityScope
        )
        self.buildPlan = plan

        let (buildDescription, buildManifest) = try BuildDescription.create(
            with: plan,
            disableSandboxForPluginCommands: self.disableSandboxForPluginCommands,
            fileSystem: self.fileSystem,
            observabilityScope: self.observabilityScope
        )

        // FIXME: ideally this would be done outside of the planning phase,
        // but it would require deeper changes in how we serialize BuildDescription
        // Output a dot graph
        if buildParameters.printManifestGraphviz {
            // FIXME: this seems like the wrong place to print
            var serializer = DOTManifestSerializer(manifest: buildManifest)
            serializer.writeDOT(to: self.outputStream)
            self.outputStream.flush()
        }
        
        // Finally create the llbuild manifest from the plan.
        return buildDescription
    }

    /// Build the package structure target.
    private func buildPackageStructure() throws -> Bool {
        let buildSystem = try self.createBuildSystem(buildDescription: .none)
        self.buildSystem = buildSystem

        // Build the package structure target which will re-generate the llbuild manifest, if necessary.
        return buildSystem.build(target: "PackageStructure")
    }

    /// Create the build system using the given build description.
    ///
    /// The build description should only be omitted when creating the build system for
    /// building the package structure target.
    private func createBuildSystem(buildDescription: BuildDescription?) throws -> SPMLLBuild.BuildSystem {
        // Figure out which progress bar we have to use during the build.
        let progressAnimation: ProgressAnimationProtocol = self.logLevel.isVerbose
            ? MultiLineNinjaProgressAnimation(stream: self.outputStream)
            : NinjaProgressAnimation(stream: self.outputStream)

        let buildExecutionContext = BuildExecutionContext(
            buildParameters,
            buildDescription: buildDescription,
            observabilityScope: self.observabilityScope,
            packageStructureDelegate: self,
            buildErrorAdviceProvider: self
        )

        // Create the build delegate.
        let buildSystemDelegate = BuildOperationBuildSystemDelegateHandler(
            buildSystem: self,
            buildExecutionContext: buildExecutionContext,
            outputStream: self.outputStream,
            progressAnimation: progressAnimation,
            logLevel: self.logLevel,
            observabilityScope: self.observabilityScope,
            delegate: self.delegate
        )
        self.buildSystemDelegate = buildSystemDelegate

        let databasePath = buildParameters.dataPath.appending(component: "build.db").pathString
        let buildSystem = SPMLLBuild.BuildSystem(
            buildFile: buildParameters.llbuildManifest.pathString,
            databaseFile: databasePath,
            delegate: buildSystemDelegate,
            schedulerLanes: buildParameters.jobs
        )

        // TODO: this seems fragile, perhaps we replace commandFailureHandler by adding relevant calls in the delegates chain 
        buildSystemDelegate.commandFailureHandler = {
            buildSystem.cancel()
            self.delegate?.buildSystemDidCancel(self)
        }

        return buildSystem
    }

    /// Runs any prebuild commands associated with the given list of plugin invocation results, in order, and returns the
    /// results of running those prebuild commands.
    private func runPrebuildCommands(for pluginResults: [BuildToolPluginInvocationResult]) throws -> [PrebuildCommandResult] {
        // Run through all the commands from all the plugin usages in the target.
        return try pluginResults.map { pluginResult in
            // As we go we will collect a list of prebuild output directories whose contents should be input to the build,
            // and a list of the files in those directories after running the commands.
            var derivedSourceFiles: [AbsolutePath] = []
            var prebuildOutputDirs: [AbsolutePath] = []
            for command in pluginResult.prebuildCommands {
                self.observabilityScope.emit(info: "Running" + (command.configuration.displayName ?? command.configuration.executable.basename))

                // Run the command configuration as a subshell. This doesn't return until it is done.
                // TODO: We need to also use any working directory, but that support isn't yet available on all platforms at a lower level.
                var commandLine = [command.configuration.executable.pathString] + command.configuration.arguments
                if !self.disableSandboxForPluginCommands {
                    commandLine = Sandbox.apply(command: commandLine, writableDirectories: [pluginResult.pluginOutputDirectory], strictness: .writableTemporaryDirectory)
                }
                let processResult = try Process.popen(arguments: commandLine, environment: command.configuration.environment)
                let output = try processResult.utf8Output() + processResult.utf8stderrOutput()
                if processResult.exitStatus != .terminated(code: 0) {
                    throw StringError("failed: \(command)\n\n\(output)")
                }

                // Add any files found in the output directory declared for the prebuild command after the command ends.
                let outputFilesDir = command.outputFilesDirectory
                if let swiftFiles = try? localFileSystem.getDirectoryContents(outputFilesDir).sorted() {
                    derivedSourceFiles.append(contentsOf: swiftFiles.map{ outputFilesDir.appending(component: $0) })
                }

                // Add the output directory to the list of directories whose structure should affect the build plan.
                prebuildOutputDirs.append(outputFilesDir)
            }

            // Add the results of running any prebuild commands for this invocation.
            return PrebuildCommandResult(derivedSourceFiles: derivedSourceFiles, outputDirectories: prebuildOutputDirs)
        }
    }
    
    public func provideBuildErrorAdvice(for target: String, command: String, message: String) -> String? {
        // Find the target for which the error was emitted.  If we don't find it, we can't give any advice.
        guard let _ = self.buildPlan?.targets.first(where: { $0.target.name == target }) else { return nil }
        
        // Check for cases involving modules that cannot be found.
        if let importedModule = try? RegEx(pattern: "no such module '(.+)'").matchGroups(in: message).first?.first {
            // A target is importing a module that can't be found.  We take a look at the build plan and see if can offer any advice.
            
            // Look for a target with the same module name as the one that's being imported.
            if let importedTarget = self.buildPlan?.targets.first(where: { $0.target.c99name == importedModule }) {
                // For the moment we just check for executables that other targets try to import.
                if importedTarget.target.type == .executable {
                    return "module '\(importedModule)' is the main module of an executable, and cannot be imported by tests and other targets"
                }
                
                // Here we can add more checks in the future.
            }
        }
        return nil
    }

    public func packageStructureChanged() -> Bool {
        do {
            _ = try plan()
        }
        catch Diagnostics.fatalError {
            return false
        }
        catch {
            self.observabilityScope.emit(error)
            return false
        }
        return true
    }
}

extension BuildDescription {
    static func create(with plan: BuildPlan, disableSandboxForPluginCommands: Bool, fileSystem: TSCBasic.FileSystem, observabilityScope: ObservabilityScope) throws -> (BuildDescription, BuildManifest) {
        // Generate the llbuild manifest.
        let llbuild = LLBuildManifestBuilder(plan, disableSandboxForPluginCommands: disableSandboxForPluginCommands, fileSystem: fileSystem, observabilityScope: observabilityScope)
        let buildManifest = try llbuild.generateManifest(at: plan.buildParameters.llbuildManifest)

        let swiftCommands = llbuild.manifest.getCmdToolMap(kind: SwiftCompilerTool.self)
        let swiftFrontendCommands = llbuild.manifest.getCmdToolMap(kind: SwiftFrontendTool.self)
        let testDiscoveryCommands = llbuild.manifest.getCmdToolMap(kind: TestDiscoveryTool.self)
        let copyCommands = llbuild.manifest.getCmdToolMap(kind: CopyTool.self)

        // Create the build description.
        let buildDescription = try BuildDescription(
            plan: plan,
            swiftCommands: swiftCommands,
            swiftFrontendCommands: swiftFrontendCommands,
            testDiscoveryCommands: testDiscoveryCommands,
            copyCommands: copyCommands
        )
        try fileSystem.createDirectory(
            plan.buildParameters.buildDescriptionPath.parentDirectory,
            recursive: true
        )
        try buildDescription.write(to: plan.buildParameters.buildDescriptionPath)
        return (buildDescription, buildManifest)
    }
}

extension BuildSubset {
    /// Returns the name of the llbuild target that corresponds to the build subset.
    func llbuildTargetName(for graph: PackageGraph, config: String, observabilityScope: ObservabilityScope)
        -> String?
    {
        switch self {
        case .allExcludingTests:
            return LLBuildManifestBuilder.TargetKind.main.targetName
        case .allIncludingTests:
            return LLBuildManifestBuilder.TargetKind.test.targetName
        case .product(let productName):
            guard let product = graph.allProducts.first(where: { $0.name == productName }) else {
                observabilityScope.emit(error: "no product named '\(productName)'")
                return nil
            }
            // If the product is automatic, we build the main target because automatic products
            // do not produce a binary right now.
            if product.type == .library(.automatic) {
                observabilityScope.emit(
                    warning:
                        "'--product' cannot be used with the automatic product '\(productName)'; building the default target instead"
                )
                return LLBuildManifestBuilder.TargetKind.main.targetName
            }
            return observabilityScope.trap {
                try product.getLLBuildTargetName(config: config)
            }
        case .target(let targetName):
            guard let target = graph.allTargets.first(where: { $0.name == targetName }) else {
                observabilityScope.emit(error: "no target named '\(targetName)'")
                return nil
            }
            return target.getLLBuildTargetName(config: config)
        }
    }
}

extension Basics.Diagnostic.Severity {
    var isVerbose: Bool {
        return self <= .info
    }
}
