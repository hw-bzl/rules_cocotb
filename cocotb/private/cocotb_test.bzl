"""Cocotb rules"""

load("@rules_venv//python:py_info.bzl", "PyInfo")
load("@rules_venv//python/venv:defs.bzl", "py_venv_common")
load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load(":cocotb_precompiled_library_info.bzl", "CocotbPrecompiledLibraryInfo")
load(":cocotb_simulators.bzl", "CocotbSimInfo", "cocotb_sim_compile")

# cocotb simulator name -> precompiled-library format family. Only sims with
# a precompiled-library concept appear here; open-source sims
# (icarus/verilator/ghdl/nvc) are intentionally absent and will fail the
# lookup below if a test tries to attach `precompiled_libs`. The same table
# is mirrored in `tools/cocotb_process_wrapper/cocotb_process_wrapper.py` —
# keep them in sync.
_SIM_FORMAT = {
    "activehdl": "aldec",
    "ies": "cadence",
    "modelsim": "mentor",
    "questa": "mentor",
    "riviera": "aldec",
    "vcs": "synopsys",
    "vcs_mx": "synopsys",
    "xcelium": "cadence",
    "xsim": "xilinx",
}

# Recognised values for `CocotbPrecompiledLibraryInfo.vendor`. Empty string
# means "no ecosystem quirks apply." Adding a new vendor requires both a new
# entry here and a corresponding handler in the wrapper.
_KNOWN_VENDORS = ["", "xilinx"]

def _rlocationpath(file, workspace_name):
    """A convenience method for producing the `rlocationpath` of a file.

    Args:
        file (File): The file object to generate the path for.
        workspace_name (str): The current workspace name.

    Returns:
        str: The `rlocationpath` value.
    """
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]

    return "{}/{}".format(workspace_name, file.short_path)

def _cocotb_test_impl(ctx):
    toolchain = ctx.toolchains[Label("//cocotb:toolchain_type")]
    venv_toolchain = py_venv_common.get_toolchain(ctx)

    sim = toolchain.default_sim
    if ctx.attr.sim:
        sim = ctx.attr.sim
    if not sim:
        fail("No simulator chosen for `{}`".format(ctx.label))

    if sim not in toolchain.simulators:
        fail("No simulator '{}' provided in the current `cocotb_toolchain` {}. Options are: {}".format(
            sim,
            toolchain.label,
            ", ".join(toolchain.simulators.keys()),
        ))
    simulator = toolchain.simulators[sim]
    sim_info = simulator[CocotbSimInfo]

    # Validate every precompiled library set's format family matches the
    # resolved test simulator. Catching the mismatch at analysis time saves a
    # confusing test-time error like "vmap directive ignored" or wrong-format
    # link config.
    precompiled_libs_info = []
    expected_format = None
    if ctx.attr.precompiled_libs:
        expected_format = _SIM_FORMAT.get(sim)
        if expected_format == None:
            fail(
                ("`{tgt}` attaches `precompiled_libs` but its simulator " +
                 "`{sim}` has no known precompiled-library format. " +
                 "Supported sims: {known}.").format(
                    tgt = ctx.label,
                    sim = sim,
                    known = ", ".join(sorted(_SIM_FORMAT.keys())),
                ),
            )
        for lib_target in ctx.attr.precompiled_libs:
            lib_info = lib_target[CocotbPrecompiledLibraryInfo]
            if lib_info.format != expected_format:
                fail(
                    ("`{tgt}` lists precompiled library `{lib}` of format " +
                     "`{lib_format}`, but the test's simulator `{sim}` " +
                     "expects format `{expected}`. Rebuild the library for " +
                     "`{expected}` or switch the test's simulator.").format(
                        tgt = ctx.label,
                        lib = lib_target.label,
                        lib_format = lib_info.format,
                        sim = sim,
                        expected = expected_format,
                    ),
                )
            if lib_info.vendor not in _KNOWN_VENDORS:
                fail(
                    ("`{tgt}` lists precompiled library `{lib}` with " +
                     "unknown vendor `{lib_vendor}`. Known vendors: " +
                     "{known}.").format(
                        tgt = ctx.label,
                        lib = lib_target.label,
                        lib_vendor = lib_info.vendor,
                        known = ", ".join([repr(v) for v in _KNOWN_VENDORS]),
                    ),
                )
            precompiled_libs_info.append((lib_info.library_dir, lib_info.vendor))

    hdl_toplevel = ctx.attr.module.label.name
    hdl_toplevel_lang = None
    hdl_toplevel_library = None

    if VerilogInfo in ctx.attr.module:
        hdl_toplevel_lang = "verilog"
    elif VhdlInfo in ctx.attr.module:
        hdl_toplevel_lang = "vhdl"
        hdl_toplevel_library = ctx.attr.module[VhdlInfo].library or "work"
    else:
        fail("Unexpected module type: {}".format(ctx.attr.module))

    sim_output = cocotb_sim_compile(
        ctx = ctx,
        simulator = simulator,
        module = ctx.attr.module,
        sim_opts = ctx.attr.sim_opts,
    )

    # Compose the simulator subprocess env from four layers, right-side
    # wins on overlap:
    #   1. `toolchain.env` — toolchain-wide defaults (rare; useful when
    #      multiple sims share an install).
    #   2. `sim_info.env` — declared on the `cocotb_*_sim` rule. Natural
    #      home for sim-specific install vars (license server, install
    #      root). `CocotbSimInfo`'s init guarantees this is at least `{}`.
    #   3. `sim_output.sim_env` — derived at compile time by the sim's
    #      `compile` function (e.g. GHDL's `GHDL_PREFIX` chosen from
    #      `vhdl_libs`).
    #   4. `ctx.attr.env` — per-`cocotb_test` override, also flows into
    #      `RunEnvironmentInfo` below for the test process env so the
    #      test and its simulator subprocess see the same values.
    #      Expanded for make-variables / `$(rlocationpath ...)` against
    #      `ctx.attr.data` so users can reference data deps by label.
    expanded_user_env = {
        k: ctx.expand_location(v, ctx.attr.data)
        for k, v in ctx.attr.env.items()
    }
    sim_env = (
        toolchain.env |
        sim_info.env |
        (getattr(sim_output, "sim_env", None) or {}) |
        expanded_user_env
    )
    sim_test_args = getattr(sim_output, "test_args", None) or []
    sim_build_args = getattr(sim_output, "build_args", None) or []
    sim_build_sources = getattr(sim_output, "build_sources", None) or []
    sim_bin = getattr(sim_output, "bin", None)
    if not sim_bin and not sim_build_sources:
        fail(
            "Simulator '{}' produced neither a pre-compiled `bin` nor `build_sources` ".format(sim) +
            "for {}; cocotb_test has nothing to run.".format(ctx.label),
        )

    args = ctx.actions.args()
    args.set_param_file_format("multiline")

    args.add("--sim", sim)
    for bin_name, bin_file in sim_info.bins.items():
        args.add("--sim_bin={}:{}".format(bin_name, _rlocationpath(bin_file, ctx.workspace_name)))
    for name, value in sim_env.items():
        args.add("--sim_env={}={}".format(name, value))
    if sim_bin:
        args.add("--bin", _rlocationpath(sim_bin, ctx.workspace_name))
    args.add("--workspace_name", ctx.workspace_name)
    for src in ctx.files.srcs:
        args.add("--test={}".format(_rlocationpath(src, ctx.workspace_name)))
    for lib_dir, lib_vendor in precompiled_libs_info:
        # `<format>:<vendor>:<rlocationpath>` — format prefix lets the
        # wrapper sanity-check at runtime (analysis already verified, but a
        # defensive runtime check guards against accidental wrapper
        # invocations); vendor selects ecosystem quirks (e.g. Xilinx adds
        # `glbl` as a sibling top + fs simulation precision).
        args.add("--precompiled_lib_dir={}:{}:{}".format(
            expected_format,
            lib_vendor,
            _rlocationpath(lib_dir, ctx.workspace_name),
        ))

    # Coverage bridge: when the sim integration provides one AND this
    # test was analysed under `bazel coverage`, pass the post-process
    # tool's rlocationpath + sim-relative data glob + args template to
    # the wrapper. The wrapper runs the tool after `runner.test()`
    # returns, with `{output}` and `{data_files}` substituted to produce
    # lcov at `$COVERAGE_OUTPUT_FILE`.
    # Gate on whether the DUT (the HDL `module`) should be instrumented,
    # not whether the test rule itself should — coverage applies to the
    # HDL sources reachable through `module[InstrumentedFilesInfo]`,
    # which is what Bazel's instrumentation filter actually checks.
    coverage_runfiles = ctx.runfiles()
    if sim_info.coverage and ctx.coverage_instrumented(ctx.attr.module):
        # `sim_info.coverage.tool` is a Target — pull its executable for
        # the wrapper arg AND its default_runfiles so the whole tool
        # (launcher + interpreter + helper data) ships at test time. A
        # File would only carry the launcher and miss the venv_config /
        # interpreter / sibling .py files rules_venv-based binaries need
        # to start up.
        tool_exec = sim_info.coverage.tool[DefaultInfo].files_to_run.executable
        args.add("--coverage_tool={}".format(
            _rlocationpath(tool_exec, ctx.workspace_name),
        ))
        args.add("--coverage_data_glob={}".format(sim_info.coverage.data_glob))
        for a in sim_info.coverage.args:
            args.add("--coverage_arg={}".format(a))
        coverage_runfiles = ctx.runfiles(files = [tool_exec]).merge(
            sim_info.coverage.tool[DefaultInfo].default_runfiles,
        )

    args.add("--")
    args.add("--hdl_toplevel", hdl_toplevel)
    args.add("--hdl_toplevel_lang", hdl_toplevel_lang)
    if hdl_toplevel_library:
        args.add("--hdl_toplevel_library", hdl_toplevel_library)
    for src in sim_build_sources:
        args.add("--build_source={}".format(_rlocationpath(src, ctx.workspace_name)))
    for a in sim_build_args:
        args.add("--build_args={}".format(a))
    for a in sim_test_args:
        args.add("--test_args={}".format(a))
    if ctx.attr.params:
        args.add("--parameters")
        args.add_all(ctx.attr.params)

    args_file = ctx.actions.declare_file("{}.args.txt".format(ctx.label.name))
    ctx.actions.write(
        output = args_file,
        content = args,
    )

    dep_info = py_venv_common.create_dep_info(
        ctx = ctx,
        deps = [ctx.attr._runner] + ctx.attr.deps,
    )

    py_info = py_venv_common.create_py_info(
        ctx = ctx,
        imports = [],
        srcs = [ctx.file._runner_main] + ctx.files.srcs,
        dep_info = dep_info,
    )

    direct_runfiles = ctx.runfiles(
        files = sim_info.bins.values() + (
            [sim_bin] if sim_bin else []
        ) + [args_file] + ctx.files.srcs + ctx.files.data + [d for d, _ in precompiled_libs_info],
        transitive_files = sim_info.all_files,
    ).merge_all([
        dep_info.runfiles,
        sim_output.runfiles,
        coverage_runfiles,
    ] + [
        target[DefaultInfo].default_runfiles
        for target in ctx.attr.data
        if DefaultInfo in target
    ])

    executable, runfiles = py_venv_common.create_venv_entrypoint(
        ctx = ctx,
        venv_toolchain = venv_toolchain,
        py_info = py_info,
        main = ctx.file._runner_main,
        runfiles = direct_runfiles,
    )

    return [
        RunEnvironmentInfo(
            environment = expanded_user_env | {
                "COCOTB_TEST_ARGS_FILE": _rlocationpath(args_file, ctx.workspace_name),
            },
        ),
        DefaultInfo(
            executable = executable,
            files = depset([executable]),
            runfiles = runfiles,
        ),
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["module"],
            dependency_attributes = ["module"],
            extensions = ["vhd", "vhdl", "v", "sv", "vh", "svh"],
        ),
    ]

cocotb_test = rule(
    doc = "Run a test using `cocotb` on a given Verilog/VHDL module.",
    implementation = _cocotb_test_impl,
    attrs = {
        "data": attr.label_list(
            doc = "Additional runtime data used by the test.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "Python dependencies required by the test sources.",
            providers = [PyInfo],
        ),
        "env": attr.string_dict(
            doc = "Environment variables to set for the test.",
        ),
        "module": attr.label(
            doc = "The Verilog/VHDL module to test.",
            mandatory = True,
            providers = [[VerilogInfo], [VhdlInfo]],
        ),
        "params": attr.string_list(
            doc = "Verilog parameters or VHDL generics.",
        ),
        "precompiled_libs": attr.label_list(
            doc = ("Precompiled simulator library sets to link before the " +
                   "test's own compile step. Each target must produce a " +
                   "`CocotbPrecompiledLibraryInfo` whose `format` matches " +
                   "this test's resolved simulator's format family " +
                   "(analysis-time check). At runtime the per-format runner " +
                   "patch in `cocotb_process_wrapper` emits the vendor's " +
                   "link directive (`vmap -link` for Aldec, `-modelsimini` " +
                   "for Mentor, etc.) so DUT wrappers that reference " +
                   "libraries inside the precompiled set (e.g. Xilinx's " +
                   "`xil_defaultlib`) resolve."),
            providers = [CocotbPrecompiledLibraryInfo],
            default = [],
        ),
        "sim": attr.string(
            doc = "The name of the simulator to use. Must match a key in the cocotb_toolchain's `simulators` dict.",
        ),
        "sim_opts": attr.string_list(
            doc = "Additional command line arguments to pass only to the simulator during code-generation.",
        ),
        "srcs": attr.label_list(
            doc = "Sources containing the test code to run.",
            mandatory = True,
            allow_files = [".py"],
            allow_empty = False,
        ),
        "_runner": attr.label(
            doc = "The process wrapper for running cocotb tests.",
            default = Label("//tools/cocotb_process_wrapper"),
            providers = [PyInfo],
        ),
        "_runner_main": attr.label(
            doc = "The main entrypoint for the cocotb process.",
            allow_single_file = True,
            default = Label("//tools/cocotb_process_wrapper:cocotb_process_wrapper.py"),
        ),
    } | py_venv_common.create_venv_attrs(),
    toolchains = [
        "@rules_cc//cc:toolchain_type",
        "@rules_python//python/cc:toolchain_type",
        str(Label("//cocotb:toolchain_type")),
        py_venv_common.TOOLCHAIN_TYPE,
    ],
    fragments = ["cpp"],
    test = True,
)
