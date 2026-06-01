# `@pragma('vm:monomorphic')` — type-parameter monomorphization (experiment)

A kernel transform that monomorphizes a class type parameter annotated with
`@pragma('vm:monomorphic')`, while keeping the generic API type-safe at the
source level.

## Idea

```dart
class BitArray<@pragma('vm:monomorphic') T extends int> {
  void add(T v) { ... }   // covariant-by-class T => runtime AssertAssignable
}
```

When a type parameter carries the pragma, the compiler:

1. **Verifies** that every type argument supplied for it is the bound itself, or
   an extension type whose representation type is (transitively) the bound.
   Anything else is a compile-time error. This guarantees all instantiations
   share the bound's runtime representation, so erasure is sound.
2. **Monomorphizes** the class: drops the type parameter, substitutes
   `T -> bound` in every member, clears the by-class covariance flags (removing
   the per-call `AssertAssignable` + `:type_arguments` load), and rewrites every
   `BitArray<X>` use site to non-generic `BitArray`.

Source-level type safety is preserved because the front end type-checks the
original generic program *before* the transform runs (the same "erase after
checking" model extension types themselves use).

## Implementation

- `pkg/vm/lib/transformations/monomorphize.dart` — the transform
  (`ReplacementVisitor` for type rewriting, `Substitution`, clears
  `isCovariantByClass`).
- `pkg/vm/lib/modular/target/vm.dart` — wired into
  `performModularTransformationsOnLibraries` (runs on JIT and AOT, while
  extension types are still intact so representation types are visible).

The `runtime/BUILD.gn`, `runtime/vm/BUILD.gn`, and
`build/config/compiler/BUILD.gn` changes are **local build workarounds** for a
newer toolchain (Fuchsia clang 23 with `is_clang=false`): tolerate GCC-only
warning flags / `-latomic`, and don't treat new clang warnings as errors. They
are not part of the feature and can be dropped.

## How to reproduce

```sh
# build the SDK (frontend snapshot includes the transform)
./tools/build.py -m release -a arm64 create_sdk
DART=xcodebuild/ReleaseARM64/dart-sdk/bin/dart
PLAT=xcodebuild/ReleaseARM64/vm_platform.dill

# compile a benchmark through the transform and run it
$DART pkg/vm/bin/gen_kernel.dart --platform $PLAT \
  --packages .dart_tool/package_config.json \
  -o /tmp/b.dill experiments/vm-monomorphic-pragma/bench/bench_mono.dart
$DART /tmp/b.dill

# inspect the IL: MonoBitArray.add has no AssertAssignable / type_arguments load
$DART --print-flow-graph-optimized --print-flow-graph-filter="MonoBitArray.add" /tmp/b.dill
```

## Verification (works)

`bench/safety/`:
- `bad_string.dart` — `BitArray<String>` is **rejected** at compile time.
- `bad_ext.dart` — `Bag<Money>` (extension type over `double`) is **rejected**.
- `good.dart` — `int`, `NodeId` (ext over int), and `Pid` (ext over ext over
  int, transitive) are **accepted** and run correctly.

IL confirms the transform: `MonoBitArray.add` lowers to `add(int)` with no
`AssertAssignable` and no `:type_arguments` load; the un-annotated
`GenericBitArray.add` keeps both.

## Honest performance finding

For an **`int`** bit array the annotation is **not** "much more efficient", and
the measurements show exactly why:

| benchmark | mono (`@pragma`) | generic (no pragma) | hand `int` |
|---|---|---|---|
| realistic (large fns, inliner budget exhausted) | 626 ms | 642 ms | 307 ms |
| `add` inlined, values prebuilt | 374 ms | 374 ms | 284 ms |
| covariant check isolated, `add` never-inline | ~480 ms | ~490 ms | – |

- The covariant `int` check is a cheap Smi test: ~2% when `add` cannot inline,
  and **0%** when it does (the optimizer already eliminates it on inlining, so
  mono == generic).
- The big gap in the naive benchmark was the **un-inlined `NodeId(i)`
  extension-type constructor** (inliner budget in large functions), present with
  *and* without the annotation. In a small loop `NodeId(i)` inlines to nothing
  (100M iterations in ~28 ms).

So on this mature VM, monomorphizing an `int`-bounded generic is a ~0–2% change.
The transform is correct and the verification is useful, but the perf lever for
fast extension-typed-int containers is **inlining**, not monomorphization.
Monomorphization would matter more for a heavier bound whose `AssertAssignable`
is an expensive subtype test rather than a Smi check.
