//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

@preconcurrency import SystemPackage


#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

extension Subprocess {
    /// A collection of configurations parameters to use when
    /// spawning a subprocess.
    public struct Configuration: Sendable, Hashable {

        internal enum RunState<Result: Sendable>: Sendable {
            case workBody(Result)
            case monitorChildProcess(TerminationStatus)
        }

        /// The executable to run.
        public var executable: Executable
        /// The arguments to pass to the executable.
        public var arguments: Arguments
        /// The environment to use when running the executable.
        public var environment: Environment
        /// The working directory to use when running the executable.
        public var workingDirectory: FilePath
        /// The platform specifc options to use when
        /// running the subprocess.
        public var platformOptions: PlatformOptions

        public init(
            executable: Executable,
            arguments: Arguments = [],
            environment: Environment = .inherit,
            workingDirectory: FilePath? = nil,
            platformOptions: PlatformOptions = PlatformOptions()
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory ?? .currentWorkingDirectory
            self.platformOptions = platformOptions
        }

        /// Close each input individually, and throw the first error if there's multiple errors thrown
        @Sendable
        private func cleanup(
            process: Subprocess,
            childSide: Bool, parentSide: Bool,
            attemptToTerminateSubProcess: Bool
        ) async throws {
            guard childSide || parentSide || attemptToTerminateSubProcess else {
                return
            }

            var exitError: Error? = nil
            // Attempt to teardown the subprocess
            if attemptToTerminateSubProcess {
                #if os(Windows)
                exitError = process.tryTerminate()
                #else
                await process.teardown(
                    using: self.platformOptions.teardownSequence
                )
                #endif
            }

            let inputCloseFunc: () throws -> Void
            let outputCloseFunc: () throws -> Void
            let errorCloseFunc: () throws -> Void
            if childSide && parentSide {
                // Close all
                inputCloseFunc = process.executionInput.closeAll
                outputCloseFunc = process.executionOutput.closeAll
                errorCloseFunc = process.executionError.closeAll
            } else if childSide {
                // Close child only
                inputCloseFunc = process.executionInput.closeChildSide
                outputCloseFunc = process.executionOutput.closeChildSide
                errorCloseFunc = process.executionError.closeChildSide
            } else {
                // Close parent only
                inputCloseFunc = process.executionInput.closeParentSide
                outputCloseFunc = process.executionOutput.closeParentSide
                errorCloseFunc = process.executionError.closeParentSide
            }

            var inputError: Error?
            var outputError: Error?
            var errorError: Error? // lol
            do {
                try inputCloseFunc()
            } catch {
                inputError = error
            }

            do {
                try outputCloseFunc()
            } catch {
                outputError = error
            }

            do {
                try errorCloseFunc()
            } catch {
                errorError = error // lolol
            }

            if let inputError = inputError {
                throw inputError
            }

            if let outputError = outputError {
                throw outputError
            }

            if let errorError = errorError {
                throw errorError
            }

            if let exitError = exitError {
                throw exitError
            }
        }

        /// Close each input individually, and throw the first error if there's multiple errors thrown
        @Sendable
        internal func cleanupAll(
            input: ExecutionInput,
            output: ExecutionOutput,
            error: ExecutionOutput
        ) throws {
            var inputError: Error?
            var outputError: Error?
            var errorError: Error?

            do {
                try input.closeAll()
            } catch {
                inputError = error
            }

            do {
                try output.closeAll()
            } catch {
                outputError = error
            }

            do {
                try error.closeAll()
            } catch {
                errorError = error
            }

            if let inputError = inputError {
                throw inputError
            }
            if let outputError = outputError {
                throw outputError
            }
            if let errorError = errorError {
                throw errorError
            }
        }

        internal func run<Result>(
            output: RedirectedOutputMethod,
            error: RedirectedOutputMethod,
            isolation: isolated (any Actor)? = #isolation,
            _ body: @escaping (Subprocess, StandardInputWriter) async throws -> Result
        ) async throws -> ExecutionResult<Result> {
            let (readFd, writeFd) = try FileDescriptor.pipe()
            let executionInput: ExecutionInput = .init(storage: .customWrite(readFd, writeFd))
            let executionOutput: ExecutionOutput = try output.createExecutionOutput()
            let executionError: ExecutionOutput = try error.createExecutionOutput()
            let process: Subprocess = try self.spawn(
                withInput: executionInput,
                output: executionOutput,
                error: executionError)
            // After spawn, cleanup child side fds
            try await self.cleanup(
                process: process,
                childSide: true,
                parentSide: false,
                attemptToTerminateSubProcess: false
            )
            return try await withAsyncTaskCancellationHandler {
                async let waitingStatus = try await monitorProcessTermination(forProcessWithIdentifier: process.processIdentifier)
                // Body runs in the same isolation
                do {
                    let result = try await body(process, .init(input: executionInput))
                    // Clean up parent side when body finishes
                    try await self.cleanup(
                        process: process,
                        childSide: false,
                        parentSide: true,
                        attemptToTerminateSubProcess: false
                    )
                    let status: TerminationStatus = try await waitingStatus
                    return ExecutionResult(terminationStatus: status, value: result)
                } catch {
                    // Cleanup everything
                    try await self.cleanup(
                        process: process,
                        childSide: false,
                        parentSide: true,
                        attemptToTerminateSubProcess: false
                    )
                    throw error
                }
            } onCancel: {
                // Attempt to terminate the child process
                // Since the task has already been cancelled,
                // this is the best we can do
                try? await self.cleanup(
                    process: process,
                    childSide: true,
                    parentSide: true,
                    attemptToTerminateSubProcess: true
                )
            }
        }

        internal func run<Result>(
            input: InputMethod,
            output: RedirectedOutputMethod,
            error: RedirectedOutputMethod,
            isolation: isolated (any Actor)? = #isolation,
            _ body: (sending @escaping (Subprocess) async throws -> Result)
        ) async throws -> ExecutionResult<Result> {
            let executionInput = try input.createExecutionInput()
            let executionOutput = try output.createExecutionOutput()
            let executionError = try error.createExecutionOutput()
            let process = try self.spawn(
                withInput: executionInput,
                output: executionOutput,
                error: executionError)
            // After spawn, clean up child side
            try await self.cleanup(
                process: process,
                childSide: true,
                parentSide: false,
                attemptToTerminateSubProcess: false
            )
            return try await withAsyncTaskCancellationHandler {
                async let waitingStatus = try monitorProcessTermination(
                    forProcessWithIdentifier: process.processIdentifier
                )
                do {
                    // Body runs in the same isolation
                    let result = try await body(process)
                    // After body finishes, cleanup parent side
                    try await self.cleanup(
                        process: process,
                        childSide: false,
                        parentSide: true,
                        attemptToTerminateSubProcess: false
                    )
                    let status = try await waitingStatus
                    return ExecutionResult(terminationStatus: status, value: result)
                } catch {
                    try await self.cleanup(
                        process: process,
                        childSide: false,
                        parentSide: true,
                        attemptToTerminateSubProcess: false
                    )
                    throw error
                }
            } onCancel: {
                // Attempt to terminate the child process
                // Since the task has already been cancelled,
                // this is the best we can do
                try? await self.cleanup(
                    process: process,
                    childSide: true,
                    parentSide: true,
                    attemptToTerminateSubProcess: true
                )
            }
        }
    }
}

extension Subprocess.Configuration : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return """
Subprocess.Configuration(
    executable: \(self.executable.description),
    arguments: \(self.arguments.description),
    environment: \(self.environment.description),
    workingDirectory: \(self.workingDirectory),
    platformOptions: \(self.platformOptions.description(withIndent: 1))
)
"""
    }

    public var debugDescription: String {
        return """
Subprocess.Configuration(
    executable: \(self.executable.debugDescription),
    arguments: \(self.arguments.debugDescription),
    environment: \(self.environment.debugDescription),
    workingDirectory: \(self.workingDirectory),
    platformOptions: \(self.platformOptions.description(withIndent: 1))
)
"""
    }
}

// MARK: - Executable
extension Subprocess {
    /// `Subprocess.Executable` defines how should the executable
    /// be looked up for execution.
    public struct Executable: Sendable, Hashable {
        internal enum Configuration: Sendable, Hashable {
            case executable(String)
            case path(FilePath)
        }

        internal let storage: Configuration

        private init(_config: Configuration) {
            self.storage = _config
        }

        /// Locate the executable by its name.
        /// `Subprocess` will use `PATH` value to
        /// determine the full path to the executable.
        public static func named(_ executableName: String) -> Self {
            return .init(_config: .executable(executableName))
        }
        /// Locate the executable by its full path.
        /// `Subprocess` will use this  path directly.
        public static func at(_ filePath: FilePath) -> Self {
            return .init(_config: .path(filePath))
        }
        /// Returns the full executable path given the environment value.
        public func resolveExecutablePath(in environment: Environment) -> FilePath? {
            if let path = self.resolveExecutablePath(withPathValue: environment.pathValue()) {
                return FilePath(path)
            }
            return nil
        }
    }
}

extension Subprocess.Executable : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch storage {
        case .executable(let executableName):
            return executableName
        case .path(let filePath):
            return filePath.string
        }
    }

    public var debugDescription: String {
        switch storage {
        case .executable(let string):
            return "executable(\(string))"
        case .path(let filePath):
            return "path(\(filePath.string))"
        }
    }
}

// MARK: - Arguments
extension Subprocess {
    /// A collection of arguments to pass to the subprocess.
    public struct Arguments: Sendable, ExpressibleByArrayLiteral, Hashable {
        public typealias ArrayLiteralElement = String

        internal let storage: [StringOrRawBytes]
        internal let executablePathOverride: StringOrRawBytes?

        /// Create an Arguments object using the given literal values
        public init(arrayLiteral elements: String...) {
            self.storage = elements.map { .string($0) }
            self.executablePathOverride = nil
        }
        /// Create an Arguments object using the given array
        public init(_ array: [String]) {
            self.storage = array.map { .string($0) }
            self.executablePathOverride = nil
        }

#if !os(Windows) // Windows does NOT support arg0 override
        /// Create an `Argument` object using the given values, but
        /// override the first Argument value to `executablePathOverride`.
        /// If `executablePathOverride` is nil,
        /// `Arguments` will automatically use the executable path
        /// as the first argument.
        /// - Parameters:
        ///   - executablePathOverride: the value to override the first argument.
        ///   - remainingValues: the rest of the argument value
        public init(executablePathOverride: String?, remainingValues: [String]) {
            self.storage = remainingValues.map { .string($0) }
            if let executablePathOverride = executablePathOverride {
                self.executablePathOverride = .string(executablePathOverride)
            } else {
                self.executablePathOverride = nil
            }
        }

        /// Create an `Argument` object using the given values, but
        /// override the first Argument value to `executablePathOverride`.
        /// If `executablePathOverride` is nil,
        /// `Arguments` will automatically use the executable path
        /// as the first argument.
        /// - Parameters:
        ///   - executablePathOverride: the value to override the first argument.
        ///   - remainingValues: the rest of the argument value
        public init(executablePathOverride: Data?, remainingValues: [Data]) {
            self.storage = remainingValues.map { .rawBytes($0.toArray()) }
            if let override = executablePathOverride {
                self.executablePathOverride = .rawBytes(override.toArray())
            } else {
                self.executablePathOverride = nil
            }
        }

        public init(_ array: [Data]) {
            self.storage = array.map { .rawBytes($0.toArray()) }
            self.executablePathOverride = nil
        }
#endif
    }
}

extension Subprocess.Arguments : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        var result: [String] = self.storage.map(\.description)

        if let override = self.executablePathOverride {
            result.insert("override\(override.description)", at: 0)
        }
        return result.description
    }

    public var debugDescription: String { return self.description }
}

// MARK: - Environment
extension Subprocess {
    /// A set of environment variables to use when executing the subprocess.
    public struct Environment: Sendable, Hashable {
        internal enum Configuration: Sendable, Hashable {
            case inherit([StringOrRawBytes : StringOrRawBytes])
            case custom([StringOrRawBytes : StringOrRawBytes])
        }

        internal let config: Configuration

        init(config: Configuration) {
            self.config = config
        }
        /// Child process should inherit the same environment
        /// values from its parent process.
        public static var inherit: Self {
            return .init(config: .inherit([:]))
        }
        /// Override the provided `newValue` in the existing `Environment`
        public func updating(_ newValue: [String : String]) -> Self {
            return .init(config: .inherit(newValue.wrapToStringOrRawBytes()))
        }
        /// Use custom environment variables
        public static func custom(_ newValue: [String : String]) -> Self {
            return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
        }

#if !os(Windows)
        /// Override the provided `newValue` in the existing `Environment`
        public func updating(_ newValue: [Data : Data]) -> Self {
            return .init(config: .inherit(newValue.wrapToStringOrRawBytes()))
        }
        /// Use custom environment variables
        public static func custom(_ newValue: [Data : Data]) -> Self {
            return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
        }
#endif
    }
}

extension Subprocess.Environment : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self.config {
        case .custom(let customDictionary):
            return customDictionary.dictionaryDescription
        case .inherit(let updateValue):
            return "Inherting current environment with updates: \(updateValue.dictionaryDescription)"
        }
    }

    public var debugDescription: String {
        return self.description
    }
}

fileprivate extension Dictionary where Key == String, Value == String {
    func wrapToStringOrRawBytes() -> [Subprocess.StringOrRawBytes : Subprocess.StringOrRawBytes] {
        var result = Dictionary<
            Subprocess.StringOrRawBytes,
            Subprocess.StringOrRawBytes
        >(minimumCapacity: self.count)
        for (key, value) in self {
            result[.string(key)] = .string(value)
        }
        return result
    }
}

fileprivate extension Dictionary where Key == Data, Value == Data {
    func wrapToStringOrRawBytes() -> [Subprocess.StringOrRawBytes : Subprocess.StringOrRawBytes] {
        var result = Dictionary<
            Subprocess.StringOrRawBytes,
            Subprocess.StringOrRawBytes
        >(minimumCapacity: self.count)
        for (key, value) in self {
            result[.rawBytes(key.toArray())] = .rawBytes(value.toArray())
        }
        return result
    }
}

fileprivate extension Dictionary where Key == Subprocess.StringOrRawBytes, Value == Subprocess.StringOrRawBytes {
    var dictionaryDescription: String {
        var result = "[\n"
        for (key, value) in self {
            result += "\t\(key.description) : \(value.description),\n"
        }
        result += "]"
        return result
    }
}

fileprivate extension Data {
    func toArray<T>() -> [T] {
        return self.withUnsafeBytes { ptr in
            return Array(ptr.bindMemory(to: T.self))
        }
    }
}

// MARK: - TerminationStatus
extension Subprocess {
    /// An exit status of a subprocess.
    @frozen
    public enum TerminationStatus: Sendable, Hashable, Codable {
        #if canImport(WinSDK)
        public typealias Code = DWORD
        #else
        public typealias Code = CInt
        #endif

        /// The subprocess was existed with the given code
        case exited(Code)
        /// The subprocess was signalled with given exception value
        case unhandledException(Code)
        /// Whether the current TerminationStatus is successful.
        public var isSuccess: Bool {
            switch self {
            case .exited(let exitCode):
                return exitCode == 0
            case .unhandledException(_):
                return false
            }
        }
    }
}

extension Subprocess.TerminationStatus : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .exited(let code):
            return "exited(\(code))"
        case .unhandledException(let code):
            return "unhandledException(\(code))"
        }
    }

    public var debugDescription: String {
        return self.description
    }
}

// MARK: - Internal
extension Subprocess {
    internal enum StringOrRawBytes: Sendable, Hashable {
        case string(String)
        case rawBytes([CChar])

        // Return value needs to be deallocated manually by callee
        func createRawBytes() -> UnsafeMutablePointer<CChar> {
            switch self {
            case .string(let string):
                return strdup(string)
            case .rawBytes(let rawBytes):
                return strdup(rawBytes)
            }
        }

        var stringValue: String? {
            switch self {
            case .string(let string):
                return string
            case .rawBytes(let rawBytes):
                return String(validatingUTF8: rawBytes)
            }
        }

        var description: String {
            switch self {
            case .string(let string):
                return string
            case .rawBytes(let bytes):
                return bytes.description
            }
        }

        var count: Int {
            switch self {
            case .string(let string):
                return string.count
            case .rawBytes(let rawBytes):
                return strnlen(rawBytes, Int.max)
            }
        }

        func hash(into hasher: inout Hasher) {
            // If Raw bytes is valid UTF8, hash it as so
            switch self {
            case .string(let string):
                hasher.combine(string)
            case .rawBytes(let bytes):
                if let stringValue = self.stringValue {
                    hasher.combine(stringValue)
                } else {
                    hasher.combine(bytes)
                }
            }
        }
    }
}

extension FilePath {
    static var currentWorkingDirectory: Self {
        let path = getcwd(nil, 0)!
        defer { free(path) }
        return .init(String(cString: path))
    }
}

extension Optional where Wrapped : Collection {
    func withOptionalUnsafeBufferPointer<Result>(
        _ body: ((UnsafeBufferPointer<Wrapped.Element>)?) throws -> Result
    ) rethrows -> Result {
        switch self {
        case .some(let wrapped):
            guard let array: Array<Wrapped.Element> = wrapped as? Array else {
                return try body(nil)
            }
            return try array.withUnsafeBufferPointer { ptr in
                return try body(ptr)
            }
        case .none:
            return try body(nil)
        }
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<Result>(
        _ body: ((UnsafePointer<Int8>)?) throws -> Result
    ) rethrows -> Result {
        switch self {
        case .none:
            return try body(nil)
        case .some(let wrapped):
            return try wrapped.withCString {
                return try body($0)
            }
        }
    }

    var stringValue: String {
        return self ?? "nil"
    }
}

// MARK: - Stubs for the one from Foundation
public enum QualityOfService: Int, Sendable {
    case userInteractive    = 0x21
    case userInitiated      = 0x19
    case utility            = 0x11
    case background         = 0x09
    case `default`          = -1
}

internal func withAsyncTaskCancellationHandler<Result>(
    _ body: @escaping () async throws -> Result,
    onCancel handler: @Sendable @escaping () async -> Void,
    isolation: isolated (any Actor)? = #isolation
) async rethrows -> Result {
    return try await withThrowingTaskGroup(
        of: Void.self,
        returning: Result.self
    ) { group in
        group.addTask {
            // wait until cancelled
            do { while true { try await Task.sleep(nanoseconds: 1_000_000_000) } } catch {}
            // Run task cancel handler
            await handler()
        }

        let result = try await body()
        group.cancelAll()
        return result
    }
}

