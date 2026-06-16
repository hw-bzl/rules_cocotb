"""Common utilties for cocotb simulator actions"""

# Shared `env` attribute used by every `cocotb_*_sim` rule. Surfaced on
# the rule's `CocotbSimInfo.env` field; consumed by `cocotb_test` when
# it builds the `--sim_env` list passed to the process wrapper. The doc
# describes the test-time precedence ordering.
SIM_ENV_ATTR = attr.string_dict(
    doc = (
        "Environment variables to set when the cocotb runner invokes " +
        "this simulator at test time (license-server pointers, install " +
        "root vars, …). Precedence: toolchain `env` < sim `env` < " +
        "rule-level `cocotb_test(env = ...)`."
    ),
    default = {},
)

CocotbSimOutputInfo = provider(
    doc = "Compiled simulator outputs.",
    fields = {
        "bin": "File-or-None: The pre-compiled executable artifact for cocotb to run. Set when the simulator integration pre-compiles at Bazel time (e.g. `cocotb_icarus_sim`/`cocotb_verilator_sim`). Leave unset for build-at-test-time rules — cocotb's `Runner.build()` will produce its own artifact under `test_dir`. When `bin` is set, cocotb's runner uses `bin.parent` as `build_dir` and finds the artifact at the simulator's conventional `sim_file` path (e.g. `sim.vvp`, `simv`, `<hdl_toplevel>`).",
        "build_args": "list[str]: Optional extra args forwarded to cocotb runner's `build_args` (per-simulator compile flags). Only relevant when `build_sources` is set.",
        "build_sources": "list[File]: Optional source files to (re)build at test time via `cocotb_tools.runner.Runner.build()`. Required for build-at-test-time rules (no pre-compiled `bin`) and for JIT-only simulators whose pre-built work libraries aren't relocatable (e.g. GHDL).",
        "runfiles": "Runfiles: The runfiles object carrying the artifacts and sources cocotb needs at test time.",
        "sim_env": """\
dict[str, str]: Optional environment variables to set when invoking cocotb's
runner at test time. Literal string values are set verbatim; values prefixed
with `abs:[upN:]<rlocationpath>` are resolved by the cocotb process wrapper
to an absolute filesystem path, optionally walking N parent directories up
(e.g. `abs:up3:ghdl+/vhdl_libs_v08/ieee/v08/ieee-obj08.cf` resolves to the
`vhdl_libs_v08` root directory).
""",
        "test_args": "list[str]: Optional extra args forwarded to cocotb runner's `test_args` (per-simulator command-line flags).",
    },
)

def _cocotb_sim_info_init(*, all_files, bins, compile, env = {}, coverage = None):
    return {
        "all_files": all_files,
        "bins": bins,
        "compile": compile,
        "coverage": coverage,
        "env": env,
    }

CocotbSimInfo, _ = provider(
    doc = """\
Common simulator interface required by the cocotb toolchain.

`CocotbSimInfo` is the *only* contract `cocotb_test` and `cocotb_toolchain`
depend on — any target that returns it can plug into the toolchain's
`simulators` dict. The shipped `cocotb_*_sim` rules each return one (plus
their own per-simulator extension provider, e.g. `CocotbSimGhdlInfo`), but
they aren't privileged in any way.

This is the public extension point for shipping a simulator the bundled
rules don't cover, or wrapping an install shape they don't fit (vendored
tarball, system `.deb`, internal corp build, ...). Write a Starlark rule
whose impl returns `CocotbSimInfo`, drop it into a `cocotb_toolchain`
under the simulator name of your choice, and `cocotb_test(sim = ...)`
resolves through it.

Simulator-specific providers (`CocotbSimGhdlInfo`, `CocotbSimIcarusInfo`,
etc.) are only consumed by the corresponding shipped `compile` function —
custom rules don't need to return them unless they want to reuse a
shipped `compile`.
""",
    init = _cocotb_sim_info_init,
    fields = {
        "all_files": "depset[File]: All transitive runfiles required by the simulator.",
        "bins": "dict[str, File]: Simulator binaries to place on PATH at test time. Keys are the expected binary names (e.g. {'verilator': <File>} or {'iverilog': <File>, 'vvp': <File>}).",
        "compile": "callable: A function with signature `compile(ctx, simulator, module, sim_opts) -> CocotbSimOutputInfo` that performs code-generation and compilation for this simulator.",
        "coverage": ("struct-or-None: Per-sim coverage bridge for " +
                     "`bazel coverage`. When set AND the test's compile " +
                     "step instrumented the sim binary (typically via " +
                     "`ctx.coverage_instrumented()`), the wrapper invokes " +
                     "the tool after `runner.test()` returns, producing " +
                     "lcov at `$COVERAGE_OUTPUT_FILE`. Fields:\n" +
                     "  * `tool` (Target): post-processor binary. The " +
                     "consumer pulls `[DefaultInfo].files_to_run.executable` " +
                     "for the wrapper arg AND `default_runfiles` so the " +
                     "launcher's interpreter + sibling data ship alongside " +
                     "the executable (lets py_venv-shaped binaries work, " +
                     "not just single-file native tools).\n" +
                     "  * `args` (list[str]): args template. `{output}` " +
                     "is substituted with `$COVERAGE_OUTPUT_FILE`; " +
                     "`{data_files}` is substituted with the absolute " +
                     "paths of files matching `data_glob` in the sim's " +
                     "build dir (one positional arg per file).\n" +
                     "  * `data_glob` (str): shell glob, relative to the " +
                     "sim's build dir, matching the raw coverage data " +
                     "file(s) the tool consumes.\n" +
                     "Verilator example: " +
                     "`struct(tool=verilator_coverage_target, " +
                     "args=['--write-info', '{output}', '{data_files}'], " +
                     "data_glob='coverage.dat')`. " +
                     "GHDL example: `struct(tool=ghdl_target, " +
                     "args=['coverage', '--format=lcov', '-o', '{output}', " +
                     "'{data_files}'], data_glob='*.cov')`. " +
                     "Sims that don't support coverage leave this None; " +
                     "the wrapper skips the bridge."),
        "env": "dict[str, str]: Environment variables this simulator needs when the cocotb runner invokes it at test time (e.g. license-server pointers, install-root vars). Surfaced from the sim rule's `env` attr; defaults to `{}` when a sim integration omits it. Precedence at test time: toolchain `env` < sim `env` < rule-level `cocotb_test(env = ...)`.",
    },
)
