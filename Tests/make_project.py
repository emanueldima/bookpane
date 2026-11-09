"""Regenerate the checked-in Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
def ident(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
objects = []
def obj(key, value):
    objects.append(f'\t\t{ident(key)} = {{ {value} }};')
    return ident(key)
def refs(keys): return '(' + ', '.join(ident(k) for k in keys) + (',' if keys else '') + ')'

sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Bookpane').rglob('*') if p.suffix in ['.swift', '.c'])
headers = []
resources = ['Bookpane/Assets.xcassets', 'Bookpane/ThirdPartyNotices.txt']
tests = ['Tests/EPUBParserTests.swift', 'Tests/FolderAccessTests.swift', 'Tests/ZIPExtractorTests.swift']
samples = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Samples').glob('*.epub')) + ['Tests/Fixtures/ZIP']
for path in sources + headers + resources + tests + samples:
    ext = Path(path).suffix
    kind = {'.swift':'sourcecode.swift', '.c':'sourcecode.c.c', '.h':'sourcecode.c.h', '.xcassets':'folder.assetcatalog', '.epub':'file', '.txt':'text', '':'folder'}[ext]
    obj(path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>";')
    if path not in headers:
        obj('build:'+path, f'isa = PBXBuildFile; fileRef = {ident(path)};')
obj('zip-package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/weichsel/ZIPFoundation.git"; requirement = { kind = exactVersion; version = 0.9.20; };')
obj('zip-product', f'isa = XCSwiftPackageProductDependency; package = {ident("zip-package")}; productName = ZIPFoundation;')
obj('zip-framework', f'isa = PBXBuildFile; productRef = {ident("zip-product")};')
obj('app-product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Bookpane.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = BookpaneTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('app-group', f'isa = PBXGroup; name = Bookpane; children = {refs(sources + headers + resources)}; sourceTree = "<group>";')
obj('test-group', f'isa = PBXGroup; name = Tests; children = {refs(tests+samples)}; sourceTree = "<group>";')
obj('products', f'isa = PBXGroup; name = Products; children = {refs(["app-product", "test-product"])}; sourceTree = "<group>";')
obj('main-group', f'isa = PBXGroup; children = {refs(["app-group", "test-group", "products"])}; sourceTree = "<group>";')
for key, kind, files in [('sources','PBXSourcesBuildPhase',sources), ('resources','PBXResourcesBuildPhase',resources), ('frameworks','PBXFrameworksBuildPhase',[]), ('test-sources','PBXSourcesBuildPhase',tests), ('test-resources','PBXResourcesBuildPhase',samples), ('test-frameworks','PBXFrameworksBuildPhase',[])]:
    obj(key, f'isa = {kind}; buildActionMask = 2147483647; files = {refs(["build:"+p for p in files] + (["zip-framework"] if key == "frameworks" else []))}; runOnlyForDeploymentPostprocessing = 0;')
obj('test-proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ident("app-target")}; remoteInfo = Bookpane;')
obj('test-dependency', f'isa = PBXTargetDependency; target = {ident("app-target")}; targetProxy = {ident("test-proxy")};')
obj('app-target', f'isa = PBXNativeTarget; buildConfigurationList = {ident("app-configs")}; buildPhases = {refs(["sources", "frameworks", "resources"])}; buildRules = (); dependencies = (); packageProductDependencies = {refs(["zip-product"])}; name = Bookpane; productName = Bookpane; productReference = {ident("app-product")}; productType = "com.apple.product-type.application";')
obj('test-target', f'isa = PBXNativeTarget; buildConfigurationList = {ident("test-configs")}; buildPhases = {refs(["test-sources", "test-frameworks", "test-resources"])}; buildRules = (); dependencies = {refs(["test-dependency"])}; name = BookpaneTests; productName = BookpaneTests; productReference = {ident("test-product")}; productType = "com.apple.product-type.bundle.unit-test";')
for kind in ['project','app','test']:
    for config in ['Debug','Release']:
        settings = {}
        if kind == 'project':
            settings = dict(CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', CLANG_WARN_DOCUMENTATION_COMMENTS='YES', GCC_C_LANGUAGE_STANDARD='c11', IPHONEOS_DEPLOYMENT_TARGET='17.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0', SWIFT_STRICT_CONCURRENCY='minimal', DEBUG_INFORMATION_FORMAT='dwarf' if config=='Debug' else 'dwarf-with-dsym', ENABLE_TESTABILITY='YES' if config=='Debug' else 'NO', SWIFT_OPTIMIZATION_LEVEL='-Onone' if config=='Debug' else '-O', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if config=='Debug' else '', GCC_PREPROCESSOR_DEFINITIONS=['DEBUG=1','$(inherited)'] if config=='Debug' else ['$(inherited)'])
        elif kind == 'app':
            settings = dict(PRODUCT_BUNDLE_IDENTIFIER='com.example.Bookpane', PRODUCT_NAME='$(TARGET_NAME)', GENERATE_INFOPLIST_FILE='YES', INFOPLIST_KEY_CFBundleDisplayName='Bookpane', INFOPLIST_KEY_LSApplicationCategoryType='public.app-category.books', INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES', INFOPLIST_KEY_UILaunchScreen_Generation='YES', INFOPLIST_KEY_UISupportedInterfaceOrientations='UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight', TARGETED_DEVICE_FAMILY='1', CODE_SIGN_STYLE='Automatic', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME='AccentColor', CURRENT_PROJECT_VERSION='1', MARKETING_VERSION='1.0', LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'])
        else:
            settings = dict(PRODUCT_BUNDLE_IDENTIFIER='com.example.BookpaneTests', PRODUCT_NAME='$(TARGET_NAME)', GENERATE_INFOPLIST_FILE='YES', TARGETED_DEVICE_FAMILY='1', CODE_SIGN_STYLE='Automatic', TEST_HOST='$(BUILT_PRODUCTS_DIR)/Bookpane.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Bookpane', BUNDLE_LOADER='$(TEST_HOST)', LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks'])
            # BUNDLE_EXECUTABLE_FOLDER_PATH belongs to the test bundle, so use the explicit app executable.
            settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Bookpane.app/Bookpane'
        def val(v): return '('+', '.join(q(x) for x in v)+',)' if isinstance(v,list) else q(v)
        encoded = ' '.join(f'{k} = {val(v)};' for k,v in settings.items())
        obj(kind+'-'+config, f'isa = XCBuildConfiguration; buildSettings = {{ {encoded} }}; name = {config};')
    obj(kind+'-configs', f'isa = XCConfigurationList; buildConfigurations = {refs([kind+"-Debug", kind+"-Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {ident("app-target")} = {{ CreatedOnToolsVersion = 16.0; }}; {ident("test-target")} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {ident("app-target")}; }}; }}; }}; buildConfigurationList = {ident("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {ident("main-group")}; productRefGroup = {ident("products")}; packageReferences = {refs(["zip-package"])}; projectDirPath = ""; projectRoot = ""; targets = {refs(["app-target", "test-target"])};')
(ROOT/'Bookpane.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n'+'\n'.join(objects)+'\n\t};\n\trootObject = '+ident('project')+';\n}\n')
app_id, test_id = ident('app-target'), ident('test-target')
(ROOT/'Bookpane.xcodeproj/xcshareddata/xcschemes/Bookpane.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="Bookpane.app" BlueprintName="Bookpane" ReferencedContainer="container:Bookpane.xcodeproj"/></BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}" BuildableName="BookpaneTests.xctest" BlueprintName="BookpaneTests" ReferencedContainer="container:Bookpane.xcodeproj"/></TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="Bookpane.app" BlueprintName="Bookpane" ReferencedContainer="container:Bookpane.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="Bookpane.app" BlueprintName="Bookpane" ReferencedContainer="container:Bookpane.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f'Generated Xcode project: {len(sources)} app source files, {len(tests)} test source, {len(samples)} sample resources.')
