"""Implementation of the `cocotb_stubgen` rule and its backing aspect."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_venv//python:py_info.bzl", "PyInfo")
load("@rules_venv//python/venv:defs.bzl", "py_venv_common")
load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")

_TOOLCHAIN_TYPE = Label("//cocotb:toolchain_type")

_CocotbStubsInfo = provider(
    doc = "HDL-derived Python stub files. Internal to `cocotb_stubgen`.",
    fields = {
        "metadata": (
            "depset[File] of generated sibling `.json` metadata files. " +
            "Each records the emitted module's import path and the set of " +
            "class names it exports; consumed by transitive stubgen actions " +
            "to type cross-file entity references instead of downgrading to `Any`."
        ),
        "py_info": (
            "`PyInfo` aggregating this target's stub `.py` files plus every " +
            "transitively-aspected dep's stubs. The `cocotb_stubgen` rule " +
            "returns this directly so consumers see the entire stub graph."
        ),
    },
)

def _aggregate_dep_py_info(ctx, dep_py_infos):
    """Build a `dep_info` struct for `create_py_info` from aspect-collected PyInfos.

    Aspected `vhdl_library` / `verilog_library` targets don't expose `PyInfo`
    as a first-class provider — the aspect stashes it under
    `_CocotbStubsInfo.py_info`. This helper adapts a list of those PyInfo
    objects to the struct shape `py_venv_common.create_py_info(dep_info=...)`
    expects, sidestepping the `dep[PyInfo]` / `dep[DefaultInfo]` lookups in
    `py_venv_common.create_dep_info` that would fail here.
    """
    return struct(
        transitive_imports = depset(
            transitive = [pi.imports for pi in dep_py_infos],
        ),
        transitive_sources = depset(
            transitive = [pi.transitive_sources for pi in dep_py_infos],
            order = "postorder",
        ),
        runfiles = ctx.runfiles(),
    )

def _cocotb_stubgen_aspect_impl(target, ctx):
    # Metadata + PyInfo from deps flows through even when the current target
    # has no HDL sources of its own — an intermediate `vhdl_library` that just
    # re-exports deps still needs to propagate the transitive stub set.
    # `verilog_deps`/`vhdl_deps` cover mixed-language edges that
    # rules_vhdl/rules_verilog expose alongside the plain `deps`.
    transitive_metadata = []
    dep_py_infos = []
    for dep_attr in ("deps", "verilog_deps", "vhdl_deps"):
        for dep in getattr(ctx.rule.attr, dep_attr, []):
            if _CocotbStubsInfo in dep:
                transitive_metadata.append(dep[_CocotbStubsInfo].metadata)
                dep_py_infos.append(dep[_CocotbStubsInfo].py_info)

    dep_info = _aggregate_dep_py_info(ctx, dep_py_infos)

    srcs = []
    if VhdlInfo in target:
        srcs.extend(target[VhdlInfo].srcs.to_list())
    if VerilogInfo in target:
        srcs.extend(target[VerilogInfo].srcs.to_list())

    dep_metadata_depset = depset(transitive = transitive_metadata)

    toolchain = ctx.toolchains[_TOOLCHAIN_TYPE]

    # Optional STD/IEEE sources. Without them the generator maps each
    # port's terminal type mark onto a handle class; with them it can
    # elaborate aliases and subtypes down to their base types.
    vhdl_library_files = []
    for files in toolchain.vhdl_libraries.values():
        vhdl_library_files.extend(files)

    # One `stubgen` invocation per library. The tool internally does
    # phase 1 (extract + metadata dump for every src) then phase 2 (render
    # every .py), sharing sibling class names in-process. Batching this
    # way amortizes Python/sandbox startup — the useful per-src work is
    # tiny compared to the ~100-350ms overhead of a fresh action.
    stubs = []
    metadata_files = []
    if srcs:
        stubgen_args = ctx.actions.args()
        stubgen_args.add_all(dep_metadata_depset, before_each = "--dep-metadata")
        for name in sorted(toolchain.vhdl_libraries):
            for file in toolchain.vhdl_libraries[name]:
                stubgen_args.add("--vhdl-library")
                stubgen_args.add(name)
                stubgen_args.add(file)
        for src in srcs:
            stem = paths.split_extension(src.basename)[0]
            stub = ctx.actions.declare_file(stem + ".py")
            meta = ctx.actions.declare_file(stem + ".json")

            # Dotted Python import path — must match what `declare_file`
            # yields on `sys.path` so downstream `from <path> import <Class>`
            # resolves at runtime.
            if ctx.label.package:
                module_import_path = ctx.label.package.replace("/", ".") + "." + stem
            else:
                module_import_path = stem

            stubgen_args.add("--stub")
            stubgen_args.add(src)
            stubgen_args.add(stub)
            stubgen_args.add(meta)
            stubgen_args.add(module_import_path)
            stubs.append(stub)
            metadata_files.append(meta)

        ctx.actions.run(
            executable = toolchain.stubgen,
            arguments = [stubgen_args],
            inputs = depset(
                srcs + vhdl_library_files,
                transitive = [dep_metadata_depset],
            ),
            outputs = stubs + metadata_files,
            mnemonic = "CocotbStubgen",
            progress_message = "CocotbStubgen %{label}",
        )
    return [_CocotbStubsInfo(
        metadata = depset(metadata_files, transitive = [dep_metadata_depset]),
        py_info = py_venv_common.create_py_info(
            ctx = ctx,
            imports = [],
            srcs = stubs,
            dep_info = dep_info,
        ),
    )]

_cocotb_stubgen_aspect = aspect(
    doc = """Generate one Python stub per HDL source on an
`vhdl_library` / `verilog_library` target, plus a sibling `.json`
metadata file that lets consumer stubgen actions type cross-file
entity references.

For each aspected library the aspect declares outputs at
`<pkg>/<source_basename>.{py,json}` per src and runs a single
`stubgen` action covering the whole library. The tool internally
extracts metadata for every src first, then renders every stub with
the combined (transitive-dep + sibling) class-name map — so
cross-file entity references within the library resolve in-process
without a second Bazel action.

`attr_aspects = ["deps", "verilog_deps", "vhdl_deps"]`: the aspect
walks all three edge types **for metadata only**. Dep stubs are still
gated behind an explicit `cocotb_stubgen` at the dep — walking deps
here just gives each render visibility into what class names its deps
export, so a VHDL testbench that instantiates `dut : entity work.foo`
gets a typed `dut: Foo` field with a real import instead of the `Any`
fallback, even when `foo` is a Verilog module reached via
`verilog_deps`.

Deduplication is inherent: aspects are keyed on `(aspect, target)`
and actions on their outputs, so the same `vhdl_library` covered by
any number of `cocotb_stubgen` targets runs its `stubgen` action
exactly once per build.

The generator binary and its optional VHDL standard libraries come from
`cocotb_toolchain` rather than implicit attrs, so a project can point
them at its own generator and type packages without patching this rule.
They ride on the existing `cocotb_toolchain` because nothing about the
generator varies between the libraries in one graph — every HDL library
the aspect touches wants the same tool, and any project generating stubs
already registers a `cocotb_toolchain` to run the tests that consume
them.
""",
    implementation = _cocotb_stubgen_aspect_impl,
    attr_aspects = ["deps", "verilog_deps", "vhdl_deps"],
    required_providers = [[VhdlInfo], [VerilogInfo]],
    toolchains = [str(_TOOLCHAIN_TYPE)],
)

def _cocotb_stubgen_impl(ctx):
    if _CocotbStubsInfo not in ctx.attr.module:
        fail("cocotb_stubgen '{}': module '{}' produced no stubs (no VhdlInfo/VerilogInfo sources).".format(
            ctx.label,
            ctx.attr.module.label,
        ))
    py_info = ctx.attr.module[_CocotbStubsInfo].py_info
    return [
        DefaultInfo(
            files = py_info.transitive_sources,
            runfiles = ctx.runfiles(transitive_files = py_info.transitive_sources),
        ),
        py_info,
    ]

cocotb_stubgen = rule(
    doc = """Generate typed cocotb DUT stubs for an HDL library.

Point `module` at a `vhdl_library` or `verilog_library` and the rule
produces a `PyInfo` target you add to any Python rule's `deps` (most
commonly `cocotb_test.deps`) to make the DUT's ports and signals
type-check.

Example — a VHDL DUT `tests/foo/dut.vhd`:

```python
vhdl_library(
    name = "dut",
    srcs = ["dut.vhd"],
)

cocotb_stubgen(
    name = "dut_stubs",
    module = ":dut",
)

cocotb_test(
    name = "dut_test",
    srcs = ["dut_test.py"],
    module = ":dut",
    deps = [":dut_stubs"],
    sim = "ghdl",
)
```

One class is emitted per entity / module found in each HDL source, each
subclassing `cocotb.handle.HierarchyObject` so it can stand in as the
DUT parameter's type directly. The import path mirrors the HDL source's
own package and basename — `tests/foo/dut.vhd` yields a `Dut` class
importable as:

```python
from tests.foo.dut import Dut

async def test(dut: Dut) -> None:
    dut.clk.value = 0
```

VHDL ports / generics / architecture signals are typed against cocotb's
handle hierarchy (`LogicObject`, `LogicArrayObject`, `IntegerObject`, ...).
Verilog ports, parameters and nets fall back to `typing.Any` — Verilog
declarations are effectively untyped once `logic` / `wire` / `reg` are
flattened. Instantiations in either language type as the instantiated
entity's own stub class.

Verilog is parsed without preprocessing, so ports supplied by a macro
(`` module m(`MY_PORTS); ``) are omitted rather than guessed at.

The generator itself comes from the registered
[`cocotb_toolchain`](./cocotb_toolchain.md): its `stubgen` attr
substitutes a different generator, and its optional `vhdl_libraries`
attr supplies the `STD` / `IEEE` sources a generator needs to resolve
project-local aliases and subtypes down to their base types.
""",
    implementation = _cocotb_stubgen_impl,
    attrs = {
        "module": attr.label(
            doc = "HDL library (`vhdl_library` / `verilog_library`) to stub.",
            mandatory = True,
            providers = [[VhdlInfo], [VerilogInfo]],
            aspects = [_cocotb_stubgen_aspect],
        ),
    },
    provides = [PyInfo],
)
