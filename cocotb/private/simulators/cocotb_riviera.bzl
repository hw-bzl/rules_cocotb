"""Cocotb Aldec Riviera-PRO simulator integration"""

load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load(":cocotb_sim_utils.bzl", "CocotbSimInfo", "CocotbSimOutputInfo", "SIM_ENV_ATTR")

CocotbSimRivieraInfo = provider(
    doc = "Riviera-PRO-specific extension of `CocotbSimInfo`.",
    fields = {
        "all_files": "depset[File]: All transitive runfiles required by the Riviera-PRO tools.",
        "vsimsa": "File: The `vsimsa` standalone batch simulator executable. Cocotb's Riviera runner only ever invokes vsimsa as a subprocess; the other Aldec engines (alib/alog/acom/asim) are loaded internally by vsimsa via `$RIVIERA_HOME/bin/` and don't need PATH wiring.",
    },
)

def riviera_compile(ctx, simulator, module, sim_opts):
    """Stage HDL sources for a Riviera-PRO simulation at test time.

    No Bazel-time `alib` / `alog` / `acom` runs — the simulator is
    commercial and not generally available in CI. The cocotb runner
    drives the full build/sim flow at test time via `Runner.build()`.

    Args:
        ctx (ctx): The rule's context object.
        simulator (Target): The `cocotb_riviera_sim` target.
        module (Target): The HDL module (`VerilogInfo` or `VhdlInfo`).
        sim_opts (list): Additional flags forwarded to cocotb's runner.

    Returns:
        CocotbSimOutputInfo: Provider with a stamp file and the sources
        cocotb's runner will (re)compile at test time.
    """
    sim_info = simulator[CocotbSimRivieraInfo]
    if not sim_info.vsimsa:
        fail("cocotb_riviera_sim requires a vsimsa binary")

    # Walk transitive deps so cocotb's runner.build() compiles every package
    # the module's wrapper references via `library X; use X.pkg.all`. Without
    # this, `acom` of the wrapper fails with `Cannot find context item`
    # because deps' .vhd files were never compiled into the work library.
    # Build_sources is dep-first ordered (depset default `topological`), so
    # VHDL package compile order is naturally satisfied.
    src_depsets = []
    data_depsets = []
    if VerilogInfo in module:
        info = module[VerilogInfo]
        for dep_info in info.deps.to_list():
            src_depsets.append(dep_info.srcs)
            src_depsets.append(dep_info.hdrs)
            data_depsets.append(dep_info.data)
        src_depsets.append(info.srcs)
        src_depsets.append(info.hdrs)
        data_depsets.append(info.data)
    elif VhdlInfo in module:
        info = module[VhdlInfo]
        for dep_info in info.deps.to_list():
            src_depsets.append(dep_info.srcs)
            data_depsets.append(dep_info.data)
        src_depsets.append(info.srcs)
        data_depsets.append(info.data)
    else:
        fail("Module must provide VerilogInfo or VhdlInfo")

    all_srcs = depset(transitive = src_depsets)
    all_data = depset(transitive = data_depsets)

    # Coverage instrumentation. When the HDL module is exercised under
    # `bazel coverage`, fold the Aldec coverage flags into the runner's
    # build_args / test_args so:
    #   * acom/alog instrument each source (per-file `-coverage <kinds>`)
    #   * asim records hit counts into ACDB at runtime (`-acdb_cov <kinds>`)
    # Kinds: s=statement, b=branch, e=expression, c=condition, a=assertion,
    # m=FSM. The post-process tool from
    # `simulator[CocotbSimInfo].coverage` consumes whichever ACDBs end
    # up in the runner's results dir.
    build_args = list(sim_opts)
    test_args = []
    if ctx.coverage_instrumented(module):
        build_args.extend(["-coverage", "sbecam"])

        # `-acdb_cov` enables collection; `-acdb_file` is required for
        # asim to actually persist the ACDB on disk (otherwise the data
        # stays in memory and is lost at process exit). Relative path
        # lands in asim's cwd, which cocotb's runner sets to the test's
        # results dir — exactly where the wrapper's `coverage_data_glob`
        # searches.
        test_args.extend(["-acdb_cov", "sbecam", "-acdb_file", "coverage.acdb"])

    return CocotbSimOutputInfo(
        runfiles = ctx.runfiles(
            transitive_files = depset(transitive = [all_srcs, all_data]),
        ),
        build_args = build_args,
        test_args = test_args,
        build_sources = all_srcs.to_list(),
    )

def _cocotb_riviera_sim_impl(ctx):
    all_files = ctx.attr.vsimsa[DefaultInfo].default_runfiles.files

    vsimsa_exe = ctx.executable.vsimsa

    # Coverage post-processor — emitted as the `CocotbSimInfo.coverage`
    # struct the rules_cocotb wrapper consumes. Only populated when the
    # rule's `coverage_tool` attr is set; consumers that don't ship a
    # converter omit it and `bazel coverage` produces baseline-only LCOV.
    # `tool` is the Target (not the File): the consumer pulls
    # `[DefaultInfo].files_to_run.executable` for the wrapper arg AND
    # `default_runfiles` so the launcher's interpreter + sibling data
    # ship alongside the executable.
    coverage_struct = None
    if ctx.attr.coverage_tool:
        coverage_struct = struct(
            tool = ctx.attr.coverage_tool,
            data_glob = ctx.attr.coverage_data_glob,
            args = list(ctx.attr.coverage_args),
        )

    return [
        CocotbSimInfo(
            all_files = all_files,
            bins = {
                "vsimsa": vsimsa_exe,
            },
            compile = riviera_compile,
            coverage = coverage_struct,
            env = ctx.attr.env,
        ),
        CocotbSimRivieraInfo(
            all_files = all_files,
            vsimsa = vsimsa_exe,
        ),
    ]

cocotb_riviera_sim = rule(
    doc = """\
A simulator configuration for running Aldec Riviera-PRO simulations in
cocotb tests.

### Status

Infrastructure only. Riviera-PRO is commercial, with no BCR module and
no redistributable binary; `rules_cocotb` cannot validate this rule in
CI. Wire it up downstream by pointing the binary attrs at your own
install and registering a `cocotb_toolchain` that routes
`sim = "riviera"` through this rule. Cocotb's runner handles the
actual build/sim via `Runner.build` / `Runner.test`.

### Downstream wiring

Expose `vsimsa` to Bazel and register a custom `cocotb_toolchain`.
`vsimsa` is the only binary cocotb's Riviera runner invokes; the rest
of the Aldec install (alib/alog/acom/asim engines, libraries, license
config) is loaded internally by vsimsa through `$RIVIERA_HOME`. Pull
those into the action sandbox by attaching them as `data` on the
`vsimsa` target — anything reachable through its runfiles will be
staged alongside the binary.

Typically this means a local repository (e.g. `new_local_repository`
or a custom repository rule pointed at `$RIVIERA_HOME`) whose
`BUILD.bazel` wraps `vsimsa` as a `native_binary` (or `sh_binary`)
target with the rest of the install as its `data` deps, then:

```python
load("@rules_cocotb//cocotb:cocotb_riviera_sim.bzl", "cocotb_riviera_sim")
load("@rules_cocotb//cocotb:cocotb_toolchain.bzl", "cocotb_toolchain")

cocotb_riviera_sim(
    name = "cocotb_riviera",
    vsimsa = "@riviera//:vsimsa",
)

cocotb_toolchain(
    name = "my_cocotb_toolchain",
    cocotb = "//path/to:cocotb_py_library",
    simulators = {":cocotb_riviera": "riviera"},
)
```

Then `register_toolchains("//path/to:my_cocotb_toolchain")` in
`MODULE.bazel` (ahead of the default `//cocotb/toolchain` registration)
and `cocotb_test(sim = "riviera", ...)` will resolve through it.

Riviera-PRO accepts both Verilog/SystemVerilog (`VerilogInfo`) and VHDL
(`VhdlInfo`) modules.
""",
    implementation = _cocotb_riviera_sim_impl,
    attrs = {
        "coverage_args": attr.string_list(
            doc = ("Template fragments forwarded to `coverage_tool` after " +
                   "the cocotb runner exits under `bazel coverage`. " +
                   "`{output}` is substituted with `$COVERAGE_OUTPUT_FILE`; " +
                   "`{data_files}` is expanded into one positional arg per " +
                   "file matched by `coverage_data_glob`. Only meaningful " +
                   "when `coverage_tool` is set."),
            default = [],
        ),
        "coverage_data_glob": attr.string(
            doc = ("Shell glob (relative to the cocotb sim's build dir) " +
                   "selecting the raw coverage data files `coverage_tool` " +
                   "consumes. For Riviera-PRO, `**/coverage.acdb` matches " +
                   "every per-test ACDB the run produces. Only meaningful " +
                   "when `coverage_tool` is set."),
            default = "",
        ),
        "coverage_tool": attr.label(
            doc = ("Optional Riviera coverage post-processor. When set AND " +
                   "the test's HDL module is exercised under " +
                   "`bazel coverage` (via `ctx.coverage_instrumented(module)`), " +
                   "the rules_cocotb process wrapper invokes this binary " +
                   "after the cocotb runner exits with the `coverage_args` " +
                   "template (substituting `{output}` and `{data_files}`) " +
                   "so it can translate the raw ACDBs into lcov at " +
                   "`$COVERAGE_OUTPUT_FILE`. Leave unset to ship raw ACDBs " +
                   "under the test outputs dir without an lcov roll-up."),
            executable = True,
            cfg = "exec",
        ),
        "env": SIM_ENV_ATTR,
        "vsimsa": attr.label(
            doc = (
                "The `vsimsa` standalone batch simulator binary. " +
                "Cocotb's Riviera runner invokes only `vsimsa`; the rest " +
                "of the Aldec install (alib/alog/acom/asim engines, " +
                "libraries, license config) is loaded internally by " +
                "vsimsa via `$RIVIERA_HOME`. Attach those install files " +
                "as `data` deps on the target you pass here so they're " +
                "staged alongside the binary."
            ),
            executable = True,
            mandatory = True,
            cfg = "exec",
        ),
    },
)
