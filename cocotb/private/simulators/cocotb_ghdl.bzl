"""Cocotb GHDL simulator integration"""

load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load(":cocotb_sim_utils.bzl", "CocotbSimInfo", "CocotbSimOutputInfo", "SIM_ENV_ATTR")

def _vhdl_lib_root_rloc(ctx, vhdl_libs):
    """Return a runtime rlocation spec for the VHDL library root.

    Picks any `.cf` file from `vhdl_libs` (laid out as
    `<root>/{std,ieee}/v<XX>/<name>.cf`) and returns its rlocationpath
    prefixed with `up3:` — the cocotb process wrapper resolves the runfile
    and walks 3 parent directories to land on `<root>`, which is what GHDL
    expects in `GHDL_PREFIX`.
    """
    for f in vhdl_libs.to_list():
        if not f.basename.endswith(".cf"):
            continue
        if f.short_path.startswith("../"):
            rloc = f.short_path[len("../"):]
        else:
            rloc = "{}/{}".format(ctx.workspace_name, f.short_path)
        return "up3:" + rloc
    return ""

CocotbSimGhdlInfo = provider(
    doc = "GHDL-specific extension of `CocotbSimInfo`.",
    fields = {
        "all_files": "depset[File]: All transitive runfiles required by the GHDL tools.",
        "ghdl": "File: The `ghdl` executable.",
        "ghdl_prefix": "str: Literal value to set as `GHDL_PREFIX` at sim time. Empty falls back to deriving from `vhdl_libs` (BCR layout) or to ghdl's compiled-in defaults.",
        "vhdl_libs": "depset[File]: Pre-compiled VHDL standard library files for GHDL_PREFIX (BCR-shaped layout).",
    },
)

def ghdl_compile(ctx, simulator, module, sim_opts):
    """Stage VHDL sources for a GHDL simulation at test time.

    No Bazel-time `ghdl -a` runs: the JIT backends (`mcode`, `llvm-jit`)
    bake absolute sandbox paths into the `.cf` metadata, so a
    sandbox-time work directory isn't usable at test time. Cocotb's
    runner re-runs `ghdl -a`/`-m`/`-r` against the source files via
    `Runner.build()` in a writable build_dir.

    Args:
        ctx (ctx): The rule's context object.
        simulator (Target): The `cocotb_ghdl_sim` target.
        module (Target): The VHDL module to compile (must provide `VhdlInfo`).
        sim_opts (list): Additional flags forwarded to cocotb's runner.

    Returns:
        CocotbSimOutputInfo: Provider with a stamp file and the sources
        cocotb's runner will (re)compile at test time.
    """
    sim_info = simulator[CocotbSimGhdlInfo]
    vhdl_info = module[VhdlInfo]

    all_srcs = vhdl_info.srcs
    all_data = vhdl_info.data

    sim_env = {}
    if sim_info.ghdl_prefix:
        # Literal path override — appropriate for system installs that know
        # their own prefix (e.g. "/usr/lib/ghdl" on a Debian system).
        sim_env["GHDL_PREFIX"] = sim_info.ghdl_prefix
    else:
        # Fall back to deriving GHDL_PREFIX from BCR-shaped `vhdl_libs`
        # (`<root>/{std,ieee}/v<XX>/...`). If `vhdl_libs` is empty, no
        # GHDL_PREFIX is set — ghdl uses its built-in defaults.
        lib_root_rloc = _vhdl_lib_root_rloc(ctx, sim_info.vhdl_libs)
        if lib_root_rloc:
            sim_env["GHDL_PREFIX"] = "abs:" + lib_root_rloc

    # Coverage instrumentation: when the DUT is under `bazel coverage`
    # AND this sim was configured with a `ghdl_coverage` post-processor
    # (i.e. the install is gcc-backed), tell cocotb's runner to pass
    # `--coverage` to both `ghdl -a` (so the work library carries
    # instrumentation) and `ghdl -r` (so the run emits coverage data).
    # The mcode/llvm-jit backends from the BCR `ghdl` module do NOT
    # implement `--coverage`; gating on `ghdl_coverage` being set
    # prevents `bazel coverage` from failing the build on those backends.
    common_args = ["--std=08"] + list(sim_opts)
    if (
        ctx.coverage_instrumented(module) and
        simulator[CocotbSimInfo].coverage
    ):
        common_args = common_args + ["--coverage"]

    return CocotbSimOutputInfo(
        runfiles = ctx.runfiles(
            transitive_files = depset(transitive = [all_srcs, all_data, sim_info.vhdl_libs]),
        ),
        sim_env = sim_env,
        test_args = common_args,
        build_args = common_args,
        build_sources = all_srcs.to_list(),
    )

def _cocotb_ghdl_sim_impl(ctx):
    vhdl_libs = depset(transitive = [t.files for t in ctx.attr.vhdl_libs])
    all_files = depset(
        transitive = [
            ctx.attr.ghdl[DefaultInfo].default_runfiles.files,
            vhdl_libs,
        ],
    )
    ghdl_exe = ctx.executable.ghdl

    # `ghdl coverage --format=lcov -o <out> <cov...>` translates
    # gcc-backed ghdl's coverage output to lcov directly. Wire the
    # bridge only when a `ghdl_coverage` target was supplied — the
    # BCR-default mcode/llvm-jit ghdl can't actually produce coverage
    # data, so leaving `ghdl_coverage` unset means `bazel coverage`
    # tests against this toolchain will report no HDL coverage rather
    # than failing on `ghdl --coverage`.
    coverage = None
    if ctx.attr.ghdl_coverage:
        coverage = struct(
            tool = ctx.attr.ghdl_coverage,
            args = ["coverage", "--format=lcov", "-o", "{output}", "{data_files}"],
            data_glob = "*.cov",
        )

    return [
        CocotbSimInfo(
            all_files = all_files,
            bins = {"ghdl": ghdl_exe},
            compile = ghdl_compile,
            env = ctx.attr.env,
            coverage = coverage,
        ),
        CocotbSimGhdlInfo(
            all_files = all_files,
            ghdl = ghdl_exe,
            ghdl_prefix = ctx.attr.ghdl_prefix,
            vhdl_libs = vhdl_libs,
        ),
    ]

cocotb_ghdl_sim = rule(
    doc = """\
A simulator configuration for running [GHDL](https://ghdl.github.io/ghdl/)
simulations in cocotb tests.

### Status

Working against the BCR `ghdl` module from version `6.0.0.bcr.1` onward,
which links the `ghdl` binary with `-Wl,--export-dynamic` and the
upstream `src/grt/grt.ver` version script so cocotb's
`libcocotbvpi_ghdl.so` can resolve unprefixed `vpi_*` symbols at dlopen
time. Earlier `ghdl@6.0.0` is missing those linker flags and fails at
sim time with `undefined symbol: vpi_register_cb`.

The backend is selectable with `--@ghdl//:backend={mcode, llvm-jit}`
(default `mcode` on x86_64, `llvm-jit` elsewhere).

### Notes

GHDL only supports VHDL (`VhdlInfo`); pair it with a `vhdl_library`
target as the `module`. The integration is build-at-test-time: cocotb's
runner runs `ghdl -a`/`-m` in a writable build_dir via
`Runner.build()`. Pre-compiling at Bazel time isn't viable because the
JIT backends bake absolute sandbox paths into the `.cf` files.

The `vhdl_libs` attribute should point at the pre-compiled IEEE/std
libraries from the BCR `ghdl` module — most projects want
`["@ghdl//:vhdl_libs_v08"]`.
""",
    implementation = _cocotb_ghdl_sim_impl,
    attrs = {
        "env": SIM_ENV_ATTR,
        "ghdl": attr.label(
            doc = "The `ghdl` binary.",
            executable = True,
            mandatory = True,
            cfg = "exec",
        ),
        "ghdl_coverage": attr.label(
            doc = ("The `ghdl` binary to invoke at test time under " +
                   "`bazel coverage` to translate `*.cov` files to lcov " +
                   "via `ghdl coverage --format=lcov`. Defaults to the " +
                   "same `ghdl` binary (target config so the runtime " +
                   "wrapper can invoke it). NOTE: requires a gcc-backed " +
                   "ghdl; the BCR mcode/llvm-jit backends don't " +
                   "produce coverage data."),
            executable = True,
            cfg = "target",
        ),
        "ghdl_prefix": attr.string(
            doc = """\
Literal value to set as `GHDL_PREFIX` at simulation time. Use this for
ghdl installs where the prefix is a stable absolute path on disk —
typically a system/`.deb`/Homebrew install (e.g. `"/usr/lib/ghdl"`).

When unset (default), `GHDL_PREFIX` is auto-derived from `vhdl_libs` if
it's populated (BCR-shaped layout), otherwise left unset so ghdl falls
back to its own compiled-in search paths.
""",
        ),
        "vhdl_libs": attr.label_list(
            doc = """\
Pre-compiled VHDL standard libraries (e.g. `@ghdl//:vhdl_libs_v08`).
**Assumes the BCR `ghdl` module's layout** —
`<root>/{std,ieee}/v<XX>/<name>-objXX.cf` — from which `GHDL_PREFIX`
is derived. If you ship ghdl differently and the IEEE/std libs are
already discoverable by the binary, leave this empty and (optionally)
set `ghdl_prefix` to a literal path, or skip both for a system install
that uses its compiled-in defaults.
""",
            allow_files = True,
            cfg = "exec",
        ),
    },
)
