"""Cocotb Verilator simulator integration"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load(":cocotb_sim_utils.bzl", "CocotbSimInfo", "CocotbSimOutputInfo", "SIM_ENV_ATTR")

CocotbSimVerilatorInfo = provider(
    doc = "Verilator-specific extension of `CocotbSimInfo`.",
    fields = {
        "all_files": "depset[File]: All transitive runfiles required by `simulator`.",
        "cc_deps": "list[CcInfo]: Pre-resolved CcInfo providers to link into all verilator executables (cocotb VPI libs + user deps).",
        "copy_tree": "FilesToRunProvider: A tool for copying a tree of files.",
        "coverage_tool": "File: `verilator_coverage_bin` — invoked at test time to translate Verilator's `coverage.dat` into lcov for `bazel coverage`.",
        "main": "File: The cocotb entrypoint to use (typically `verilator.cpp` from cocotb).",
        "process_wrapper": "FilesToRunProvider: A process wrapper for verilator.",
        "simulator": "File: The verilator executable.",
    },
)

_CPP_SRC = ["cc", "cpp", "cxx", "c++"]
_HPP_SRC = ["h", "hh", "hpp"]

_VERILATOR_MAIN_SUFFIX = "share/lib/verilator/verilator.cpp"

# Cocotb wheel paths for its GPI shared libraries. Bases are stripped of
# the `lib` prefix and the platform extension, both of which vary by
# wheel — `cocotb_tools/config.py` picks them at runtime via the same
# logic `_find_cocotb_lib()` mirrors here.
_COCOTB_VPI_LIB_BASE = "cocotbvpi_verilator"
_COCOTB_CORE_LIB_BASES = [
    "cocotb",
    "cocotbutils",
    "embed",
    "gpi",
    "gpilog",
    "pygpilog",
]

# Candidate `<prefix><base><ext>` shapes a cocotb wheel may ship its GPI
# libs under, in priority order. Mirrors `cocotb_tools.config.lib_name`:
#   * POSIX (Linux / macOS): `lib<base>.so`
#   * Windows MinGW build:   `lib<base>.dll`
#   * Windows MSVC build:    `<base>.dll` (no `lib` prefix; cocotb's
#     config sniffs `cocotb.dll`'s existence to pick this)
# We don't know at analysis time which wheel ships in `cocotb_pkg_files`,
# so try all three and take the first match.
_COCOTB_LIB_VARIANTS = [
    ("lib", ".so"),
    ("lib", ".dll"),
    ("", ".dll"),
]

def _only_cpp(f):
    if f.extension in _CPP_SRC + _HPP_SRC:
        return f.path
    return None

def _only_hpp(f):
    if f.extension in _HPP_SRC:
        return f.path
    return None

def _all_package_files(target):
    info = target[DefaultInfo]
    files = info.files.to_list()
    if info.default_runfiles:
        files = files + info.default_runfiles.files.to_list()
    return files

def _find_one(files, suffix, owner):
    for f in files:
        if f.path.endswith(suffix):
            return f
    fail("Could not find '{}' in {}".format(suffix, owner))

def _find_cocotb_lib(files, base, owner):
    """Find a cocotb GPI shared library by base name.

    Tries each known `<prefix><base><ext>` variant a cocotb wheel may
    use (POSIX, Windows MinGW, Windows MSVC) and returns the first match.

    Args:
        files: list[File] from `_all_package_files()`.
        base: bare library name (e.g. `cocotb`, `gpi`, `cocotbvpi_verilator`).
        owner: Label of the owning target, for error messages.

    Returns:
        The matched File.
    """
    for prefix, ext in _COCOTB_LIB_VARIANTS:
        suffix = "libs/{}{}{}".format(prefix, base, ext)
        for f in files:
            if f.path.endswith(suffix):
                return f
    fail("Could not find cocotb library {} (tried {}) in {}".format(
        base,
        ", ".join(["{}{}{}".format(p, base, e) for p, e in _COCOTB_LIB_VARIANTS]),
        owner,
    ))

def _cc_import_for(ctx, files):
    """Wrap a list of .so files in a CcInfo linking_context."""
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    libraries = [
        cc_common.create_library_to_link(
            actions = ctx.actions,
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
            dynamic_library = f,
        )
        for f in files
    ]
    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset(libraries),
    )
    return CcInfo(
        linking_context = cc_common.create_linking_context(
            linker_inputs = depset([linker_input]),
        ),
    )

def verilator_compile(ctx, simulator, module, sim_opts):
    """Compile a verilator executable wired against cocotb's VPI plugin.

    Args:
        ctx (ctx): The rule's context object.
        simulator (Target): The `cocotb_verilator_sim` target.
        module (Target): The Verilog/SystemVerilog module to compile.
        sim_opts (list): Dedicated flags for verilator.

    Returns:
        CocotbSimOutputInfo: Provider with the compiled binary and runfiles.
    """
    sim_info = simulator[CocotbSimVerilatorInfo]
    verilog_info = module[VerilogInfo]
    all_srcs = verilog_info.srcs
    all_data = verilog_info.data

    module_top = module.label.name

    verilator_output = ctx.actions.declare_directory(
        "{}.verilator/{}.build".format(ctx.label.name, module_top),
    )

    args = ctx.actions.args()
    args.add(sim_info.simulator)
    args.add("--no-std")
    args.add("--cc")
    args.add("--exe")
    args.add("--Mdir", verilator_output.path)
    args.add("-DCOCOTB_SIM=1")
    args.add("--top-module", module_top)
    args.add_all(ctx.attr.params, format_each = "-G%s")
    args.add("--vpi")
    args.add("--public-flat-rw")
    args.add("--prefix", "Vtop")
    args.add("-o", module_top)

    # Instrument for line/toggle/user coverage when the DUT is being
    # analysed under `bazel coverage`. `ctx.coverage_instrumented()`
    # with no arg checks the test rule itself (typically False); the
    # `module` dep is what carries `InstrumentedFilesInfo`, so probe
    # there. The runtime cost is collected into `coverage.dat` in the
    # sim's cwd; `verilator_coverage_bin` translates that to lcov which
    # the wrapper writes to `COVERAGE_OUTPUT_FILE`.
    if ctx.coverage_instrumented(module):
        args.add("--coverage-line")
        args.add("--coverage-toggle")
        args.add("--coverage-user")

    args.add(sim_info.main)
    args.add_all(all_srcs)
    args.add_all(sim_opts)

    ctx.actions.run(
        arguments = [args],
        mnemonic = "CocotbVerilatorCompile",
        executable = sim_info.process_wrapper.executable,
        inputs = depset([sim_info.main], transitive = [all_srcs, all_data]),
        outputs = [verilator_output],
        tools = [sim_info.process_wrapper, sim_info.all_files],
    )

    verilator_output_cpp = ctx.actions.declare_directory(
        "{}.verilator/{}.srcs".format(ctx.label.name, module_top),
    )
    verilator_output_hpp = ctx.actions.declare_directory(
        "{}.verilator/{}.hdrs".format(ctx.label.name, module_top),
    )

    cp_args = ctx.actions.args()
    cp_args.add(verilator_output_cpp.path, format = "--src_output=%s")
    cp_args.add(verilator_output_hpp.path, format = "--hdr_output=%s")
    cp_args.add(sim_info.main, format = "--src=%s")
    cp_args.add_all([verilator_output], map_each = _only_cpp, format_each = "--src=%s")
    cp_args.add_all([verilator_output], map_each = _only_hpp, format_each = "--hdr=%s")

    ctx.actions.run(
        mnemonic = "CocotbVerilatorCopyTree",
        arguments = [cp_args],
        inputs = [verilator_output, sim_info.main],
        outputs = [verilator_output_cpp, verilator_output_hpp],
        executable = sim_info.copy_tree.executable,
        tools = [sim_info.copy_tree],
    )

    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    defines = {"COCOTB_SIM": "1"}
    if "--trace" in sim_opts:
        defines.update({
            "VM_TRACE": "1",
            "VM_TRACE_FST": "0",
            "VM_TRACE_VCD": "1",
        })
    if "--trace-fst" in sim_opts:
        defines.update({
            "VM_TRACE": "1",
            "VM_TRACE_FST": "1",
            "VM_TRACE_VCD": "0",
        })
    if "VM_TRACE_FST" in defines:
        defines.update({"VM_TRACE_VCD": "1"})

    # When verilator is invoked with `--coverage-*`, it generates an
    # instrumented model — but cocotb's `verilator.cpp` only calls
    # `VerilatedCov::write()` under `#if VM_COVERAGE`. Verilator's own
    # generated headers set `VM_COVERAGE` when its `--coverage-*` flags
    # were passed; mirror that here so the cocotb-side `verilator.cpp`
    # wrapper actually writes `coverage.dat` at sim exit.
    if ctx.coverage_instrumented(module):
        defines["VM_COVERAGE"] = "1"

    compilation_contexts = [dep.compilation_context for dep in sim_info.cc_deps]
    _compilation_context, compilation_outputs = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = [],
        srcs = [verilator_output_cpp],
        includes = [verilator_output_hpp.path],
        defines = ["{}={}".format(k, v) for k, v in defines.items()],
        public_hdrs = [verilator_output_hpp],
        compilation_contexts = compilation_contexts,
    )

    linking_contexts = [dep.linking_context for dep in sim_info.cc_deps]

    py_cc_toolchain = ctx.toolchains["@rules_python//python/cc:toolchain_type"].py_cc_toolchain
    for info_id, info in py_cc_toolchain.libs.providers_map.items():
        if info_id == "CcInfo":
            linking_contexts.append(info.linking_context)

    linking_output = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        name = "{}.verilator/{}".format(ctx.label.name, module_top),
        link_deps_statically = False,
    )

    dynamic_libs = []
    for context in linking_contexts:
        for inputs in context.linker_inputs.to_list():
            for lib in inputs.libraries:
                if lib.dynamic_library:
                    dynamic_libs.append(lib.dynamic_library)

    return CocotbSimOutputInfo(
        bin = linking_output.executable,
        runfiles = ctx.runfiles(files = dynamic_libs, transitive_files = all_data),
    )

def _cocotb_verilator_sim_impl(ctx):
    cocotb_pkg_files = _all_package_files(ctx.attr.cocotb)
    cocotb_label = ctx.attr.cocotb.label

    main = _find_one(cocotb_pkg_files, _VERILATOR_MAIN_SUFFIX, cocotb_label)
    vpi_libs = [_find_cocotb_lib(cocotb_pkg_files, _COCOTB_VPI_LIB_BASE, cocotb_label)]
    core_libs = [_find_cocotb_lib(cocotb_pkg_files, b, cocotb_label) for b in _COCOTB_CORE_LIB_BASES]
    cocotb_so_files = vpi_libs + core_libs

    # Wrap the verilated VPI .so and the cocotb core .so set in CcInfo
    # linking_contexts so they're linked into the verilator binary +
    # carried along as dynamic-library runfiles. Also link `@verilator//:verilated`
    # via the user-facing `deps` attr so simple bumps to the verilator
    # version don't require editing this rule.
    cc_deps = [
        _cc_import_for(ctx, vpi_libs),
        _cc_import_for(ctx, core_libs),
    ] + [dep[CcInfo] for dep in ctx.attr.deps]

    all_files = depset(
        cocotb_so_files + [main],
        transitive = [
            ctx.attr.verilator[DefaultInfo].default_runfiles.files,
        ],
    )
    verilator_exe = ctx.executable.verilator

    return [
        CocotbSimInfo(
            all_files = all_files,
            bins = {"verilator": verilator_exe},
            compile = verilator_compile,
            env = ctx.attr.env,
            # Verilator dumps `coverage.dat` in the sim's cwd when the
            # binary was compiled with `--coverage-*` (gated on
            # `ctx.coverage_instrumented()` in `verilator_compile`).
            # `verilator_coverage_bin --write-info <out> <dat>` then
            # produces lcov directly.
            coverage = struct(
                tool = ctx.attr.verilator_coverage,
                args = ["--write-info", "{output}", "{data_files}"],
                data_glob = "coverage.dat",
            ),
        ),
        CocotbSimVerilatorInfo(
            all_files = all_files,
            cc_deps = cc_deps,
            copy_tree = ctx.attr.copy_tree[DefaultInfo].files_to_run,
            coverage_tool = ctx.executable.verilator_coverage,
            main = main,
            process_wrapper = ctx.attr.process_wrapper[DefaultInfo].files_to_run,
            simulator = verilator_exe,
        ),
    ]

cocotb_verilator_sim = rule(
    doc = """\
A simulator configuration for compiling [Verilator](https://verilator.org/)
binaries to be run in cocotb tests.

### Status

Fully functional. Sourced from the `verilator` and `rules_verilator` BCR
modules; the default toolchain wires `@verilator//:verilator_executable`
together with cocotb's `share/lib/verilator/verilator.cpp` entrypoint.
Used by the in-tree `adder_test` smoke test, which passes end-to-end.

### Notes

Verilator only supports Verilog/SystemVerilog (`VerilogInfo`); pair it
with a `verilog_library` target as the `module`. The `sim_opts`
attribute on `cocotb_test` is forwarded to the underlying `verilator`
invocation — e.g. `sim_opts = ["--trace-fst"]` enables FST waveform
capture.

The BCR verilator binary needs the `rules_verilator` process wrapper
to set up its include / lib paths, and cocotb's `verilator.cpp`
front-end plus its VPI shared libraries to link against. The rule
locates those inside the cocotb pip wheel automatically — point
`cocotb` at any `py_library` wrapping `@cocotb_pip_deps//cocotb` and
the rule extracts what it needs internally.
""",
    implementation = _cocotb_verilator_sim_impl,
    attrs = {
        "cocotb": attr.label(
            doc = "The cocotb pip package (a `py_library` wrapping `@cocotb_pip_deps//cocotb`). Used to extract `verilator.cpp` and the cocotb VPI shared libraries.",
            mandatory = True,
        ),
        "copy_tree": attr.label(
            doc = "A tool for copying a tree of files. Defaults to the `rules_verilator` helper.",
            cfg = "exec",
            executable = True,
            default = Label("@rules_verilator//verilator/private:verilator_copy_tree"),
        ),
        "deps": attr.label_list(
            doc = "Additional `CcInfo`-providing dependencies to link into the verilator executable (e.g. `@verilator//:verilated` and your project's C++ shims).",
            providers = [CcInfo],
        ),
        "env": SIM_ENV_ATTR,
        "process_wrapper": attr.label(
            doc = "A process wrapper for verilator. Defaults to the `rules_verilator` helper.",
            cfg = "exec",
            executable = True,
            default = Label("@rules_verilator//verilator/private:verilator_process_wrapper"),
        ),
        "verilator": attr.label(
            doc = "The Verilator binary to use (e.g. `@verilator//:verilator_executable`).",
            executable = True,
            mandatory = True,
            cfg = "exec",
        ),
        "verilator_coverage": attr.label(
            doc = ("`verilator_coverage_bin` — invoked at test time under " +
                   "`bazel coverage` to translate `coverage.dat` into lcov."),
            default = Label("@verilator//:verilator_coverage_executable"),
            executable = True,
            cfg = "target",
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    fragments = ["cpp"],
)
