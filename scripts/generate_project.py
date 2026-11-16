#!/usr/bin/env python3
"""Generate a dependency-free, checked-in Xcode project. Python 3 standard library only."""
from pathlib import Path
from hashlib import sha1
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def ident(key): return sha1(key.encode()).hexdigest()[:24].upper()
def add(key, isa, **values):
    uid = ident(key); objects[uid] = dict(isa=isa, **values); return uid
def q(value): return json.dumps(str(value))
def encode(value):
    if isinstance(value, dict): return '{ ' + ' '.join(f'{k} = {encode(v)};' for k,v in value.items()) + ' }'
    if isinstance(value, list): return '( ' + ', '.join(encode(v) for v in value) + ', )' if value else '( )'
    return q(value)

app = 'LittleMoments'; tests = 'LittleMomentsTests'; ui = 'LittleMomentsUITests'
products = []
target_ids = {name: ident('target:'+name) for name in [app, tests, ui]}
groups = []
configs = []
base = dict(IPHONEOS_DEPLOYMENT_TARGET='17.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0',
    CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', GCC_C_LANGUAGE_STANDARD='gnu17',
    SWIFT_STRICT_CONCURRENCY='minimal', ENABLE_USER_SCRIPT_SANDBOXING='YES')
for configuration in ['Debug','Release']:
    settings = dict(base, SWIFT_OPTIMIZATION_LEVEL='-Onone' if configuration=='Debug' else '-O',
        DEBUG_INFORMATION_FORMAT='dwarf' if configuration=='Debug' else 'dwarf-with-dsym',
        ENABLE_TESTABILITY='YES' if configuration=='Debug' else 'NO',
        ONLY_ACTIVE_ARCH='YES' if configuration=='Debug' else 'NO',
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if configuration=='Debug' else '',
        GCC_PREPROCESSOR_DEFINITIONS=['DEBUG=1','$(inherited)'] if configuration=='Debug' else ['$(inherited)'])
    configs.append(add('project:'+configuration, 'XCBuildConfiguration', name=configuration, buildSettings=settings))
project_config = add('project:configs','XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
for name in [app,tests,ui]:
    files=[]; sources=[]; resources=[]
    for path in sorted((ROOT/name).rglob('*')):
        if not path.is_file(): continue
        rel=str(path.relative_to(ROOT))
        if path.suffix=='.swift': kind='sourcecode.swift'
        elif path.suffix=='.plist' or path.suffix=='.xcprivacy': kind='text.plist.xml'
        else: continue
        file=add('file:'+rel,'PBXFileReference',lastKnownFileType=kind,path=rel,sourceTree='SOURCE_ROOT'); files.append(file)
        if path.suffix=='.swift': sources.append(add('build:'+rel,'PBXBuildFile',fileRef=file))
        elif path.suffix=='.xcprivacy': resources.append(add('build:'+rel,'PBXBuildFile',fileRef=file))
    if name==app:
        file=add('file:assets','PBXFileReference',lastKnownFileType='folder.assetcatalog',path='LittleMoments/Resources/Assets.xcassets',sourceTree='SOURCE_ROOT');files.append(file)
        resources.append(add('build:assets','PBXBuildFile',fileRef=file))
    groups.append(add('group:'+name,'PBXGroup',children=files,name=name,sourceTree='<group>'))
    suffix='.app' if name==app else '.xctest'
    product=add('product:'+name,'PBXFileReference',explicitFileType='wrapper.application' if name==app else 'wrapper.cfbundle',includeInIndex='0',path=name+suffix,sourceTree='BUILT_PRODUCTS_DIR');products.append(product)
    phases=[add('sources:'+name,'PBXSourcesBuildPhase',buildActionMask='2147483647',files=sources,runOnlyForDeploymentPostprocessing='0'),add('frameworks:'+name,'PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[],runOnlyForDeploymentPostprocessing='0'),add('resources:'+name,'PBXResourcesBuildPhase',buildActionMask='2147483647',files=resources,runOnlyForDeploymentPostprocessing='0')]
    settings=dict(PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='org.littlemoments.'+name,
        TARGETED_DEVICE_FAMILY='1',CODE_SIGN_STYLE='Automatic',CURRENT_PROJECT_VERSION='1',MARKETING_VERSION='1.0',
        GENERATE_INFOPLIST_FILE='NO' if name==app else 'YES',SUPPORTED_PLATFORMS='iphoneos iphonesimulator')
    if name==app: settings.update(INFOPLIST_FILE='LittleMoments/Resources/Info.plist',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon')
    elif name==tests: settings.update(TEST_HOST='$(BUILT_PRODUCTS_DIR)/LittleMoments.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/LittleMoments',BUNDLE_LOADER='$(TEST_HOST)')
    else: settings.update(TEST_TARGET_NAME=app)
    target_configs=[add(name+':'+c,'XCBuildConfiguration',name=c,buildSettings=settings) for c in ['Debug','Release']]
    config=add(name+':configs','XCConfigurationList',buildConfigurations=target_configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
    deps=[]
    if name!=app:
        proxy=add('proxy:'+name,'PBXContainerItemProxy',containerPortal=ident('project'),proxyType='1',remoteGlobalIDString=target_ids[app],remoteInfo=app)
        deps=[add('dep:'+name,'PBXTargetDependency',target=target_ids[app],targetProxy=proxy)]
    add('target:'+name,'PBXNativeTarget',buildConfigurationList=config,buildPhases=phases,buildRules=[],dependencies=deps,name=name,productName=name,productReference=product,productType='com.apple.product-type.application' if name==app else ('com.apple.product-type.bundle.unit-test' if name==tests else 'com.apple.product-type.bundle.ui-testing'))
product_group=add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
main=add('main','PBXGroup',children=groups+[product_group],sourceTree='<group>')
project=add('project','PBXProject',attributes=dict(BuildIndependentTargetsInParallel='YES',LastUpgradeCheck='1600',TargetAttributes={target_ids[n]:dict(CreatedOnToolsVersion='16.0') for n in [app,tests,ui]}),buildConfigurationList=project_config,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=main,productRefGroup=product_group,projectDirPath='',projectRoot='',targets=list(target_ids.values()))
projectdir=ROOT/'LittleMoments.xcodeproj';projectdir.mkdir(exist_ok=True)
(projectdir/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project))+'\n')
scheme_dir=projectdir/'xcshareddata/xcschemes';scheme_dir.mkdir(parents=True,exist_ok=True)
def ref(n):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[n]}" BuildableName="{n}{".app" if n==app else ".xctest"}" BlueprintName="{n}" ReferencedContainer="container:LittleMoments.xcodeproj"/>'
(scheme_dir/'LittleMoments.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app)}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(tests)}</TestableReference><TestableReference skipped="NO">{ref(ui)}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app)}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app)}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated {projectdir.name} with {len(objects)} objects')
