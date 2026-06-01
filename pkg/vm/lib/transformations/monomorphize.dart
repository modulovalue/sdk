// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Monomorphization of class type parameters annotated with
/// `@pragma('vm:monomorphic')`.
///
/// A class type parameter annotated with `@pragma('vm:monomorphic')` must be
/// bounded by a non-generic class type (e.g. `int`). When present, this
/// transform:
///
///   1. *Verifies* that every type argument supplied for the annotated
///      parameter is either the bound itself or an extension type whose
///      (transitive) representation type is the bound. Anything else is a
///      compile-time error. This guarantees that all instantiations share the
///      bound's runtime representation, so erasing the parameter to the bound
///      is sound.
///
///   2. *Monomorphizes* the class by replacing every occurrence of the type
///      parameter with the bound inside the class' members, dropping the type
///      parameter from the class, and rewriting every use site
///      (`C<NodeId>` -> `C`) across the libraries being compiled.
///
/// The payoff is on the VM JIT: a `void add(T v)` for a class-covariant `T`
/// otherwise emits, on every call, a `LoadField(:type_arguments)` plus a
/// covariant `AssertAssignable`. After monomorphization the parameter is plain
/// `int` and those instructions disappear, matching hand-written `int` code.
///
/// Source-level type safety is preserved: the front end type-checks the
/// original generic program *before* this transform runs; monomorphization
/// happens only in kernel, after checking, just like extension type erasure.

import 'package:_fe_analyzer_shared/src/messages/codes.dart'
    show Message, MessageCode;
import 'package:kernel/ast.dart';
import 'package:kernel/core_types.dart' show CoreTypes;
import 'package:kernel/src/replacement_visitor.dart' show ReplacementVisitor;
import 'package:kernel/target/targets.dart' show DiagnosticReporter;

const String kVmMonomorphicPragmaName = 'vm:monomorphic';

/// Describes a single class type parameter that should be monomorphized.
class _MonoTarget {
  final Class cls;
  final TypeParameter typeParam;

  /// Index of [typeParam] within `cls.typeParameters`.
  final int index;

  /// The (non-generic) class bound, e.g. `int`.
  final InterfaceType bound;

  _MonoTarget(this.cls, this.typeParam, this.index, this.bound);
}

void transformLibraries(
  List<Library> libraries,
  CoreTypes coreTypes,
  DiagnosticReporter diagnosticReporter,
) {
  final List<_MonoTarget> targets = _collectTargets(
    libraries,
    coreTypes,
    diagnosticReporter,
  );
  if (targets.isEmpty) return;

  for (final _MonoTarget target in targets) {
    final _Rewriter rewriter = _Rewriter(target, diagnosticReporter);
    // Rewrite the class itself and every use site in this compilation.
    for (final Library library in libraries) {
      rewriter.transform(library);
    }
    _dropTypeParameter(target);
  }
}

List<_MonoTarget> _collectTargets(
  List<Library> libraries,
  CoreTypes coreTypes,
  DiagnosticReporter diagnosticReporter,
) {
  final List<_MonoTarget> targets = <_MonoTarget>[];
  for (final Library library in libraries) {
    for (final Class cls in library.classes) {
      final List<TypeParameter> typeParameters = cls.typeParameters;
      for (int i = 0; i < typeParameters.length; i++) {
        final TypeParameter tp = typeParameters[i];
        if (!_hasMonomorphicPragma(tp, coreTypes)) continue;

        final DartType bound = tp.bound;
        if (bound is! InterfaceType || bound.typeArguments.isNotEmpty) {
          diagnosticReporter.report(
            _error(
              "The @pragma('vm:monomorphic') type parameter '${tp.name}' of "
              "class '${cls.name}' must be bounded by a non-generic class type "
              "(for example 'int'), but its bound is '$bound'.",
            ),
            tp.fileOffset,
            (tp.name ?? '').length,
            cls.fileUri,
          );
          continue;
        }
        targets.add(_MonoTarget(cls, tp, i, bound));
      }
    }
  }
  return targets;
}

bool _hasMonomorphicPragma(TypeParameter tp, CoreTypes coreTypes) {
  for (final Expression annotation in tp.annotations) {
    if (annotation is! ConstantExpression) continue;
    final Constant constant = annotation.constant;
    if (constant is! InstanceConstant) continue;
    if (constant.classNode != coreTypes.pragmaClass) continue;
    final Constant? name =
        constant.fieldValues[coreTypes.pragmaName.fieldReference];
    if (name is StringConstant && name.value == kVmMonomorphicPragmaName) {
      return true;
    }
  }
  return false;
}

/// Removes the monomorphized type parameter from the class and clears the
/// by-class covariance flags that would otherwise still request a runtime
/// `AssertAssignable` for the (now non-generic) parameters.
void _dropTypeParameter(_MonoTarget target) {
  final Class cls = target.cls;
  for (final Member member in cls.members) {
    if (member is Field) {
      member.isCovariantByClass = false;
    }
    final FunctionNode? function = member.function;
    if (function != null) {
      for (final VariableDeclaration p in function.positionalParameters) {
        p.isCovariantByClass = false;
      }
      for (final VariableDeclaration p in function.namedParameters) {
        p.isCovariantByClass = false;
      }
    }
  }
  cls.typeParameters.removeAt(target.index);
}

Message _error(String message) =>
    MessageCode('VmMonomorphic', problemMessage: message);

/// Tree transformer that rewrites all types (via [_TypeReplacer]) and strips
/// the monomorphized type argument from constructor / factory invocations,
/// while verifying every type argument supplied for the target parameter.
class _Rewriter extends Transformer {
  final _MonoTarget target;
  final DiagnosticReporter diagnosticReporter;
  late final _TypeReplacer _typeReplacer = _TypeReplacer(this);

  // Location used for diagnostics, updated as members / invocations are
  // entered (type nodes themselves carry no offsets).
  Uri _currentUri;
  int _currentOffset = TreeNode.noOffset;

  _Rewriter(this.target, this.diagnosticReporter)
    : _currentUri = target.cls.fileUri;

  @override
  DartType visitDartType(DartType node) =>
      node.accept1(_typeReplacer, Variance.covariant) ?? node;

  @override
  Supertype visitSupertype(Supertype node) {
    List<DartType>? newArgs;
    for (int i = 0; i < node.typeArguments.length; i++) {
      final DartType? replaced = node.typeArguments[i].accept1(
        _typeReplacer,
        Variance.covariant,
      );
      if (replaced != null) {
        newArgs ??= node.typeArguments.toList();
        newArgs[i] = replaced;
      }
    }
    if (node.className == target.cls.reference) {
      final List<DartType> args = (newArgs ?? node.typeArguments).toList();
      if (args.length > target.index) {
        _verifyArgument(args[target.index]);
        args.removeAt(target.index);
      }
      return Supertype.byReference(node.className, args);
    }
    return newArgs == null
        ? node
        : Supertype.byReference(node.className, newArgs);
  }

  @override
  TreeNode visitField(Field node) {
    return _withLocation(node.fileUri, node.fileOffset, () {
      node.transformChildren(this);
      return node;
    });
  }

  @override
  TreeNode visitProcedure(Procedure node) {
    return _withLocation(node.fileUri, node.fileOffset, () {
      node.transformChildren(this);
      return node;
    });
  }

  @override
  TreeNode visitConstructor(Constructor node) {
    return _withLocation(node.fileUri, node.fileOffset, () {
      node.transformChildren(this);
      return node;
    });
  }

  @override
  TreeNode visitConstructorInvocation(ConstructorInvocation node) {
    final int saved = _currentOffset;
    _currentOffset = node.fileOffset;
    node.transformChildren(this);
    if (node.target.enclosingClass == target.cls) {
      _stripInvocationArguments(node.arguments);
    }
    _currentOffset = saved;
    return node;
  }

  @override
  TreeNode visitStaticInvocation(StaticInvocation node) {
    final int saved = _currentOffset;
    _currentOffset = node.fileOffset;
    node.transformChildren(this);
    if (node.target.isFactory && node.target.enclosingClass == target.cls) {
      _stripInvocationArguments(node.arguments);
    }
    _currentOffset = saved;
    return node;
  }

  void _stripInvocationArguments(Arguments arguments) {
    if (arguments.types.length > target.index) {
      _verifyArgument(arguments.types[target.index]);
      arguments.types.removeAt(target.index);
    }
  }

  T _withLocation<T>(Uri uri, int offset, T Function() action) {
    final Uri savedUri = _currentUri;
    final int savedOffset = _currentOffset;
    _currentUri = uri;
    _currentOffset = offset;
    final T result = action();
    _currentUri = savedUri;
    _currentOffset = savedOffset;
    return result;
  }

  /// Reports an error unless [argument] is the bound or an extension type whose
  /// (transitive) representation type is the bound.
  void _verifyArgument(DartType argument) {
    final DartType erased = argument.extensionTypeErasure;
    final bool ok =
        erased is InterfaceType &&
        erased.classReference == target.bound.classReference &&
        erased.typeArguments.isEmpty;
    if (ok) return;
    diagnosticReporter.report(
      _error(
        "Type argument '$argument' is not allowed for the "
        "@pragma('vm:monomorphic') type parameter '${target.typeParam.name}' "
        "of class '${target.cls.name}'. Only '${target.bound}' or an extension "
        "type whose representation type is '${target.bound}' may be used here.",
      ),
      _currentOffset,
      1,
      _currentUri,
    );
  }
}

/// Replaces, within a [DartType]:
///   * the target type parameter with the bound, and
///   * occurrences of the target class with the same class minus its
///     monomorphized type argument (verifying the argument first).
class _TypeReplacer extends ReplacementVisitor {
  final _Rewriter owner;
  _TypeReplacer(this.owner);

  _MonoTarget get _target => owner.target;

  @override
  DartType? visitTypeParameterType(TypeParameterType node, Variance variance) {
    if (node.parameter == _target.typeParam) {
      final Nullability nullability =
          node.declaredNullability == Nullability.nullable
          ? Nullability.nullable
          : _target.bound.declaredNullability;
      return _target.bound.withDeclaredNullability(nullability);
    }
    return super.visitTypeParameterType(node, variance);
  }

  @override
  DartType? createInterfaceType(
    InterfaceType node,
    Nullability? newNullability,
    List<DartType>? newTypeArguments,
  ) {
    if (node.classReference == _target.cls.reference) {
      final List<DartType> args = (newTypeArguments ?? node.typeArguments)
          .toList();
      if (args.length > _target.index) {
        owner._verifyArgument(args[_target.index]);
        args.removeAt(_target.index);
        return InterfaceType.byReference(
          node.classReference,
          newNullability ?? node.nullability,
          args,
        );
      }
    }
    return super.createInterfaceType(node, newNullability, newTypeArguments);
  }
}
