"""Implementation of the `cocotb_stubgen` rule and its backing aspect."""

load("@rules_venv//python/venv:defs.bzl", "py_venv_common")
load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")

_CocotbStubsInfo = provider(
    doc = "HDL-derived Python stub files. Internal to `cocotb_stubgen`.",
    fields = {
        "stubs": "depset[File] of generated stub `.py` files, one per HDL source.",
    },
)

def _cocotb_stubgen_aspect_impl(target, ctx):
    srcs = []
    if VhdlInfo in target:
        srcs.extend(target[VhdlInfo].srcs.to_list())
    if VerilogInfo in target:
        srcs.extend(target[VerilogInfo].srcs.to_list())
    if not srcs:
        return []

    stubs = []
    for src in srcs:
        # Emit `<basename>.py` alongside the aspected target's package so the
        # stub is importable as `<pkg>.<basename>` — mirrors the HDL source's
        # own name so testbenches don't need a second name to memorise.
        stem = src.basename[:-len(src.extension) - 1] if src.extension else src.basename
        stub = ctx.actions.declare_file(stem + ".py")
        args = ctx.actions.args()
        args.add("--output", stub)
        args.add(src)
        ctx.actions.run(
            executable = ctx.executable._stubgen,
            arguments = [args],
            inputs = [src],
            outputs = [stub],
            mnemonic = "CocotbStubgen",
            progress_message = "Generating cocotb stubs for %{input}",
        )
        stubs.append(stub)
    return [_CocotbStubsInfo(stubs = depset(stubs))]

_cocotb_stubgen_aspect = aspect(
    doc = """Generate one Python `typing.Protocol` stub per HDL source on an
`vhdl_library` / `verilog_library` target.

For each `File` in `VhdlInfo.srcs` / `VerilogInfo.srcs` on the aspected
target, runs the `stubgen` tool once and declares an output at
`<pkg>/<source_basename>.py` in the target's package. Results are
returned through the private `_CocotbStubsInfo` provider for the
`cocotb_stubgen` rule to consume.

Direct-only: `attr_aspects = []` — the aspect does not walk `.deps`.
Testbenches typically only touch top-level ports of the DUT `module`;
sub-instance stubs are opted into by pointing a separate
`cocotb_stubgen` at the sub-library.

Deduplication is inherent: aspects are keyed on `(aspect, target)` and
actions on their outputs, so the same `vhdl_library` covered by any
number of `cocotb_stubgen` targets runs each per-source `stubgen`
action exactly once per build.
""",
    implementation = _cocotb_stubgen_aspect_impl,
    attr_aspects = [],
    required_providers = [[VhdlInfo], [VerilogInfo]],
    attrs = {
        "_stubgen": attr.label(
            default = Label("//tools/stubgen"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _cocotb_stubgen_impl(ctx):
    if _CocotbStubsInfo not in ctx.attr.module:
        fail("cocotb_stubgen '{}': module '{}' produced no stubs (no VhdlInfo/VerilogInfo sources).".format(
            ctx.label,
            ctx.attr.module.label,
        ))
    stub_files = ctx.attr.module[_CocotbStubsInfo].stubs.to_list()
    py_info = py_venv_common.create_py_info(
        ctx = ctx,
        imports = [],
        srcs = stub_files,
    )
    return [
        DefaultInfo(
            files = depset(stub_files),
            runfiles = ctx.runfiles(files = stub_files),
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
Verilog ports and parameters fall back to `typing.Any` — Verilog port
declarations are effectively untyped once `logic` / `wire` / `reg` are
flattened.
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
)
