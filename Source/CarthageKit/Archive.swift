import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD

public final class Archive {

    // MARK: - Public

    public static func archiveFrameworks(frameworkNames: [String], directoryURL: URL, customOutputURL: URL?, frameworkFoundHandler: ((String) -> Void)? = nil) -> SignalProducer<URL, CarthageError> {

        if let definedOutputURL = customOutputURL, definedOutputURL.path.isEmpty {
            return SignalProducer<URL, CarthageError>(error: CarthageError.invalidArgument(description: "Custom archive output path should not be empty"))
        }

        let configuration = "Release"
        let frameworks: SignalProducer<[String], CarthageError>
        if !frameworkNames.isEmpty {
            frameworks = .init(value: frameworkNames.map {
                return $0.appendingPathExtension("framework")
            })
        } else {
            let schemeMatcher = SchemeCartfile.from(directoryURL: directoryURL).value?.matcher
            frameworks = Xcode.buildableSchemesInDirectory(directoryURL, withConfiguration: configuration, schemeMatcher: schemeMatcher)
                .flatMap(.merge) { scheme, project -> SignalProducer<BuildSettings, CarthageError> in
                    let buildArguments = BuildArguments(project: project, scheme: scheme, configuration: configuration)
                    return Xcode.loadBuildSettings(with: buildArguments)
                }
                .flatMap(.concat) { settings -> SignalProducer<String, CarthageError> in
                    if let wrapperName = settings.wrapperName.value, settings.productType.value == .framework {
                        return .init(value: wrapperName)
                    } else {
                        return .empty
                    }
                }
                .collect()
                .map { Array(Set($0)).sorted() }
        }

        return frameworks.flatMap(.merge) { frameworks -> SignalProducer<URL, CarthageError> in
            return SignalProducer<Platform, CarthageError>(Platform.supportedPlatforms)
                .flatMap(.merge) { platform -> SignalProducer<String, CarthageError> in
                    return SignalProducer(frameworks).map { framework in
                        return platform.relativePath.appendingPathComponent(framework)
                    }
                }
                .map { relativePath -> (relativePath: String, url: URL) in
                    return (relativePath, directoryURL.appendingPathComponent(relativePath))
                }
                .filter { file in file.url.isExistingFileOrDirectory }
                .flatMap(.merge) { framework -> SignalProducer<String, CarthageError> in
                    let dSYM = framework.relativePath.appendingPathExtension("dSYM")
                    let bcsymbolmapsProducer = Frameworks.BCSymbolMapsForFramework(framework.url)
                        // generate relative paths for the bcsymbolmaps so they print nicely
                        .map { url in framework.relativePath.deletingLastPathComponent.appendingPathComponent(url.lastPathComponent) }
                    let extraFilesProducer = SignalProducer(value: dSYM)
                        .concat(bcsymbolmapsProducer)
                        .filter { _ in framework.url.isExistingFileOrDirectory }
                    return SignalProducer(value: framework.relativePath)
                        .concat(extraFilesProducer)
                }
                .on(value: { path in
                    frameworkFoundHandler?(path)
                })
                .collect()
                .flatMap(.merge) { paths -> SignalProducer<URL, CarthageError> in

                    let foundFrameworks = paths
                        .lazy
                        .map { $0.lastPathComponent }
                        .filter { $0.hasSuffix(".framework") }

                    if Set(foundFrameworks) != Set(frameworks) {
                        let error = CarthageError.invalidArgument(
                            description: "Could not find any copies of \(frameworks.joined(separator: ", ")). "
                                + "Make sure you're in the project's root and that the frameworks have already been built using 'carthage build --no-skip-current'."
                        )
                        return SignalProducer(error: error)
                    }

                    let outputURL = outputURLForBaseURL(customOutputURL ?? directoryURL, frameworks: frameworks)

                    _ = try? FileManager
                        .default
                        .removeItem(at: outputURL)
                    _ = try? FileManager
                        .default
                        .createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                    return zip(paths: paths, into: outputURL, workingDirectoryURL: directoryURL)
            }
        }
    }

    // MARK: - Internal

    /// Unarchives the given file URL into a temporary directory, using its
    /// extension to detect archive type, then sends the file URL to that directory.
    static func unarchive(archive fileURL: URL) -> SignalProducer<URL, CarthageError> {
        switch fileURL.pathExtension {
        case "gz", "tgz", "bz2", "xz":
            return untar(archive: fileURL)
        default:
            return unzip(archive: fileURL)
        }
    }

    /// Zips the given input paths (recursively) into an archive that will be
    /// located at the given URL.
    static func zip(paths: [String], into archiveURL: URL, workingDirectoryURL: URL) -> SignalProducer<URL, CarthageError> {
        precondition(!paths.isEmpty)
        precondition(archiveURL.isFileURL)

        let task = Task("/usr/bin/env", arguments: [ "zip", "-q", "-r", "--symlinks", archiveURL.path ] + paths, workingDirectoryPath: workingDirectoryURL.path)

        return task.launch()
            .mapError(CarthageError.taskError)
            .then(SignalProducer<URL, CarthageError>(value: archiveURL))
    }

    // MARK: - Private

    /// Returns an appropriate output file path for the resulting zip file using
    /// the given option and frameworks.
    private static func outputURLForBaseURL(_ baseURL: URL, frameworks: [String]) -> URL {
        let defaultOutputPath = "\(frameworks.first!).zip"

        if baseURL.isExistingDirectory || baseURL.path.hasSuffix("/") {
            return baseURL.appendingPathComponent(defaultOutputPath)
        } else {
            return baseURL
        }
    }

    /// Unzips the archive at the given file URL, extracting into the given
    /// directory URL (which must already exist).
    private static func unzip(archive fileURL: URL, to destinationDirectoryURL: URL) -> SignalProducer<URL, CarthageError> {
        precondition(fileURL.isFileURL)
        precondition(destinationDirectoryURL.isFileURL)

        let task = Task("/usr/bin/env", arguments: [ "unzip", "-uo", "-qq", "-d", destinationDirectoryURL.path, fileURL.path ])
        return task.launch()
            .mapError(CarthageError.taskError)
            .then(SignalProducer<URL, CarthageError>(value: destinationDirectoryURL))
    }

    /// Untars an archive at the given file URL, extracting into the given
    /// directory URL (which must already exist).
    private static func untar(archive fileURL: URL, to destinationDirectoryURL: URL) -> SignalProducer<URL, CarthageError> {
        precondition(fileURL.isFileURL)
        precondition(destinationDirectoryURL.isFileURL)

        let task = Task("/usr/bin/env", arguments: [ "tar", "-xf", fileURL.path, "-C", destinationDirectoryURL.path ])
        return task.launch()
            .mapError(CarthageError.taskError)
            .then(SignalProducer<URL, CarthageError>(value: destinationDirectoryURL))
    }

    /// Unzips the archive at the given file URL into a temporary directory, then
    /// sends the file URL to that directory.
    private static func unzip(archive fileURL: URL) -> SignalProducer<URL, CarthageError> {
        return FileManager.default.reactive.createTemporaryDirectory()
            .flatMap(.merge) { directoryURL in
                return unzip(archive: fileURL, to: directoryURL)
                    .then(SignalProducer<URL, CarthageError>(value: directoryURL))
        }
    }

    /// Untars an archive at the given file URL into a temporary directory,
    /// then sends the file URL to that directory.
    private static func untar(archive fileURL: URL) -> SignalProducer<URL, CarthageError> {
        return FileManager.default.reactive.createTemporaryDirectory()
            .flatMap(.merge) { directoryURL in
                return untar(archive: fileURL, to: directoryURL)
                    .then(SignalProducer<URL, CarthageError>(value: directoryURL))
        }
    }

}

extension String {
    fileprivate func removingPrefix(_ prefix: String) -> String {
        if self.hasPrefix(prefix) {
            let startIndex = self.index(self.startIndex, offsetBy: prefix.count)
            return String(self[startIndex..<self.endIndex])
        } else {
            return self
        }
    }

    fileprivate func removingSuffix(_ suffix: String) -> String {
        if self.hasSuffix(suffix) {
            let endIndex = self.index(self.endIndex, offsetBy: -suffix.count)
            return String(self[self.startIndex..<endIndex])
        } else {
            return self
        }
    }
    
    fileprivate func appendingPathComponent(_ component: String) -> String {
        return (self as NSString).appendingPathComponent(component)
    }
    
    fileprivate func appendingPathExtension(_ pathExtension: String) -> String {
        return (self as NSString).appendingPathExtension(pathExtension)!
    }
    
    fileprivate var deletingLastPathComponent: String {
        return (self as NSString).deletingLastPathComponent
    }
    
    fileprivate var lastPathComponent: String {
        return (self as NSString).lastPathComponent
    }
}
