// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/messages/codes.dart'
    show LocatedMessage, Message;
import 'package:_js_interop_checks/js_interop_checks.dart'
    show JsInteropChecks, JsInteropDiagnosticReporter;
import 'package:_js_interop_checks/src/js_interop.dart' as jsInteropHelper
    show calculateTransitiveImportsOfJsInteropIfUsed;
import 'package:_js_interop_checks/src/transformations/js_util_optimizer.dart'
    show JsUtilOptimizer;
import 'package:_js_interop_checks/src/transformations/shared_interop_transformer.dart'
    show SharedInteropTransformer;
import 'package:_js_interop_checks/src/transformations/static_interop_class_eraser.dart'
    show StaticInteropClassEraser;
import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/clone.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/reference_from_index.dart';
import 'package:kernel/target/changed_structure_notifier.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/type_environment.dart';

import '../../transformations/monomorphize.dart' as monomorphize;
import '../transformations/call_site_annotator.dart' as callSiteAnnotator;
import '../transformations/deeply_immutable.dart' as deeply_immutable;
import '../transformations/lowering.dart'
    as lowering
    show transformLibraries, transformProcedure;
import '../transformations/mixin_full_resolution.dart'
    as transformMixins
    show transformLibraries;
import '../transformations/ffi/common.dart'
    as ffiHelper
    show calculateTransitiveImportsOfDartFfiIfUsed;
import '../transformations/ffi/definitions.dart'
    as transformFfiDefinitions
    show transformLibraries;
import '../transformations/ffi/native.dart'
    as transformFfiNative
    show transformLibraries;
import '../transformations/ffi/use_sites.dart'
    as transformFfiUseSites
    show transformLibraries, transformProcedure;

class VmTarget extends Target {
  final TargetFlags flags;

  Class? _growableList;
  Class? _immutableList;
  Class? _constMap;
  Class? _constSet;
  Class? _map;
  Class? _set;
  Class? _record;
  Class? _oneByteString;
  Class? _twoByteString;
  Class? _smi;
  Class? _double; // _Double, not double.
  Class? _closure;
  Class? _syncStarIterable;

  // Cache for getNativeClasses; invalidated implicitly between modular passes.
  Map<String, Class>? _nativeClasses;

  VmTarget(this.flags);

  @override
  bool get enableNoSuchMethodForwarders => true;

  @override
  bool get supportsSetLiterals => false;

  @override
  bool get supportsFileUriExpression => true;

  @override
  int get enabledLateLowerings => LateLowering.none;

  @override
  bool get supportsLateLoweringSentinel => false;

  @override
  bool get useStaticFieldLowering => false;

  @override
  bool get supportsExplicitGetterCalls => true;

  @override
  int get enabledConstructorTearOffLowerings =>
      ConstructorTearOffLowering.typedefs;

  @override
  String get name => 'vm';

  // This is the order that bootstrap libraries are loaded according to
  // `runtime/vm/object_store.h`.
  @override
  List<String> get extraRequiredLibraries => const <String>[
    'dart:async',
    'dart:collection',
    'dart:_compact_hash',
    'dart:concurrent',
    'dart:convert',
    'dart:developer',
    'dart:ffi',
    'dart:_internal',
    'dart:isolate',
    'dart:math',

    // The library dart:mirrors may be ignored by the VM, e.g. when built in
    // PRODUCT mode.
    'dart:mirrors',

    'dart:typed_data',
    'dart:_vm',
    'dart:vmservice_io',
    'dart:_vmservice',
    'dart:_builtin',
    'dart:nativewrappers',
    'dart:io',
    'dart:cli',

    // Dart Live (VM-on-Wasm) embedder libraries for direct JS interop.
    'dart:_js_helper',
    'dart:_js_types',
    'dart:js_interop',
    'dart:js_interop_unsafe',
    'dart:js_util',
    'dart:_foreign_helper',
  ];

  @override
  bool mayDefineRestrictedType(Uri uri) => uri.isScheme('dart');

  @override
  List<String> get extraRequiredLibrariesPlatform => const <String>[];

  void _patchVmConstants(CoreTypes coreTypes) {
    // Fix Endian.host to be a const field equal to Endian.little instead of
    // a final field. VM does not support big-endian architectures at the
    // moment.
    // Can't use normal patching process for this because CFE does not
    // support patching fields.
    // See http://dartbug.com/32836 for the background.
    final Field host = coreTypes.index.getField(
      'dart:typed_data',
      'Endian',
      'host',
    );
    final Field little = coreTypes.index.getField(
      'dart:typed_data',
      'Endian',
      'little',
    );
    host.isConst = true;
    host.initializer = new CloneVisitorNotMembers().clone(little.initializer!)
      ..parent = host;
  }

  @override
  void performPreConstantEvaluationTransformations(
    Component component,
    CoreTypes coreTypes,
    List<Library> libraries,
    DiagnosticReporter diagnosticReporter, {
    void Function(String msg)? logger,
    ChangedStructureNotifier? changedStructureNotifier,
  }) {
    super.performPreConstantEvaluationTransformations(
      component,
      coreTypes,
      libraries,
      diagnosticReporter,
      logger: logger,
      changedStructureNotifier: changedStructureNotifier,
    );
    _patchVmConstants(coreTypes);
  }

  @override
  List<String> get extraIndexedLibraries => const <String>[
    "dart:_compact_hash",
    "dart:collection",
    // TODO(askesc): This is for the VM host endian optimization, which
    // could possibly be done more cleanly after the VM no longer supports
    // doing constant evaluation on its own. See http://dartbug.com/32836
    "dart:typed_data",
    // Phase 3 of Dart-Live `package:web` support: the JS-interop transformer
    // (run from `performModularTransformationsOnLibraries`) needs these
    // libraries indexed so `CoreTypes.index.getTopLevelProcedure` can
    // resolve members like `FunctionToJSExportedDartFunction|get#toJS`.
    "dart:js_interop",
    "dart:js_interop_unsafe",
    "dart:_js_types",
    "dart:_js_helper",
    "dart:js_util",
    "dart:_foreign_helper",
  ];

  // Phase 3 of the Dart-Live `package:web` support: lower `@JS()`-annotated
  // extension type member calls (the whole `package:web` API surface) into
  // the unsafe `getProperty` / `setProperty` / `callMethod` patches that
  // ship in our `_internal/vm/lib/js_interop_unsafe_patch.dart`.
  void _performJSInteropTransformations(
    Component component,
    CoreTypes coreTypes,
    ClassHierarchy hierarchy,
    Set<Library> interopDependentLibraries,
    DiagnosticReporter diagnosticReporter,
    ReferenceFromIndex? referenceFromIndex,
  ) {
    _nativeClasses ??= JsInteropChecks.getNativeClasses(component);
    final jsInteropReporter = JsInteropDiagnosticReporter(
      diagnosticReporter as DiagnosticReporter<Message, LocatedMessage>,
    );
    final jsInteropChecks = JsInteropChecks(
      coreTypes,
      hierarchy,
      jsInteropReporter,
      _nativeClasses!,
      // Reuse the dart2wasm relaxation: don't reject `external` members
      // without `@JS()`. Our user samples mix `@pragma("vm:external-name",
      // ...)` natives (EmbedderJSEval etc.) with `@JS()`-annotated bindings,
      // and there's no clean way to distinguish the two here.
      isDart2Wasm: true,
    );
    for (final library in interopDependentLibraries) {
      jsInteropChecks.visitLibrary(library);
    }
    final sharedInteropTransformer = SharedInteropTransformer(
      TypeEnvironment(coreTypes, hierarchy),
      jsInteropReporter,
      jsInteropChecks.exportChecker,
      jsInteropChecks.extensionIndex,
    );
    // JsUtilOptimizer rewrites external `@JS()` extension methods, getters,
    // setters and constructors into calls to `dart:js_util` (which we patch
    // to delegate to `dart:js_interop_unsafe`). The eraser drops `@JS()`
    // class types so their values can hold a JSObject at runtime.
    final jsUtilOptimizer = JsUtilOptimizer(
      coreTypes,
      hierarchy,
      jsInteropChecks.extensionIndex,
      isDart2JS: false,
    );
    // Erase `@staticInterop` class types to `dart:_js_helper.JSValue`, the
    // concrete class that holds the JS handle at runtime. (Default eraser
    // targets `dart:_interceptors.JavaScriptObject`, which the VM doesn't
    // have.)
    final jsValueClass = coreTypes.index.getClass(
      'dart:_js_helper',
      'JSValue',
    );
    final staticInteropEraser = StaticInteropClassEraser(
      coreTypes,
      eraseStaticInteropType: (staticInteropType) => InterfaceType(
        jsValueClass,
        staticInteropType.declaredNullability,
      ),
      additionalCoreLibraries: const {
        '_js_helper',
        '_js_types',
        'js_interop',
        'js_interop_unsafe',
        'js_util',
      },
    );
    for (final library in interopDependentLibraries) {
      sharedInteropTransformer.visitLibrary(library);
      if (!jsInteropReporter.hasJsInteropErrors) {
        jsUtilOptimizer.visitLibrary(library);
        staticInteropEraser.visitLibrary(library);
      }
    }
  }

  @override
  void performModularTransformationsOnLibraries(
    Component component,
    CoreTypes coreTypes,
    ClassHierarchy hierarchy,
    List<Library> libraries,
    Map<String, String>? environmentDefines,
    DiagnosticReporter diagnosticReporter,
    ReferenceFromIndex? referenceFromIndex, {
    void Function(String msg)? logger,
    ChangedStructureNotifier? changedStructureNotifier,
  }) {
    // Run JS-interop lowering before mixin / FFI transformations: the shared
    // transformer expects a fresh extension-type AST.
    //
    // Skip this entirely when we are *building* the SDK (i.e. compile_platform
    // is producing vm_platform.dill). At that point `dart:js_interop` is one
    // of the libraries being built — its members aren't in [CoreTypes.index]
    // yet, so `JsInteropChecks`'s constructor would crash on lookups for
    // `FunctionToJSExportedDartFunction|get#toJS`. User-code gen_kernel
    // happens against an already-built platform dill where those lookups
    // succeed, so it's the only path that actually needs the transformer.
    final dartJSInterop = Uri.parse('dart:js_interop');
    final buildingPlatform = libraries.any(
      (l) => l.importUri == dartJSInterop,
    );
    if (buildingPlatform) {
      logger?.call('Skipped JS interop transformations (building platform)');
    } else {
      // Restrict the transform to the libraries that this modular pass
      // owns (i.e. user code). Dart-Live builds vm_platform.dill ahead of
      // time and `gen_kernel` loads it from disk; the platform libraries
      // are already in `component.libraries` but we must not revisit them
      // (their `external` JS interop declarations are intentional and the
      // checker would reject them).
      final passLibs = libraries.toSet();
      final transitive = jsInteropHelper
          .calculateTransitiveImportsOfJsInteropIfUsed(
            component.libraries,
            dartJSInterop,
          );
      final interopDependent = <Library>{
        for (final l in transitive)
          if (passLibs.contains(l)) l,
      };
      if (interopDependent.isEmpty) {
        logger?.call('Skipped JS interop transformations');
      } else {
        _performJSInteropTransformations(
          component,
          coreTypes,
          hierarchy,
          interopDependent,
          diagnosticReporter,
          referenceFromIndex,
        );
        logger?.call('Transformed JS interop classes');
      }
    }

    transformMixins.transformLibraries(
      this,
      coreTypes,
      hierarchy,
      libraries,
      referenceFromIndex,
    );
    logger?.call("Transformed mixin applications");

    List<Library>? transitiveImportingDartFfi = ffiHelper
        .calculateTransitiveImportsOfDartFfiIfUsed(component, libraries);
    if (transitiveImportingDartFfi == null) {
      logger?.call("Skipped ffi transformation");
    } else {
      transformFfiDefinitions.transformLibraries(
        component,
        coreTypes,
        hierarchy,
        transitiveImportingDartFfi,
        diagnosticReporter,
        referenceFromIndex,
        changedStructureNotifier,
      );
      logger?.call("Transformed ffi definitions");

      // Transform @Native(..) functions into FFI native call functions.
      // Pass instance method receivers as implicit first argument to the static
      // native function.
      // Transform arguments that extend NativeFieldWrapperClass1 to Pointer if
      // the native function expects Pointer (to avoid Handle overhead).
      transformFfiNative.transformLibraries(
        component,
        coreTypes,
        hierarchy,
        transitiveImportingDartFfi,
        diagnosticReporter,
        referenceFromIndex,
      );
      logger?.call("Transformed ffi natives");

      // The use sites transformer implements `Native.addressOf` by reading a
      // VM pragma attached to valid targets in the native transformer. Hence,
      // it can only run after `@Native` targets have been transformed.
      transformFfiUseSites.transformLibraries(
        this,
        component,
        coreTypes,
        hierarchy,
        transitiveImportingDartFfi,
        diagnosticReporter,
        referenceFromIndex,
        environmentDefines,
      );
      logger?.call("Transformed ffi use sites");
    }

    deeply_immutable.validateLibraries(
      component,
      libraries,
      coreTypes,
      diagnosticReporter,
    );
    logger?.call("Validated deeply immutable");

    bool productMode = environmentDefines!["dart.vm.product"] == "true";
    lowering.transformLibraries(
      libraries,
      coreTypes,
      hierarchy,
      productMode: productMode,
      isClosureContextLoweringEnabled: flags.isClosureContextLoweringEnabled,
    );
    logger?.call("Lowering transformations performed");

    callSiteAnnotator.transformLibraries(
      component,
      libraries,
      coreTypes,
      hierarchy,
    );
    logger?.call("Annotated call sites");

    // Monomorphize class type parameters annotated with
    // `@pragma('vm:monomorphic')`. Runs while extension types are still intact
    // so it can verify representation types. No-op unless such a pragma exists.
    monomorphize.transformLibraries(libraries, coreTypes, diagnosticReporter);
    logger?.call("Monomorphized type parameters");
  }

  @override
  void performTransformationsOnProcedure(
    CoreTypes coreTypes,
    ClassHierarchy hierarchy,
    Procedure procedure,
    Map<String, String>? environmentDefines, {
    void Function(String msg)? logger,
    required DiagnosticReporter diagnosticReporter,
  }) {
    final TreeNode? component = procedure.enclosingLibrary.parent;
    if (component is Component) {
      final List<Library>? transitiveImportingDartFfi = ffiHelper
          .calculateTransitiveImportsOfDartFfiIfUsed(component, [
            procedure.enclosingLibrary,
          ]);
      if (transitiveImportingDartFfi != null) {
        transformFfiUseSites.transformProcedure(
          this,
          component,
          coreTypes,
          hierarchy,
          procedure,
          diagnosticReporter,
          null,
          environmentDefines,
        );
        logger?.call("Transformed ffi use sites");
      }
    }

    bool productMode = environmentDefines!["dart.vm.product"] == "true";
    lowering.transformProcedure(
      procedure,
      coreTypes,
      hierarchy,
      productMode: productMode,
      isClosureContextLoweringEnabled: flags.isClosureContextLoweringEnabled,
    );
    logger?.call("Lowering transformations performed");
  }

  Expression _instantiateInvocationMirrorWithType(
    CoreTypes coreTypes,
    Expression receiver,
    String name,
    Arguments arguments,
    int offset,
    int type,
  ) {
    return new ConstructorInvocation(
      coreTypes.invocationMirrorWithTypeConstructor,
      new Arguments(<Expression>[
        new SymbolLiteral(name)..fileOffset = offset,
        new IntLiteral(type)..fileOffset = offset,
        _fixedLengthList(
          coreTypes,
          coreTypes.typeNonNullableRawType,
          arguments.types.map<Expression>((t) => new TypeLiteral(t)).toList(),
          arguments.fileOffset,
        ),
        _fixedLengthList(
          coreTypes,
          const DynamicType(),
          arguments.positional,
          arguments.fileOffset,
        ),
        new StaticInvocation(
          coreTypes.mapUnmodifiable,
          new Arguments(
            [
              new MapLiteral(
                  new List<MapLiteralEntry>.from(
                    arguments.named.map((NamedExpression arg) {
                      return new MapLiteralEntry(
                        new SymbolLiteral(arg.name)
                          ..fileOffset = arg.fileOffset,
                        arg.value,
                      )..fileOffset = arg.fileOffset;
                    }),
                  ),
                  keyType: coreTypes.symbolNonNullableRawType,
                )
                ..isConst = (arguments.named.isEmpty)
                ..fileOffset = arguments.fileOffset,
            ],
            types: [coreTypes.symbolNonNullableRawType, new DynamicType()],
          ),
        )..fileOffset = offset,
      ]),
    );
  }

  @override
  Expression instantiateInvocation(
    CoreTypes coreTypes,
    Expression receiver,
    String name,
    Arguments arguments,
    int offset,
    bool isSuper,
  ) {
    bool isGetter = false, isSetter = false, isMethod = false;
    if (name.startsWith("set:")) {
      isSetter = true;
      name = name.substring(4);
    } else if (name.startsWith("get:")) {
      isGetter = true;
      name = name.substring(4);
    } else {
      isMethod = true;
    }

    int type = _invocationType(
      isGetter: isGetter,
      isSetter: isSetter,
      isMethod: isMethod,
      isSuper: isSuper,
    );

    return _instantiateInvocationMirrorWithType(
      coreTypes,
      receiver,
      name,
      arguments,
      offset,
      type,
    );
  }

  int _invocationType({
    bool isMethod = false,
    bool isGetter = false,
    bool isSetter = false,
    bool isSuper = false,
  }) {
    // This is copied from [_InvocationMirror](
    // ../../../../../../runtime/lib/invocation_mirror_patch.dart).

    // Constants describing the invocation type.
    const int _METHOD = 0;
    const int _GETTER = 1;
    const int _SETTER = 2;
    const int _KIND_BITS = 3;

    // These values, except _SUPER, are only used when throwing
    // NoSuchMethodError for compile-time resolution failures.
    const int _SUPER = 1;
    const int _LEVEL_SHIFT = _KIND_BITS;

    int type = -1;
    // For convenience, [isGetter] and [isSetter] takes precedence over
    // [isMethod].
    if (isGetter) {
      type = _GETTER;
    } else if (isSetter) {
      type = _SETTER;
    } else if (isMethod) {
      type = _METHOD;
    }

    if (isSuper) {
      type |= (_SUPER << _LEVEL_SHIFT);
    }

    return type;
  }

  Expression _fixedLengthList(
    CoreTypes coreTypes,
    DartType typeArgument,
    List<Expression> elements,
    int offset,
  ) {
    // TODO(ahe): It's possible that it would be better to create a fixed-length
    // list first, and then populate it. That would create fewer objects. But as
    // this is currently only used in (statically resolved) no-such-method
    // handling, the current approach seems sufficient.

    // The 0-element list must be exactly 'const[]'.
    if (elements.isEmpty) {
      return new ListLiteral([], typeArgument: typeArgument)..isConst = true;
    }

    return new StaticInvocation(
      coreTypes.listUnmodifiableConstructor,
      new Arguments(
        [
          new ListLiteral(elements, typeArgument: typeArgument)
            ..fileOffset = offset,
        ],
        types: [typeArgument],
      ),
    );
  }

  // In addition to the default implementation, we allow VM tests to import
  // private platform libraries - such as `dart:_internal` - for testing
  // purposes.
  bool allowPlatformPrivateLibraryAccess(Uri importer, Uri imported) =>
      super.allowPlatformPrivateLibraryAccess(importer, imported) ||
      importer.path.contains('runtime/observatory/tests') ||
      importer.path.contains('runtime/tests/vm/dart') ||
      importer.path.contains('tests/standalone/io') ||
      importer.path.contains('test-lib') ||
      importer.path.contains('tests/ffi') ||
      (importer.path == 'dart_runtime_service_vm/src/native_bindings.dart' &&
          imported.path == '_vmservice');

  @override
  Component configureComponent(Component component) {
    callSiteAnnotator.addRepositoryTo(component);
    return super.configureComponent(component);
  }

  @override
  Class concreteListLiteralClass(CoreTypes coreTypes) {
    return _growableList ??= coreTypes.index.getClass(
      'dart:core',
      '_GrowableList',
    );
  }

  @override
  Class concreteConstListLiteralClass(CoreTypes coreTypes) {
    return _immutableList ??= coreTypes.index.getClass(
      'dart:core',
      '_ImmutableList',
    );
  }

  @override
  Class concreteMapLiteralClass(CoreTypes coreTypes) {
    return _map ??= coreTypes.index.getClass('dart:_compact_hash', '_Map');
  }

  @override
  Class concreteConstMapLiteralClass(CoreTypes coreTypes) {
    return _constMap ??= coreTypes.index.getClass(
      'dart:_compact_hash',
      '_ConstMap',
    );
  }

  @override
  Class concreteSetLiteralClass(CoreTypes coreTypes) {
    return _set ??= coreTypes.index.getClass('dart:_compact_hash', '_Set');
  }

  @override
  Class concreteConstSetLiteralClass(CoreTypes coreTypes) {
    return _constSet ??= coreTypes.index.getClass(
      'dart:_compact_hash',
      '_ConstSet',
    );
  }

  @override
  Class getRecordImplementationClass(
    CoreTypes coreTypes,
    int numPositionalFields,
    List<String> namedFields,
  ) {
    return _record ??= coreTypes.index.getClass('dart:core', '_Record');
  }

  @override
  Class? concreteIntLiteralClass(CoreTypes coreTypes, int value) {
    const int bitsPerInt32 = 32;
    const int smiBits32 = bitsPerInt32 - 2;
    const int smiMin32 = -(1 << smiBits32);
    const int smiMax32 = (1 << smiBits32) - 1;
    if ((smiMin32 <= value) && (value <= smiMax32)) {
      // Value fits into Smi on all platforms.
      return _smi ??= coreTypes.index.getClass('dart:core', '_Smi');
    }
    // Otherwise, class could be either _Smi or _Mint depending on a platform.
    return null;
  }

  @override
  Class concreteDoubleLiteralClass(CoreTypes coreTypes, double value) {
    return _double ??= coreTypes.index.getClass('dart:core', '_Double');
  }

  @override
  Class concreteStringLiteralClass(CoreTypes coreTypes, String value) {
    const int maxLatin1 = 0xff;
    for (int i = 0; i < value.length; ++i) {
      if (value.codeUnitAt(i) > maxLatin1) {
        return _twoByteString ??= coreTypes.index.getClass(
          'dart:core',
          '_TwoByteString',
        );
      }
    }
    return _oneByteString ??= coreTypes.index.getClass(
      'dart:core',
      '_OneByteString',
    );
  }

  @override
  Class concreteClosureClass(CoreTypes coreTypes) {
    return _closure ??= coreTypes.index.getClass('dart:core', '_Closure');
  }

  @override
  Class? concreteAsyncResultClass(CoreTypes coreTypes) =>
      coreTypes.futureImplClass;

  @override
  Class? concreteSyncStarResultClass(CoreTypes coreTypes) {
    return _syncStarIterable ??= coreTypes.index.getClass(
      'dart:async',
      '_SyncStarIterable',
    );
  }

  @override
  ConstantsBackend get constantsBackend =>
      switch (flags.constKeepLocalsIndicator) {
        null => const ConstantsBackend(/* keeps defaults */),
        true => const ConstantsBackend(keepLocals: true),
        false => const ConstantsBackend(keepLocals: false),
      };

  @override
  Map<String, String> updateEnvironmentDefines(Map<String, String> map) {
    // TODO(alexmarkov): Call this from the front-end in order to have
    //  the same defines when compiling platform.
    map['dart.isVM'] = 'true';
    return map;
  }

  @override
  DartLibrarySupport get dartLibrarySupport => flags.supportMirrors
      ? const DefaultDartLibrarySupport()
      : const CustomizedDartLibrarySupport(unsupported: {'mirrors'});

  @override
  bool isSupportedPragma(String pragmaName) =>
      pragmaName.startsWith("vm:") || pragmaName.startsWith("dyn-module:");
}
