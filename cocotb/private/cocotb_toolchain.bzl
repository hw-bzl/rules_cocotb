"""cocotb toolchain rules"""

load("@rules_venv//python:py_info.bzl", "PyInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load(":cocotb_simulators.bzl", "CocotbSimInfo")

# The VHDL standard libraries stub generation knows how to use. Kept sorted:
# it is compared against a sorted list of what a toolchain actually supplied.
_STUBGEN_VHDL_LIBRARIES = ["ieee", "std"]

def _cocotb_toolchain_impl(ctx):
    simulators = {}
    for target, value in ctx.attr.simulators.items():
        if value in simulators:
            fail("The simulator '{}' is defined multiple times. Please update '{}'".format(
                value,
                ctx.label,
            ))
        simulators[value] = target

    # Direct entries plus their transitive `deps`, so naming an `ieee`
    # library that itself deps on `std` brings `std` along. Collected through
    # a depset so listing both explicitly doesn't duplicate either.
    direct = [target[VhdlInfo] for target in ctx.attr.vhdl_libraries]
    vhdl_libraries = depset(
        direct,
        transitive = [info.deps for info in direct],
    ).to_list()

    # All of the expected libraries or none of them. A partial set is rejected
    # rather than honored because an elaborating generator degrades a type
    # mark it can't resolve to `Any` silently rather than erroring, so half a
    # set yields quietly worse stubs than supplying nothing.
    found = sorted({info.library: None for info in vhdl_libraries})
    if found and found != _STUBGEN_VHDL_LIBRARIES:
        fail("{}: vhdl_libraries must provide exactly the {} libraries or none at all, got {}. A library's name comes from `vhdl_library(library = ...)` and defaults to its target name; names reached through `deps` count too.".format(
            ctx.label,
            _STUBGEN_VHDL_LIBRARIES,
            found,
        ))

    return [platform_common.ToolchainInfo(
        cocotb = ctx.attr.cocotb,
        simulators = simulators,
        default_sim = ctx.attr.default_sim or None,
        env = ctx.attr.env,
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

### Supplying VHDL standard libraries

`vhdl_libraries` is optional and empty by default, and is the only part
of this toolchain that `cocotb_stubgen` reads. It reads it optionally:
stub generation is static analysis of HDL sources and runs no simulator,
so a project that only wants typed DUT handles need not register a
`cocotb_toolchain` at all.

The generator shipped today works from the parse tree alone — it maps
each port's terminal type mark (`std_logic`, `unsigned`, `integer`, ...)
onto a cocotb handle class, which covers designs whose ports are declared
in terms of the standard types directly — and so **ignores these
sources**. The attr reserves the interface for full elaboration, which
would additionally resolve project-local aliases and subtypes through to
their base types; until that lands, setting it only adds the files to
each stubgen action's inputs:

```python
vhdl_library(
    name = "std",
    srcs = glob(["std/*.vhdl"]),
)

vhdl_library(
    name = "ieee",
    srcs = glob(["ieee2008/*.vhdl"]),
    deps = [":std"],
)

cocotb_toolchain(
    name = "my_cocotb_toolchain",
    cocotb = "//path/to:cocotb_py_library",
    simulators = {":cocotb_ghdl": "ghdl"},
    vhdl_libraries = [":ieee"],
)
```

Each entry is a `vhdl_library`; the VHDL library name comes from its
`library` attr, which defaults to the target name. Libraries reached
through `deps` count too, so listing `:ieee` above is enough to pull in
`:std`. Several targets may share a library name.

Only `ieee` and `std` are accepted, and the set must be complete: a
partial set is rejected rather than honored, because unresolved types
degrade to `Any` silently instead of erroring.

Note that `@ghdl//:vhdl_libs_v08` is *not* usable here: it is a compiled
GHDL library artifact for `cocotb_ghdl_sim(vhdl_libs = ...)`, whereas
this attr wants VHDL sources for the parser.

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
        "vhdl_libraries": attr.label_list(
            doc = (
                "Optional VHDL standard library sources for `stubgen`, as " +
                "`vhdl_library` targets. Supply all of {} (counting ".format(_STUBGEN_VHDL_LIBRARIES) +
                "libraries reached through `deps`) or leave this empty. " +
                "Reserved for full elaboration; the generator shipped today " +
                "ignores them."
            ),
            providers = [VhdlInfo],
            cfg = "target",
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
