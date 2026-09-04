"""cocotb toolchain rules"""

load("@rules_venv//python:py_info.bzl", "PyInfo")
load(":cocotb_simulators.bzl", "CocotbSimInfo")

def _cocotb_toolchain_impl(ctx):
    simulators = {}
    for target, value in ctx.attr.simulators.items():
        if value in simulators:
            fail("The simulator '{}' is defined multiple times. Please update '{}'".format(
                value,
                ctx.label,
            ))
        simulators[value] = target

    vhdl_libraries = {}
    for target, name in ctx.attr.vhdl_libraries.items():
        vhdl_libraries.setdefault(name, []).extend(
            target[DefaultInfo].files.to_list(),
        )

    return [platform_common.ToolchainInfo(
        cocotb = ctx.attr.cocotb,
        simulators = simulators,
        default_sim = ctx.attr.default_sim or None,
        env = ctx.attr.env,
        stubgen = ctx.attr.stubgen[DefaultInfo].files_to_run,
        vhdl_libraries = vhdl_libraries,
        label = ctx.label,
    )]

cocotb_toolchain = rule(
    doc = """\
Define a toolchain for `cocotb_*` rules.

The toolchain bundles a `cocotb` Python library with a set of HDL
simulators that `cocotb_test` targets can select between via their `sim`
attribute. Register an instance with the standard `toolchain(...)`
wrapper to make it discoverable.

### Registering simulators

Each entry in `simulators` is a `cocotb_*_sim` target keyed by the
*string* name that `cocotb_test(sim = ...)` will use to select it.
Names are user-chosen — common conventions are `"verilator"`,
`"icarus"`, `"ghdl"`. Each name must be unique within the dict.

```python
load("@rules_cocotb//cocotb:cocotb_ghdl_sim.bzl", "cocotb_ghdl_sim")
load("@rules_cocotb//cocotb:cocotb_icarus_sim.bzl", "cocotb_icarus_sim")
load("@rules_cocotb//cocotb:cocotb_toolchain.bzl", "cocotb_toolchain")
load("@rules_cocotb//cocotb:cocotb_verilator_sim.bzl", "cocotb_verilator_sim")

# Instantiate the sim rules you want to ship.
cocotb_verilator_sim(
    name = "cocotb_verilator",
    # ... (see //cocotb/toolchain:BUILD.bazel for the full attr set)
)

cocotb_ghdl_sim(
    name = "cocotb_ghdl",
    ghdl = "@ghdl",
    vhdl_libs = ["@ghdl//:vhdl_libs_v08"],
)

cocotb_icarus_sim(
    name = "cocotb_icarus",
    iverilog = "@iverilog//:iverilog",
    vvp = "@iverilog//:vvp",
    ivl_files = {
        "@iverilog//:ivl": "ivl",
        # ... (see //cocotb/toolchain:BUILD.bazel for the full map)
    },
)

cocotb_toolchain(
    name = "my_cocotb_toolchain",
    cocotb = "//path/to:cocotb_py_library",
    default_sim = "verilator",
    simulators = {
        ":cocotb_ghdl": "ghdl",
        ":cocotb_icarus": "icarus",
        ":cocotb_verilator": "verilator",
    },
)

toolchain(
    name = "my_toolchain",
    toolchain = ":my_cocotb_toolchain",
    toolchain_type = "@rules_cocotb//cocotb:toolchain_type",
)
```

Add `register_toolchains("//path/to:my_toolchain")` to `MODULE.bazel`
ahead of `//cocotb/toolchain` to override the default. `default_sim`
chooses which simulator runs when a `cocotb_test` omits its own `sim`
attribute; it's optional, but if set must name one of the keys in
`simulators`.

### Overriding the stub generator

`cocotb_stubgen` resolves this same toolchain to find the tool that turns
HDL sources into typed Python stubs, so a project that needs custom type
mapping sets `stubgen` here rather than registering anything extra:

```python
cocotb_toolchain(
    name = "my_cocotb_toolchain",
    cocotb = "//path/to:cocotb_py_library",
    simulators = {":cocotb_ghdl": "ghdl"},
    stubgen = "//path/to:my_stubgen",
)
```

Leaving it unset uses the generator shipped with `rules_cocotb`.

### Supplying VHDL standard libraries

`vhdl_libraries` is optional and empty by default. Left empty, the
generator works from the parse tree alone: it maps each port's terminal
type mark (`std_logic`, `unsigned`, `integer`, ...) onto a cocotb handle
class, which covers designs whose ports are declared in terms of the
standard types directly.

Supplying the `STD` / `IEEE` sources lets a generator fully elaborate
instead, so ports declared with project-local aliases and subtypes
resolve through to their base types:

```python
cocotb_toolchain(
    name = "my_cocotb_toolchain",
    cocotb = "//path/to:cocotb_py_library",
    simulators = {":cocotb_ghdl": "ghdl"},
    vhdl_libraries = {
        "@some_vhdl_std//:ieee_srcs": "ieee",
        "@some_vhdl_std//:std_srcs": "std",
    },
)
```

Each entry maps a target whose files are `.vhd` sources to the VHDL
library name they belong to; several targets may share a name.

Per-simulator API and wiring details live in the
[Simulators](./simulators.md) section.
""",
    implementation = _cocotb_toolchain_impl,
    attrs = {
        "cocotb": attr.label(
            doc = "The `cocotb` python library.",
            providers = [PyInfo],
            mandatory = True,
            cfg = "exec",
        ),
        "default_sim": attr.string(
            doc = "An optional default simulator to use.",
        ),
        "env": attr.string_dict(
            doc = (
                "Environment variables to set whenever the toolchain " +
                "invokes a simulator. Applied to every sim registered " +
                "in `simulators`; for sim-specific vars (license server, " +
                "install root, etc.) prefer the per-`cocotb_*_sim` `env` " +
                "attr instead. Precedence at test time: toolchain `env` " +
                "< sim `env` < rule-level `cocotb_test(env = ...)`."
            ),
            default = {},
        ),
        "simulators": attr.label_keyed_string_dict(
            doc = "A mapping of `cocotb_*_sim` targets to their matching simulator names. Every target must provide `CocotbSimInfo`.",
            allow_empty = False,
            mandatory = True,
            cfg = "exec",
            providers = [
                [CocotbSimInfo],
            ],
        ),
        "stubgen": attr.label(
            doc = (
                "The stub generator `cocotb_stubgen` runs. Defaults to the " +
                "generator shipped with `rules_cocotb`; override it to swap " +
                "in a generator that understands project-specific HDL type " +
                "packages. A replacement must accept repeated " +
                "`--stub SRC OUTPUT METADATA MODULE_IMPORT_PATH` groups and " +
                "repeated `--dep-metadata PATH` flags, writing a Python stub " +
                "to `OUTPUT` and a JSON record of the module's import path " +
                "and exported class names to `METADATA`."
            ),
            default = Label("//tools/stubgen"),
            executable = True,
            cfg = "exec",
        ),
        "vhdl_libraries": attr.label_keyed_string_dict(
            doc = (
                "Optional VHDL standard library sources for `stubgen`, " +
                "keyed by the library name each target's files belong to. " +
                "A generator that can fully elaborate uses these to resolve " +
                "aliases and subtypes down to their base types; the bundled " +
                "generator works from the parse tree alone and ignores them."
            ),
            allow_files = [".vhd", ".vhdl"],
            default = {},
            cfg = "exec",
        ),
    },
)

def _current_cocotb_toolchain_lib_impl(ctx):
    toolchain = ctx.toolchains[Label("//cocotb:toolchain_type")]
    cocotb_target = toolchain.cocotb

    # For some reason, simply forwarding `DefaultInfo` from
    # the target results in a loss of data. To avoid this a
    # new provider is created with the same info.
    default_info = DefaultInfo(
        files = cocotb_target[DefaultInfo].files,
        runfiles = cocotb_target[DefaultInfo].default_runfiles,
    )

    return [
        default_info,
        cocotb_target[PyInfo],
        cocotb_target[OutputGroupInfo],
        cocotb_target[InstrumentedFilesInfo],
    ]

current_cocotb_toolchain_lib = rule(
    doc = "Match and expose the `cocotb_toolchain` for the current configuration.",
    implementation = _current_cocotb_toolchain_lib_impl,
    toolchains = [
        str(Label("//cocotb:toolchain_type")),
    ],
)
