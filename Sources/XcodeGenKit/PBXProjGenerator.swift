import Foundation
import PathKit
import ProjectSpec
import xcodeproj
import Yams

public class PBXProjGenerator {

    let project: Project

    let pbxProj: PBXProj
    var sourceGenerator: SourceGenerator!

    var targetObjects: [String: PBXTarget] = [:]
    var targetAggregateObjects: [String: PBXAggregateTarget] = [:]
    var targetBuildFiles: [String: PBXBuildFile] = [:]
    var targetFileReferences: [String: PBXObjectReference] = [:]

    var carthageFrameworksByPlatform: [String: Set<PBXObjectReference>] = [:]
    var frameworkFiles: [PBXObjectReference] = []

    var generated = false

    var carthageBuildPath: String {
        return project.options.carthageBuildPath ?? "Carthage/Build"
    }

    public init(project: Project) {
        self.project = project
        pbxProj = PBXProj(objectVersion: 46)
        sourceGenerator = SourceGenerator(project: project) { [unowned self] id, object in
            _ = self.addObject(id: id, object)
        }
    }

    func addObject<T: PBXObject>(id: String, _ object: T) -> T {
//        let reference = pbxProj.objects.generateReference(object, id)
        pbxProj.objects.addObject(object)
        return object
    }

    func createObject<T: PBXObject>(id: String, _ object: T) -> T {
        pbxProj.objects.addObject(object)
        return object
    }

    public func generate() throws -> PBXProj {
        if generated {
            fatalError("Cannot use PBXProjGenerator to generate more than once")
        }
        generated = true

        for group in project.fileGroups {
            try sourceGenerator.getFileGroups(path: group)
        }

        let buildConfigs: [XCBuildConfiguration] = project.configs.map { config in
            let buildSettings = project.getProjectBuildSettings(config: config)
            var baseConfigurationReference: PBXObjectReference?
            if let configPath = project.configFiles[config.name] {
                baseConfigurationReference = sourceGenerator.getContainedFileReference(path: project.basePath + configPath)
            }
            return createObject(
                id: config.name,
                XCBuildConfiguration(
                    name: config.name,
                    baseConfigurationReference: baseConfigurationReference,
                    buildSettings: buildSettings
                )
            )
        }

        let configName = project.options.defaultConfig ?? buildConfigs.first?.name ?? ""
        let buildConfigList = createObject(
            id: project.name,
            XCConfigurationList(
                buildConfigurationsReferences: buildConfigs.map { $0.reference },
                defaultConfigurationName: configName
            )
        )

        var derivedGroups: [PBXGroup] = []

        let mainGroup = createObject(
            id: "Project",
            PBXGroup(
                childrenReferences: [],
                sourceTree: .group,
                usesTabs: project.options.usesTabs,
                indentWidth: project.options.indentWidth,
                tabWidth: project.options.tabWidth
            )
        )

        let pbxProject = createObject(
            id: project.name,
            PBXProject(
                name: project.name,
                buildConfigurationListReference: buildConfigList.reference,
                compatibilityVersion: "Xcode 3.2",
                mainGroupReference: mainGroup.reference,
                developmentRegion: project.options.developmentLanguage ?? "en"
            )
        )

        pbxProj.rootObjectReference = pbxProject.reference

        for target in project.targets {
            let targetObject: PBXTarget

            if target.isLegacy {
                targetObject = PBXLegacyTarget(
                    name: target.name,
                    buildToolPath: target.legacy?.toolPath,
                    buildArgumentsString: target.legacy?.arguments,
                    passBuildSettingsInEnvironment: target.legacy?.passSettings ?? false,
                    buildWorkingDirectory: target.legacy?.workingDirectory
                )
            } else {
                targetObject = PBXNativeTarget(name: target.name)
            }

            targetObjects[target.name] = createObject(id: target.name, targetObject)

            var explicitFileType: String?
            var lastKnownFileType: String?
            let fileType = Xcode.fileType(path: Path(target.filename))
            if target.platform == .macOS || target.platform == .watchOS || target.type == .framework {
                explicitFileType = fileType
            } else {
                lastKnownFileType = fileType
            }

            if !target.isLegacy {
                let fileReference = createObject(
                    id: target.name,
                    PBXFileReference(
                        sourceTree: .buildProductsDir,
                        explicitFileType: explicitFileType,
                        lastKnownFileType: lastKnownFileType,
                        path: target.filename,
                        includeInIndex: false
                    )
                )

                targetFileReferences[target.name] = fileReference.reference
                targetBuildFiles[target.name] = createObject(
                    id: "legacy target build file" + target.name,
                    PBXBuildFile(fileReference: fileReference.reference)
                )
            }
        }

        for target in project.aggregateTargets {

            let aggregateTarget = createObject(
                id: target.name,
                PBXAggregateTarget(
                    name: target.name,
                    productName: target.name
                )
            )
            targetAggregateObjects[target.name] = aggregateTarget
        }

        try project.targets.forEach(generateTarget)
        try project.aggregateTargets.forEach(generateAggregateTarget)

        let productGroup = createObject(
            id: "Products",
            PBXGroup(
                childrenReferences: Array(targetFileReferences.values),
                sourceTree: .group,
                name: "Products"
            )
        )
        derivedGroups.append(productGroup)

        if !carthageFrameworksByPlatform.isEmpty {
            var platforms: [PBXGroup] = []
            var platformReferences: [PBXObjectReference] = []
            for (platform, fileReferences) in carthageFrameworksByPlatform {
                let platformGroup: PBXGroup = createObject(
                    id: "Carthage" + platform,
                    PBXGroup(
                        childrenReferences: fileReferences.sorted(),
                        sourceTree: .group,
                        path: platform
                    )
                )
                platformReferences.append(platformGroup.reference)
                platforms.append(platformGroup)
            }
            let carthageGroup = createObject(
                id: "Carthage",
                PBXGroup(
                    childrenReferences: platformReferences.sorted(),
                    sourceTree: .group,
                    name: "Carthage",
                    path: carthageBuildPath
                )
            )
            frameworkFiles.append(carthageGroup.reference)
        }

        if !frameworkFiles.isEmpty {
            let group = createObject(
                id: "Frameworks",
                PBXGroup(
                    childrenReferences: frameworkFiles,
                    sourceTree: .group,
                    name: "Frameworks"
                )
            )
            derivedGroups.append(group)
        }

        mainGroup.childrenReferences = Array(sourceGenerator.rootGroups)
        sortGroups(group: mainGroup)
        // add derived groups at the end
        derivedGroups.forEach(sortGroups)
        mainGroup.childrenReferences += derivedGroups
            .sorted { $0.nameOrPath.localizedStandardCompare($1.nameOrPath) == .orderedAscending }
            .map { $0.reference }

        let projectAttributes: [String: Any] = ["LastUpgradeCheck": project.xcodeVersion]
            .merged(project.attributes)
            .merged(generateTargetAttributes() ?? [:])

        pbxProject.knownRegions = sourceGenerator.knownRegions.sorted()
        let allTargets: [PBXTarget] = Array(targetObjects.values) + Array(targetAggregateObjects.values)
        pbxProject.targetsReferences = allTargets
            .sorted { $0.name < $1.name }
            .map { $0.reference }
        pbxProject.attributes = projectAttributes

        return pbxProj
    }

    func generateAggregateTarget(_ target: AggregateTarget) throws {

        let aggregateTarget = targetAggregateObjects[target.name]!

        let configs: [XCBuildConfiguration] = project.configs.map { config in

            let buildSettings = project.getBuildSettings(settings: target.settings, config: config)

            var baseConfigurationReference: PBXObjectReference?
            if let configPath = target.configFiles[config.name] {
                baseConfigurationReference = sourceGenerator.getContainedFileReference(path: project.basePath + configPath)
            }
            let buildConfig = XCBuildConfiguration(
                name: config.name,
                baseConfigurationReference: baseConfigurationReference,
                buildSettings: buildSettings
            )
            return createObject(id: config.name + target.name, buildConfig)
        }

        let dependencies: [PBXObjectReference] = target.targets.map { generateTargetDependency(from: target.name, to: $0).reference }

        let buildConfigList = createObject(id: target.name, XCConfigurationList(
            buildConfigurationsReferences: configs.map { $0.reference },
            defaultConfigurationName: ""
        ))

        var buildPhases: [PBXObjectReference] = []
        buildPhases += try target.buildScripts.map { try generateBuildScript(targetName: target.name, buildScript: $0) }

        aggregateTarget.buildPhasesReferences = buildPhases
        aggregateTarget.buildConfigurationListReference = buildConfigList.reference
        aggregateTarget.dependenciesReferences = dependencies
    }

    func generateTargetDependency(from: String, to target: String) -> PBXTargetDependency {
        guard let targetReference = targetObjects[target]?.reference ?? targetAggregateObjects[target]?.reference else {
            fatalError("target not found")
        }
        let targetProxy = createObject(
            id: "\(from)-\(target)",
            PBXContainerItemProxy(
                containerPortalReference: pbxProj.rootObjectReference!,
                remoteGlobalIDReference: targetReference,
                proxyType: .nativeTarget,
                remoteInfo: target
            )
        )

        let targetDependency = createObject(
            id: "\(from)-\(target)",
            PBXTargetDependency(
                targetReference: targetReference,
                targetProxyReference: targetProxy.reference
            )
        )
        return targetDependency
    }

    func generateBuildScript(targetName: String, buildScript: BuildScript) throws -> PBXObjectReference {

        let shellScript: String
        switch buildScript.script {
        case let .path(path):
            shellScript = try (project.basePath + path).read()
        case let .script(script):
            shellScript = script
        }

        let shellScriptPhase = PBXShellScriptBuildPhase(
            fileReferences: [],
            name: buildScript.name ?? "Run Script",
            inputPaths: buildScript.inputFiles,
            outputPaths: buildScript.outputFiles,
            shellPath: buildScript.shell ?? "/bin/sh",
            shellScript: shellScript
        )
        shellScriptPhase.runOnlyForDeploymentPostprocessing = buildScript.runOnlyWhenInstalling
        shellScriptPhase.showEnvVarsInLog = buildScript.showEnvVars
        return createObject(id: String(describing: buildScript.name) + shellScript + targetName, shellScriptPhase).reference
    }

    func generateTargetAttributes() -> [String: Any]? {

        var targetAttributes: [PBXObjectReference: [String: Any]] = [:]

        let uiTestTargets = pbxProj.objects.nativeTargets.values.filter { $0.productType == .uiTestBundle }
        for uiTestTarget in uiTestTargets {

            // look up TEST_TARGET_NAME build setting
            func testTargetName(_ target: PBXTarget) -> String? {
                guard let configurationList = target.buildConfigurationListReference else { return nil }
                guard let buildConfigurationReferences = self.pbxProj.objects.configurationLists[configurationList]?.buildConfigurationsReferences else { return nil }

                let configs = buildConfigurationReferences
                    .compactMap { ref in self.pbxProj.objects.buildConfigurations[ref] }

                return configs
                    .compactMap { $0.buildSettings["TEST_TARGET_NAME"] as? String }
                    .first
            }

            guard let name = testTargetName(uiTestTarget) else { continue }
            guard let target = self.pbxProj.objects.targets(named: name).first else { continue }

            targetAttributes[uiTestTarget.reference, default: [:]].merge(["TestTargetID": target.reference])
        }

        func generateTargetAttributes(_ target: ProjectTarget, targetReference: PBXObjectReference) {
            if !target.attributes.isEmpty {
                targetAttributes[targetReference, default: [:]].merge(target.attributes)
            }

            func getSingleBuildSetting(_ setting: String) -> String? {
                let settings = project.configs.compactMap {
                    project.getCombinedBuildSettings(basePath: project.basePath, target: target, config: $0)[setting] as? String
                }
                guard settings.count == project.configs.count,
                    let firstSetting = settings.first,
                    settings.filter({ $0 == firstSetting }).count == settings.count else {
                    return nil
                }
                return firstSetting
            }

            func setTargetAttribute(attribute: String, buildSetting: String) {
                if let setting = getSingleBuildSetting(buildSetting) {
                    targetAttributes[targetReference, default: [:]].merge([attribute: setting])
                }
            }

            setTargetAttribute(attribute: "ProvisioningStyle", buildSetting: "CODE_SIGN_STYLE")
            setTargetAttribute(attribute: "DevelopmentTeam", buildSetting: "DEVELOPMENT_TEAM")
        }

        for target in project.aggregateTargets {
            guard let targetReference = targetAggregateObjects[target.name]?.reference else {
                continue
            }
            generateTargetAttributes(target, targetReference: targetReference)
        }

        for target in project.targets {
            guard let targetReference = targetObjects[target.name]?.reference else {
                continue
            }
            generateTargetAttributes(target, targetReference: targetReference)
        }

        return targetAttributes.isEmpty ? nil : ["TargetAttributes": targetAttributes]
    }

    func sortGroups(group: PBXGroup) {
        // sort children
        let children = group.childrenReferences
            .compactMap { pbxProj.objects.getFileElement(reference: $0) }
            .sorted { child1, child2 in
                let sortOrder1 = child1.getSortOrder(groupSortPosition: project.options.groupSortPosition)
                let sortOrder2 = child2.getSortOrder(groupSortPosition: project.options.groupSortPosition)

                if sortOrder1 == sortOrder2 {
                    return child1.nameOrPath.localizedStandardCompare(child2.nameOrPath) == .orderedAscending
                } else {
                    return sortOrder1 < sortOrder2
                }
            }
        group.childrenReferences = children.map { $0.reference }.filter { $0 != group.reference }

        // sort sub groups
        let childGroups = group.childrenReferences.compactMap { pbxProj.objects.groups[$0] }
        childGroups.forEach(sortGroups)
    }

    func generateTarget(_ target: Target) throws {

        sourceGenerator.targetName = target.name
        let carthageDependencies = getAllCarthageDependencies(target: target)

        let sourceFiles = try sourceGenerator.getAllSourceFiles(targetType: target.type, sources: target.sources)

        var plistPath: Path?
        var searchForPlist = true
        var anyDependencyRequiresObjCLinking = false

        var dependencies: [PBXObjectReference] = []
        var targetFrameworkBuildFiles: [PBXObjectReference] = []
        var frameworkBuildPaths = Set<String>()
        var copyFilesBuildPhasesFiles: [TargetSource.BuildPhase.CopyFilesSettings: [PBXObjectReference]] = [:]
        var copyFrameworksReferences: [PBXObjectReference] = []
        var copyResourcesReferences: [PBXObjectReference] = []
        var copyWatchReferences: [PBXObjectReference] = []
        var extensions: [PBXObjectReference] = []
        var carthageFrameworksToEmbed: [String] = []

        let targetDependencies = (target.transitivelyLinkDependencies ?? project.options.transitivelyLinkDependencies) ?
            getAllDependenciesPlusTransitiveNeedingEmbedding(target: target) : target.dependencies

        let directlyEmbedCarthage = target.directlyEmbedCarthageDependencies ?? !(target.platform.requiresSimulatorStripping && target.type.isApp)

        func getEmbedSettings(dependency: Dependency, codeSign: Bool) -> [String: Any] {
            var embedAttributes: [String] = []
            if codeSign {
                embedAttributes.append("CodeSignOnCopy")
            }
            if dependency.removeHeaders {
                embedAttributes.append("RemoveHeadersOnCopy")
            }
            return ["ATTRIBUTES": embedAttributes]
        }

        for dependency in targetDependencies {

            let embed = dependency.embed ?? target.shouldEmbedDependencies

            switch dependency.type {
            case .target:
                let dependencyTargetName = dependency.reference
                let targetDependency = generateTargetDependency(from: target.name, to: dependencyTargetName)
                dependencies.append(targetDependency.reference)

                guard let dependencyTarget = project.getTarget(dependencyTargetName) else { continue }

                let dependencyFileReference = targetFileReferences[dependencyTargetName]!

                let dependecyLinkage = dependencyTarget.defaultLinkage
                let link = dependency.link ?? (
                    (dependecyLinkage == .dynamic && target.type != .staticLibrary)
                        || (dependecyLinkage == .static && target.type.isExecutable)
                )
                if link {
                    let dependencyBuildFileReference = targetBuildFiles[dependencyTargetName]!.fileReference!
                    let buildFile = createObject(
                        id: "target dependency build file" + target.name,
                        PBXBuildFile(fileReference: dependencyBuildFileReference)
                    )
                    targetFrameworkBuildFiles.append(buildFile.reference)

                    if !anyDependencyRequiresObjCLinking
                        && dependencyTarget.requiresObjCLinking ?? (dependencyTarget.type == .staticLibrary) {
                        anyDependencyRequiresObjCLinking = true
                    }
                }

                let embed = dependency.embed ?? (!dependencyTarget.type.isLibrary && (
                    target.type.isApp
                        || (target.type.isTest && (dependencyTarget.type.isFramework || dependencyTarget.type == .bundle))
                ))
                if embed {
                    let embedFile = createObject(
                        id: "target dependency embed build file" + target.name,
                        PBXBuildFile(
                            fileReference: dependencyFileReference,
                            settings: getEmbedSettings(dependency: dependency, codeSign: dependency.codeSign ?? !dependencyTarget.type.isExecutable)
                        )
                    )

                    if dependencyTarget.type.isExtension {
                        // embed app extension
                        extensions.append(embedFile.reference)
                    } else if dependencyTarget.type.isFramework {
                        copyFrameworksReferences.append(embedFile.reference)
                    } else if dependencyTarget.type.isApp && dependencyTarget.platform == .watchOS {
                        copyWatchReferences.append(embedFile.reference)
                    } else if dependencyTarget.type == .xpcService {
                        copyFilesBuildPhasesFiles[.xpcServices, default: []].append(embedFile.reference)
                    } else {
                        copyResourcesReferences.append(embedFile.reference)
                    }
                }

            case .framework:
                guard target.type != .staticLibrary else { break }

                let fileReference: PBXObjectReference
                if dependency.implicit {
                    fileReference = sourceGenerator.getFileReference(
                        path: Path(dependency.reference),
                        inPath: project.basePath,
                        sourceTree: .buildProductsDir
                    )
                } else {
                    fileReference = sourceGenerator.getFileReference(
                        path: Path(dependency.reference),
                        inPath: project.basePath
                    )
                }

                let buildFile = createObject(
                    id: "framework file reference" + target.name,
                    PBXBuildFile(fileReference: fileReference)
                )

                targetFrameworkBuildFiles.append(buildFile.reference)
                if !frameworkFiles.contains(fileReference) {
                    frameworkFiles.append(fileReference)
                }

                if embed {
                    let embedFile = createObject(
                        id: "framework embed file" + target.name,
                        PBXBuildFile(fileReference: fileReference, settings: getEmbedSettings(dependency: dependency, codeSign: dependency.codeSign ?? true))
                    )
                    copyFrameworksReferences.append(embedFile.reference)
                }

                let buildPath = Path(dependency.reference).parent().string.quoted
                frameworkBuildPaths.insert(buildPath)

            case .carthage:
                guard target.type != .staticLibrary else { break }

                var platformPath = Path(getCarthageBuildPath(platform: target.platform))
                var frameworkPath = platformPath + dependency.reference
                if frameworkPath.extension == nil {
                    frameworkPath = Path(frameworkPath.string + ".framework")
                }
                let fileReference = sourceGenerator.getFileReference(path: frameworkPath, inPath: platformPath)

                let buildFile = createObject(
                    id: "carthage dependency build file" + target.name,
                    PBXBuildFile(fileReference: fileReference)
                )

                carthageFrameworksByPlatform[target.platform.carthageDirectoryName, default: []].insert(fileReference)

                targetFrameworkBuildFiles.append(buildFile.reference)

                // Embedding handled by iterating over `carthageDependencies` below
            }
        }

        for dependency in carthageDependencies {
            guard target.type != .staticLibrary else { break }

            let embed = dependency.embed ?? target.shouldEmbedDependencies

            var platformPath = Path(getCarthageBuildPath(platform: target.platform))
            var frameworkPath = platformPath + dependency.reference
            if frameworkPath.extension == nil {
                frameworkPath = Path(frameworkPath.string + ".framework")
            }
            let fileReference = sourceGenerator.getFileReference(path: frameworkPath, inPath: platformPath)

            if embed {
                if directlyEmbedCarthage {
                    let embedFile = createObject(
                        id: "carthage embed" + target.name,
                        PBXBuildFile(fileReference: fileReference, settings: getEmbedSettings(dependency: dependency, codeSign: dependency.codeSign ?? true))
                    )
                    copyFrameworksReferences.append(embedFile.reference)
                } else {
                    carthageFrameworksToEmbed.append(dependency.reference)
                }
            }
        }

        let fileReference = targetFileReferences[target.name]
        var buildPhases: [PBXObjectReference] = []

        func getBuildFilesForSourceFiles(_ sourceFiles: [SourceFile]) -> [PBXObjectReference] {
            let files = sourceFiles
                .reduce(into: [SourceFile]()) { output, sourceFile in
                    if !output.contains(where: { $0.fileReference == sourceFile.fileReference }) {
                        output.append(sourceFile)
                    }
                }
                .sorted { $0.path.lastComponent < $1.path.lastComponent }
            return files.map { createObject(id: $0.path.string + target.name, $0.buildFile) }
                .map { $0.reference }
        }

        func getBuildFilesForPhase(_ buildPhase: BuildPhase) -> [PBXObjectReference] {
            let filteredSourceFiles = sourceFiles
                .filter { $0.buildPhase?.buildPhase == buildPhase }
            return getBuildFilesForSourceFiles(filteredSourceFiles)
        }

        func getBuildFilesForCopyFilesPhases() -> [TargetSource.BuildPhase.CopyFilesSettings: [PBXObjectReference]] {
            var sourceFilesByCopyFiles: [TargetSource.BuildPhase.CopyFilesSettings: [SourceFile]] = [:]
            for sourceFile in sourceFiles {
                guard case let .copyFiles(copyFilesSettings)? = sourceFile.buildPhase else { continue }
                sourceFilesByCopyFiles[copyFilesSettings, default: []].append(sourceFile)
            }
            return sourceFilesByCopyFiles.mapValues { getBuildFilesForSourceFiles($0) }
        }

        buildPhases += try target.prebuildScripts.map { try generateBuildScript(targetName: target.name, buildScript: $0) }

        let sourcesBuildPhaseFiles = getBuildFilesForPhase(.sources)
        let sourcesBuildPhase = createObject(id: target.name, PBXSourcesBuildPhase(fileReferences: sourcesBuildPhaseFiles))
        buildPhases.append(sourcesBuildPhase.reference)

        let resourcesBuildPhaseFiles = getBuildFilesForPhase(.resources) + copyResourcesReferences
        if !resourcesBuildPhaseFiles.isEmpty {
            let resourcesBuildPhase = createObject(id: target.name, PBXResourcesBuildPhase(fileReferences: resourcesBuildPhaseFiles))
            buildPhases.append(resourcesBuildPhase.reference)
        }

        let buildSettings = project.getCombinedBuildSettings(basePath: project.basePath, target: target, config: project.configs[0])
        let swiftObjCInterfaceHeader = buildSettings["SWIFT_OBJC_INTERFACE_HEADER_NAME"] as? String

        if target.type == .staticLibrary
            && swiftObjCInterfaceHeader != ""
            && sourceFiles.contains(where: { $0.buildPhase == .sources && $0.path.extension == "swift" }) {

            let inputPaths = ["$(DERIVED_SOURCES_DIR)/$(SWIFT_OBJC_INTERFACE_HEADER_NAME)"]
            let outputPaths = ["$(BUILT_PRODUCTS_DIR)/include/$(PRODUCT_MODULE_NAME)/$(SWIFT_OBJC_INTERFACE_HEADER_NAME)"]
            let script = createObject(
                id: "Swift.h" + target.name,
                PBXShellScriptBuildPhase(
                    fileReferences: [],
                    name: "Copy Swift Objective-C Interface Header",
                    inputPaths: inputPaths,
                    outputPaths: outputPaths,
                    shellPath: "/bin/sh",
                    shellScript: "ditto \"${SCRIPT_INPUT_FILE_0}\" \"${SCRIPT_OUTPUT_FILE_0}\"\n"
                )
            )
            buildPhases.append(script.reference)
        }

        copyFilesBuildPhasesFiles.merge(getBuildFilesForCopyFilesPhases()) { $0 + $1 }
        if !copyFilesBuildPhasesFiles.isEmpty {
            for (copyFiles, buildPhaseFiles) in copyFilesBuildPhasesFiles {
                let copyFilesBuildPhase = createObject(
                    id: "copy files" + copyFiles.destination.rawValue + copyFiles.subpath + target.name,
                    PBXCopyFilesBuildPhase(
                        dstPath: copyFiles.subpath,
                        dstSubfolderSpec: copyFiles.destination.destination,
                        fileReferences: buildPhaseFiles
                    )
                )

                buildPhases.append(copyFilesBuildPhase.reference)
            }
        }

        let headersBuildPhaseFiles = getBuildFilesForPhase(.headers)
        if !headersBuildPhaseFiles.isEmpty && (target.type == .framework || target.type == .dynamicLibrary) {
            let headersBuildPhase = createObject(id: target.name, PBXHeadersBuildPhase(fileReferences: headersBuildPhaseFiles))
            buildPhases.append(headersBuildPhase.reference)
        }

        if !targetFrameworkBuildFiles.isEmpty {

            let frameworkBuildPhase = createObject(
                id: target.name,
                PBXFrameworksBuildPhase(fileReferences: targetFrameworkBuildFiles)
            )
            buildPhases.append(frameworkBuildPhase.reference)
        }

        if !extensions.isEmpty {

            let copyFilesPhase = createObject(
                id: "embed app extensions" + target.name,
                PBXCopyFilesBuildPhase(
                    dstPath: "",
                    dstSubfolderSpec: .plugins,
                    name: "Embed App Extensions",
                    fileReferences: extensions
                )
            )

            buildPhases.append(copyFilesPhase.reference)
        }

        copyFrameworksReferences += getBuildFilesForPhase(.frameworks)
        if !copyFrameworksReferences.isEmpty {

            let copyFilesPhase = createObject(
                id: "embed frameworks" + target.name,
                PBXCopyFilesBuildPhase(
                    dstPath: "",
                    dstSubfolderSpec: .frameworks,
                    name: "Embed Frameworks",
                    fileReferences: copyFrameworksReferences
                )
            )

            buildPhases.append(copyFilesPhase.reference)
        }

        if !copyWatchReferences.isEmpty {

            let copyFilesPhase = createObject(
                id: "embed watch content" + target.name,
                PBXCopyFilesBuildPhase(
                    dstPath: "$(CONTENTS_FOLDER_PATH)/Watch",
                    dstSubfolderSpec: .productsDirectory,
                    name: "Embed Watch Content",
                    fileReferences: copyWatchReferences
                )
            )

            buildPhases.append(copyFilesPhase.reference)
        }

        if !carthageFrameworksToEmbed.isEmpty {

            let inputPaths = carthageFrameworksToEmbed
                .map { "$(SRCROOT)/\(carthageBuildPath)/\(target.platform)/\($0)\($0.contains(".") ? "" : ".framework")" }
            let outputPaths = carthageFrameworksToEmbed
                .map { "$(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/\($0)\($0.contains(".") ? "" : ".framework")" }
            let carthageExecutable = project.options.carthageExecutablePath ?? "carthage"
            let carthageScript = createObject(
                id: "Carthage" + target.name,
                PBXShellScriptBuildPhase(
                    fileReferences: [],
                    name: "Carthage",
                    inputPaths: inputPaths,
                    outputPaths: outputPaths,
                    shellPath: "/bin/sh",
                    shellScript: "\(carthageExecutable) copy-frameworks\n"
                )
            )
            buildPhases.append(carthageScript.reference)
        }

        let buildRules = target.buildRules.map { buildRule in
            createObject(
                id: "\(target.name)-\(buildRule.action)-\(buildRule.fileType)",
                PBXBuildRule(
                    compilerSpec: buildRule.action.compilerSpec,
                    fileType: buildRule.fileType.fileType,
                    isEditable: true,
                    filePatterns: buildRule.fileType.pattern,
                    name: buildRule.name ?? "Build Rule",
                    outputFiles: buildRule.outputFiles,
                    outputFilesCompilerFlags: buildRule.outputFilesCompilerFlags,
                    script: buildRule.action.script
                )
            ).reference
        }

        buildPhases += try target.postbuildScripts.map { try generateBuildScript(targetName: target.name, buildScript: $0) }

        let configs: [XCBuildConfiguration] = project.configs.map { config in
            var buildSettings = project.getTargetBuildSettings(target: target, config: config)

            // automatically set INFOPLIST_FILE path
            if !project.targetHasBuildSetting("INFOPLIST_FILE", basePath: project.basePath, target: target, config: config) {
                if searchForPlist {
                    plistPath = getInfoPlist(target.sources)
                    searchForPlist = false
                }
                if let plistPath = plistPath {
                    buildSettings["INFOPLIST_FILE"] = plistPath.byRemovingBase(path: project.basePath)
                }
            }

            // automatically calculate bundle id
            if let bundleIdPrefix = project.options.bundleIdPrefix,
                !project.targetHasBuildSetting("PRODUCT_BUNDLE_IDENTIFIER", basePath: project.basePath, target: target, config: config) {
                let characterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-.")).inverted
                let escapedTargetName = target.name
                    .replacingOccurrences(of: "_", with: "-")
                    .components(separatedBy: characterSet)
                    .joined(separator: "")
                buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] = bundleIdPrefix + "." + escapedTargetName
            }

            // automatically set test target name
            if target.type == .uiTestBundle,
                !project.targetHasBuildSetting("TEST_TARGET_NAME", basePath: project.basePath, target: target, config: config) {
                for dependency in target.dependencies {
                    if dependency.type == .target,
                        let dependencyTarget = project.getTarget(dependency.reference),
                        dependencyTarget.type == .application {
                        buildSettings["TEST_TARGET_NAME"] = dependencyTarget.name
                        break
                    }
                }
            }

            // objc linkage
            if anyDependencyRequiresObjCLinking {
                let otherLinkingFlags = "OTHER_LDFLAGS"
                let objCLinking = "-ObjC"
                if var array = buildSettings[otherLinkingFlags] as? [String] {
                    array.append(objCLinking)
                    buildSettings[otherLinkingFlags] = array
                } else if let string = buildSettings[otherLinkingFlags] as? String {
                    buildSettings[otherLinkingFlags] = [string, objCLinking]
                } else {
                    buildSettings[otherLinkingFlags] = ["$(inherited)", objCLinking]
                }
            }

            // set Carthage search paths
            let configFrameworkBuildPaths: [String]
            if !carthageDependencies.isEmpty {
                let carthagePlatformBuildPath = "$(PROJECT_DIR)/" + getCarthageBuildPath(platform: target.platform)
                configFrameworkBuildPaths = [carthagePlatformBuildPath] + Array(frameworkBuildPaths).sorted()
            } else {
                configFrameworkBuildPaths = Array(frameworkBuildPaths).sorted()
            }

            // set framework search paths
            if !configFrameworkBuildPaths.isEmpty {
                let frameworkSearchPaths = "FRAMEWORK_SEARCH_PATHS"
                if var array = buildSettings[frameworkSearchPaths] as? [String] {
                    array.append(contentsOf: configFrameworkBuildPaths)
                    buildSettings[frameworkSearchPaths] = array
                } else if let string = buildSettings[frameworkSearchPaths] as? String {
                    buildSettings[frameworkSearchPaths] = [string] + configFrameworkBuildPaths
                } else {
                    buildSettings[frameworkSearchPaths] = ["$(inherited)"] + configFrameworkBuildPaths
                }
            }

            var baseConfigurationReference: PBXObjectReference?
            if let configPath = target.configFiles[config.name] {
                baseConfigurationReference = sourceGenerator.getContainedFileReference(path: project.basePath + configPath)
            }
            let buildConfig = XCBuildConfiguration(
                name: config.name,
                baseConfigurationReference: baseConfigurationReference,
                buildSettings: buildSettings
            )
            return createObject(id: config.name + target.name, buildConfig)
        }

        let buildConfigList = createObject(id: target.name, XCConfigurationList(
            buildConfigurationsReferences: configs.map { $0.reference },
            defaultConfigurationName: ""
        ))

        let targetObject = targetObjects[target.name]!

        targetObject.name = target.name
        targetObject.buildConfigurationListReference = buildConfigList.reference
        targetObject.buildPhasesReferences = buildPhases
        targetObject.dependenciesReferences = dependencies
        targetObject.productName = target.name
        targetObject.buildRulesReferences = buildRules
        targetObject.productReference = fileReference
        if !target.isLegacy {
            targetObject.productType = target.type
        }
    }

    func getInfoPlist(_ sources: [TargetSource]) -> Path? {
        return sources
            .lazy
            .map { self.project.basePath + $0.path }
            .flatMap { (path) -> Path? in
                if path.isFile {
                    return path.lastComponent == "Info.plist" ? path : nil
                } else {
                    return path.first(where: { $0.lastComponent == "Info.plist" })
                }
            }
            .first
    }

    func getCarthageBuildPath(platform: Platform) -> String {

        let carthagePath = Path(carthageBuildPath)
        let platformName = platform.carthageDirectoryName
        return "\(carthagePath)/\(platformName)"
    }

    func getAllCarthageDependencies(target topLevelTarget: Target) -> [Dependency] {
        // this is used to resolve cyclical target dependencies
        var visitedTargets: Set<String> = []
        var frameworks: [String: Dependency] = [:]

        var queue: [ProjectTarget] = [topLevelTarget]
        while !queue.isEmpty {
            let projectTarget = queue.removeFirst()
            if visitedTargets.contains(projectTarget.name) {
                continue
            }
            
            if let target = projectTarget as? Target {
                for dependency in target.dependencies {
                    // don't overwrite frameworks, to allow top level ones to rule
                    if frameworks[dependency.reference] != nil {
                        continue
                    }
                    
                    switch dependency.type {
                    case .carthage:
                        frameworks[dependency.reference] = dependency
                    case .target:
                        if let projectTarget = project.getProjectTarget(dependency.reference) {
                            queue.append(projectTarget)
                        }
                    default:
                        break
                    }
                }
            } else if let aggregateTarget = projectTarget as? AggregateTarget {
                for dependencyName in aggregateTarget.targets {
                    if let projectTarget = project.getProjectTarget(dependencyName) {
                        queue.append(projectTarget)
                    }
                }
            }

            visitedTargets.update(with: projectTarget.name)
        }

        return frameworks.sorted(by: { $0.key < $1.key }).map { $0.value }
    }

    func getAllDependenciesPlusTransitiveNeedingEmbedding(target topLevelTarget: Target) -> [Dependency] {
        // this is used to resolve cyclical target dependencies
        var visitedTargets: Set<String> = []
        var dependencies: [String: Dependency] = [:]
        var queue: [Target] = [topLevelTarget]
        while !queue.isEmpty {
            let target = queue.removeFirst()
            if visitedTargets.contains(target.name) {
                continue
            }

            let isTopLevel = target == topLevelTarget

            for dependency in target.dependencies {
                // don't overwrite dependencies, to allow top level ones to rule
                if dependencies[dependency.reference] != nil {
                    continue
                }

                // don't want a dependency if it's going to be embedded or statically linked in a non-top level target
                // in .target check we filter out targets that will embed all of their dependencies
                switch dependency.type {
                case .framework, .carthage:
                    if isTopLevel || dependency.embed == nil {
                        dependencies[dependency.reference] = dependency
                    }
                case .target:
                    if isTopLevel || dependency.embed == nil {
                        if let dependencyTarget = project.getTarget(dependency.reference) {
                            dependencies[dependency.reference] = dependency
                            if !dependencyTarget.shouldEmbedDependencies {
                                // traverse target's dependencies if it doesn't embed them itself
                                queue.append(dependencyTarget)
                            }
                        } else if project.getAggregateTarget(dependency.reference) != nil {
                            // Aggregate targets should be included
                            dependencies[dependency.reference] = dependency
                        }
                    }
                }
            }

            visitedTargets.update(with: target.name)
        }

        return dependencies.sorted(by: { $0.key < $1.key }).map { $0.value }
    }
}

extension Target {

    var shouldEmbedDependencies: Bool {
        return type.isApp || type.isTest
    }
}

extension Platform {
    /// - returns: `true` for platforms that the app store requires simulator slices to be stripped.
    public var requiresSimulatorStripping: Bool {
        switch self {
        case .iOS, .tvOS, .watchOS:
            return true
        case .macOS:
            return false
        }
    }
}

extension PBXFileElement {

    public func getSortOrder(groupSortPosition: SpecOptions.GroupSortPosition) -> Int {
        if type(of: self).isa == "PBXGroup" {
            switch groupSortPosition {
            case .top: return -1
            case .bottom: return 1
            case .none: return 0
            }
        } else {
            return 0
        }
    }
}
