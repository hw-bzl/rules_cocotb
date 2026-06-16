"""cocotb process wrapper

This script is only intended to be invoked by the `cocotb_test` Bazel rule.
"""

# pylint: disable=too-many-lines

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import warnings
from pathlib import Path
from typing import Any, NamedTuple, Optional, Sequence, Tuple, Union
from xml.etree import ElementTree

from python.runfiles import Runfiles

COCOTB_PROCESS_WRAPPER = "COCOTB_PROCESS_WRAPPER"
COCOTB_TEST_ARGS_FILE = "COCOTB_TEST_ARGS_FILE"
COCOTB_TEST_SUBPROCESS_ARGS_FILE = "COCOTB_TEST_SUBPROCESS_ARGS_FILE"

# cocotb simulator name -> precompiled-library format family. Mirrors the
# `_SIM_FORMAT` constant in `cocotb/private/cocotb_test.bzl` — keep them in
# sync. Sims without a precompiled-library concept (icarus, verilator, ghdl,
# nvc) are intentionally absent.
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


def _find_runfile(runfiles: Runfiles, rlocationpath: str) -> Path:
    """A convinenice method for locating runfiles and ensuring they point to real files

    Args:
        runfiles: A Runfiles object.
        rlocationpath: The runfile to look up

    Returns:
        The path to the runfile.
    """
    runfile = runfiles.Rlocation(rlocationpath)
    if not runfile:
        raise FileNotFoundError(f"Runfile not found: {rlocationpath}")
    path = Path(runfile)
    if not path.exists():
        raise FileNotFoundError(f"Runfile does not exist: {path}")
    return path


def _parse_named_binary(value: str) -> Tuple[str, str]:
    """Parse a `name:rlocationpath` pair for a simulator binary.

    Args:
        value: The command line arg value in `name:rlocationpath` format.

    Returns:
        The binary name and its `rlocationpath`.
    """
    name, _, path = value.partition(":")
    return name, path


def _parse_precompiled_lib(value: str) -> Tuple[str, str, str]:
    """Parse a `<format>:<vendor>:<rlocationpath>` precompiled-library-dir arg.

    `<vendor>` may be empty (`aldec::path/to/lib`) for bundles without
    ecosystem quirks.

    Args:
        value: The command line arg value.

    Returns:
        The (format, vendor, rlocationpath) triple.
    """
    fmt, _, rest = value.partition(":")
    vendor, _, rloc = rest.partition(":")
    if not fmt or not rloc:
        raise ValueError(
            f"--precompiled_lib_dir expects `<format>:<vendor>:<rlocationpath>`, got {value!r}"
        )
    return fmt, vendor, rloc


def parse_args(args: Sequence[str]) -> argparse.Namespace:
    """Parse command line arguments"""

    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--test",
        dest="tests",
        type=str,
        default=[],
        action="append",
        required=True,
        help="Test sources for cocotb.",
    )
    parser.add_argument(
        "--sim",
        type=str,
        required=True,
        help="The simulator name (e.g. 'verilator', 'icarus').",
    )
    parser.add_argument(
        "--sim_bin",
        dest="sim_bins",
        type=_parse_named_binary,
        default=[],
        action="append",
        help="Named simulator binary as `name:rlocationpath`. May be repeated.",
    )
    parser.add_argument(
        "--sim_env",
        dest="sim_envs",
        type=str,
        default=[],
        action="append",
        help=(
            "Simulator-supplied env var as `NAME=VALUE`. The value may be a "
            "literal string, or prefixed with `abs:<rlocationpath>` to set "
            "NAME to the absolute filesystem path of that runfile. Repeatable."
        ),
    )
    parser.add_argument(
        "--bin",
        type=str,
        default=None,
        help=(
            "Optional pre-compiled simulator artifact. When set, `build_dir` "
            "is its parent directory and cocotb's runner finds the artifact "
            "at the simulator's conventional `sim_file` path. When unset, "
            "cocotb's runner builds inside `test_dir` from `--build_source` "
            "inputs."
        ),
    )
    parser.add_argument(
        "--workspace_name",
        type=str,
        required=True,
        help="The name of the current Bazel workspace.",
    )
    parser.add_argument(
        "--precompiled_lib_dir",
        dest="precompiled_lib_dirs",
        type=_parse_precompiled_lib,
        default=[],
        action="append",
        help=(
            "Precompiled library set as `<format>:<vendor>:<rlocationpath>`. "
            "`<format>` is the vendor format family "
            "(aldec/mentor/synopsys/cadence/xilinx). `<vendor>` is an "
            "optional ecosystem id (`xilinx` for Vivado export; empty for "
            "vanilla bundles). `<rlocationpath>` points at a TreeArtifact "
            "whose root holds that format's link-config file (aldec: "
            "./library.cfg; mentor: ./modelsim.ini; etc.). The wrapper "
            "patches the per-format cocotb runner to emit the appropriate "
            "link directive (`vmap -link` for aldec, etc.) before cocotb's "
            "own compile step, then applies any vendor quirks additively. "
            "Repeatable."
        ),
    )
    parser.add_argument(
        "--coverage_tool",
        type=str,
        default=None,
        help=(
            "Rlocationpath of the sim's coverage post-processor. When set "
            "AND the test was launched under `bazel coverage` (i.e. "
            "`COVERAGE_OUTPUT_FILE` is in env), the wrapper runs "
            "`<tool> --write-info $COVERAGE_OUTPUT_FILE <data-files>` after "
            "`runner.test()` returns. `<data-files>` are the matches of "
            "`--coverage_data_glob` resolved against the sim's build dir."
        ),
    )
    parser.add_argument(
        "--coverage_data_glob",
        type=str,
        default=None,
        help=(
            "Shell glob (relative to the sim's build dir) selecting the "
            "raw coverage data file(s) the `--coverage_tool` consumes. "
            "E.g. Verilator emits `coverage.dat`."
        ),
    )
    parser.add_argument(
        "--coverage_arg",
        dest="coverage_args",
        type=str,
        default=[],
        action="append",
        help=(
            "Arg template fragment for invoking `--coverage_tool`. "
            "`{output}` is substituted with `$COVERAGE_OUTPUT_FILE`; "
            "`{data_files}` is expanded into one positional arg per file "
            "matched by `--coverage_data_glob`. Repeatable."
        ),
    )
    parser.add_argument(
        "cocotb_args",
        nargs="*",
        help="Remaining arguments to forward to cocotb.",
    )

    return parser.parse_args(args)


def _process_test_outputs(test_dir: Path) -> None:
    """Wire any test outputs into the appropriate location for Bazel tests."""

    if "TEST_UNDECLARED_OUTPUTS_DIR" in os.environ:
        outputs_dir = Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"])

        outputs = []
        for log in ("dump.fst", "dump.vcd"):
            log_path = test_dir / log
            if log_path.exists():
                outputs.append(log_path)

        if outputs:
            outputs_dir.mkdir(exist_ok=True, parents=True)
            for output in outputs:
                shutil.copy(output, outputs_dir / output.name)

    if "XML_OUTPUT_FILE" in os.environ:
        results_file = test_dir / "results.xml"
        if results_file.exists():
            shutil.copy(results_file, os.environ["XML_OUTPUT_FILE"])


# pylint: disable-next=too-many-locals,too-many-statements,too-many-branches
def main() -> None:
    """The main entrypoint."""
    if COCOTB_TEST_ARGS_FILE not in os.environ:
        raise EnvironmentError(f"`{COCOTB_TEST_ARGS_FILE}` was not found in environment.")

    # Construct runfiles so we can find test inputs
    runfiles = Runfiles.Create()
    if not runfiles:
        raise EnvironmentError("Failed to locate runfiles.")

    args_file = _find_runfile(runfiles, os.environ[COCOTB_TEST_ARGS_FILE])
    args = parse_args(args_file.read_text(encoding="utf-8").splitlines() + sys.argv[1:])

    # Prepare the environment for the cocotb subprocess
    env = dict(os.environ)
    env[COCOTB_PROCESS_WRAPPER] = __file__
    env.update(runfiles.EnvVars())

    # `bazel coverage` sets `COVERAGE=1` to signal coverage mode.
    # Cocotb's `_start_user_coverage` reads that as a legacy fallback
    # for `COCOTB_USER_COVERAGE` and tries to auto-import the `coverage`
    # pip package — which crashes the test if `coverage` isn't in the
    # cocotb_pip_deps. We only care about *HDL* coverage here (handled
    # via `--coverage_tool` post-processing below), not Python user
    # coverage, so clear `COVERAGE` from the subprocess env. The outer
    # wrapper keeps `COVERAGE_OUTPUT_FILE` / `COVERAGE_MANIFEST` /
    # `COVERAGE_DIR` in its own env for the post-test step.
    env.pop("COVERAGE", None)

    # Generate a safe directory for the test to write outputs to. Note that this
    # directory is not cleaned up by this process wrapper. Instead, this cleanup
    # is deferred to Bazel.
    tmp_dir = tempfile.mkdtemp(dir=os.getenv("TEST_TMPDIR"), prefix="cocotb_test-")
    tmp_path = Path(tmp_dir)

    # Ensure no caching occurs in the users home directory.
    home_dir = tmp_path / "home"
    home_dir.mkdir(exist_ok=True, parents=True)
    env["HOME"] = str(home_dir)
    Path(env["HOME"]).mkdir(exist_ok=True, parents=True)

    # Cocotb expects the simulator to be available via PATH so
    # it must be injected into the environment before running
    # the tests.
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True, parents=True)
    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")

    # Cocotb is also extremely particular about the binary names since
    # it's relying on `PATH` to find them. Simulators must be uniquely
    # symlinked to achieve this as it's not guaranteed that the Bazel
    # target will have the appropriate name.
    sim_name = args.sim
    for bin_name, bin_rlocationpath in args.sim_bins:
        sim_bin = _find_runfile(runfiles, bin_rlocationpath)
        symlink = bin_dir / bin_name
        symlink.symlink_to(sim_bin)

    for entry in args.sim_envs:
        name, _, value = entry.partition("=")
        if value.startswith("abs:"):
            spec = value[len("abs:") :]
            up = 0
            while spec.startswith("up"):
                count_end = spec.find(":")
                if count_end <= 0:
                    break
                try:
                    up += int(spec[2:count_end])
                except ValueError:
                    break
                spec = spec[count_end + 1 :]
            resolved = runfiles.Rlocation(spec)
            if not resolved:
                raise FileNotFoundError(f"Sim env runfile not found: {spec}")
            path = Path(resolved).absolute()
            for _ in range(up):
                path = path.parent
            value = str(path)
        env[name] = value

    # Create a clean directory in which to write test results into.
    test_dir = tmp_path / "results"
    test_dir.mkdir(parents=True, exist_ok=True)

    # When `--bin` is supplied the simulator integration pre-compiled an
    # artifact and `build_dir` is reported as the runfiles directory
    # containing it — cocotb's runner finds the artifact at its
    # conventional `sim_file` path (e.g. `build_dir/sim.vvp` for icarus,
    # `build_dir/<hdl_toplevel>` for verilator). When `--bin` is omitted
    # (build-at-test-time rules) we use the writable `test_dir` so
    # cocotb's runner can populate it from `--build_source` inputs.
    if args.bin:
        test_bin = _find_runfile(runfiles, args.bin)
        build_dir = test_bin if test_bin.is_dir() else test_bin.parent
    else:
        build_dir = test_dir

    # Resolve test rlocationpaths to absolute paths. Use bare basenames as
    # cocotb `test_module` names rather than qualified `pkg.sub.module`
    # names — qualified names made from the repo layout can collide with
    # installed pip packages of the same top-level name (a test under
    # `cocotb/...` would import as `cocotb.<...>` and resolve against the
    # cocotb pip package first, raising `ModuleNotFoundError`).
    #
    # The bare basename only resolves if its parent directory is on
    # `sys.path` inside the cocotb subprocess; we hand those dirs over via
    # `--test_sys_path`. Cocotb's runner builds the simulator's PYTHONPATH
    # from `sys.path` (see `cocotb_tools.runner.Simulator._set_env`), so
    # `sys.path` is the right hook — augmenting env wouldn't propagate.
    test_paths = [_find_runfile(runfiles, t) for t in args.tests]
    test_module_args = ["--test_module"] + [p.stem for p in test_paths]
    test_sys_path_args = [
        f"--test_sys_path={d}" for d in sorted({str(p.parent) for p in test_paths})
    ]

    build_dir_abs = str(build_dir.absolute())
    substituted_cocotb_args = [arg.replace("$BUILD_DIR", build_dir_abs) for arg in args.cocotb_args]

    # Resolve precompiled library TreeArtifact rlocationpaths to absolute paths
    # once here so the cocotb subprocess doesn't need runfiles. Validate the
    # `<format>` prefix matches the resolved test sim's format family —
    # analysis already enforced this, but a defensive runtime check guards
    # against accidental wrapper invocations. Vendor passes through unchanged.
    precompiled_lib_args = []
    if args.precompiled_lib_dirs:
        expected_format = _SIM_FORMAT.get(sim_name)
        if expected_format is None:
            raise ValueError(
                f"--precompiled_lib_dir set, but simulator {sim_name!r} has no "
                f"known precompiled-library format. Supported sims: "
                f"{', '.join(sorted(_SIM_FORMAT.keys()))}."
            )
        for lib_format, lib_vendor, lib_rloc in args.precompiled_lib_dirs:
            if lib_format != expected_format:
                raise ValueError(
                    f"--precompiled_lib_dir format mismatch: lib has format "
                    f"{lib_format!r}, test simulator {sim_name!r} expects "
                    f"format {expected_format!r}."
                )
            lib_path = _find_runfile(runfiles, lib_rloc)
            precompiled_lib_args.append(
                f"--precompiled_lib_path={lib_vendor}:{lib_path.absolute()}"
            )

    # Run the cocotb test
    result = subprocess.run(
        [
            sys.executable,
            __file__,
            "--sim",
            sim_name,
            "--test_dir",
            str(test_dir),
            "--build_dir",
            str(build_dir),
        ]
        + precompiled_lib_args
        + test_module_args
        + test_sys_path_args
        + substituted_cocotb_args,
        env=env,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
    )

    # Sanitize the logs from the subprocess to try and have certain files align
    # with repo paths for improved IDE integrations.
    stdout = result.stdout
    if "RUNFILES_DIR" in env:
        runfiles_dir = env["RUNFILES_DIR"]
        stdout = stdout.replace(f"{runfiles_dir}/{args.workspace_name}", ".")
        stdout = stdout.replace(runfiles_dir, "..")

    # Present logs and process outputs.
    print(stdout.rstrip(), file=sys.stderr)
    _process_test_outputs(test_dir)

    # Coverage post-process: when running under `bazel coverage` the env
    # carries `COVERAGE_OUTPUT_FILE` (where Bazel expects per-test lcov).
    # If the sim provided a coverage-tool descriptor, invoke it now to
    # translate the sim's raw coverage output into lcov. A failure here
    # only complains to stderr — the test's pass/fail is independent of
    # whether coverage post-processing succeeded.
    coverage_output_file = os.environ.get("COVERAGE_OUTPUT_FILE")
    if (
        result.returncode == 0
        and coverage_output_file
        and args.coverage_tool
        and args.coverage_data_glob
        and args.coverage_args
    ):
        try:
            _emit_coverage_lcov(
                runfiles,
                _CoverageInputs(
                    tool_rloc=args.coverage_tool,
                    data_glob=args.coverage_data_glob,
                    args_template=args.coverage_args,
                    build_dir=Path(build_dir),
                    test_dir=test_dir,
                    output_path=Path(coverage_output_file),
                    env=env,
                ),
            )
        except RuntimeError as exc:
            print(f"coverage post-process failed: {exc}", file=sys.stderr)

    sys.exit(result.returncode)


class _CoverageInputs(NamedTuple):
    """Inputs to `_emit_coverage_lcov`, bundled to keep the call shape narrow."""

    tool_rloc: str
    data_glob: str
    args_template: Sequence[str]
    build_dir: Path
    test_dir: Path
    output_path: Path
    # Same composed env the cocotb runner subprocess saw. Important for
    # coverage tools that need to re-invoke the simulator (e.g. Aldec
    # `vsimsa` for ACDB→lcov conversion) — they need `RIVIERA_HOME` and
    # the rest of the install vars the sim's `env` attr provided.
    env: dict[str, str]


def _emit_coverage_lcov(runfiles: Runfiles, inputs: "_CoverageInputs") -> None:
    """Invoke the sim's coverage tool to translate raw data → lcov.

    Looks for `inputs.data_glob` in both `inputs.build_dir` and
    `inputs.test_dir` (sims differ on which they write coverage to —
    Verilator drops it in cwd which is `test_dir` under cocotb's
    runner). Substitutes `{output}` and `{data_files}` in
    `inputs.args_template`, then runs the tool.
    """
    tool_path = _find_runfile(runfiles, inputs.tool_rloc)

    # Sims write coverage data to either build_dir or test_dir depending
    # on whether they're build-at-Bazel-time (Verilator: data lands in
    # test_dir/cwd) or build-at-test-time (GHDL: data lands in build_dir
    # which is also test_dir for those). Probe both.
    data_files = sorted(
        {p.resolve() for p in inputs.build_dir.glob(inputs.data_glob)}
        | {p.resolve() for p in inputs.test_dir.glob(inputs.data_glob)},
    )
    if not data_files:
        print(
            f"coverage post-process: no files matching {inputs.data_glob!r} in "
            f"{inputs.build_dir} or {inputs.test_dir}; skipping lcov emission",
            file=sys.stderr,
        )
        return

    cli_args: list[str] = []
    for tmpl in inputs.args_template:
        if tmpl == "{data_files}":
            cli_args.extend(str(f) for f in data_files)
        else:
            cli_args.append(tmpl.replace("{output}", str(inputs.output_path)))

    print(
        f"coverage post-process: {tool_path} {' '.join(cli_args)}",
        file=sys.stderr,
    )
    cov_result = subprocess.run(
        [str(tool_path)] + cli_args,
        env=inputs.env,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
    )
    if cov_result.stdout:
        print(cov_result.stdout.rstrip(), file=sys.stderr)
    if cov_result.returncode != 0:
        raise RuntimeError(
            f"coverage tool exited {cov_result.returncode}",
        )


class ParseDict(argparse.Action):
    """An argparse action that parses repeated `KEY=VALUE` pairs into a dict."""

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: Any,
        option_string: Optional[str] = None,
    ) -> None:
        del parser
        del option_string
        setattr(namespace, self.dest, {})
        for value in values:
            key, value = value.split("=")
            getattr(namespace, self.dest)[key] = value


# This should match the parameters to the `test` function
# https://github.com/cocotb/cocotb/blob/stable/1.8/cocotb/runner.py#L196-L247
_COCOTB_TEST_FLAGS = [
    "build_dir",
    "extra_env",
    "gpi_interfaces",
    "gui",
    "hdl_toplevel_lang",
    "hdl_toplevel_library",
    "hdl_toplevel",
    "parameters",
    "plusargs",
    "seed",
    "test_args",
    "test_dir",
    "test_module",
    "testcase",
    "verbose",
    "waves",
]
"""All known arguments to `cocotb.runner.Simulator.test`"""


def cocotb_parse_args() -> argparse.Namespace:
    """Parse arguments for the cocotb subprocess.

    Note that these arguments expected to match https://github.com/cocotb/cocotb/blob/stable/1.8/cocotb/runner.py#L196-L247
    """
    parser = argparse.ArgumentParser()

    parser.add_argument("--sim", required=True, help="Default simulator")
    parser.add_argument(
        "--parameters",
        nargs="*",
        default={},
        action=ParseDict,
        help="Verilog parameters or VHDL generics",
    )
    parser.add_argument("--hdl_toplevel", default=None, help="Name of the HDL toplevel module")
    parser.add_argument(
        "--build_dir", default="sim_build", help="Directory to run the build step in"
    )
    parser.add_argument(
        "--verbose", default=False, action="store_true", help="Enable verbose messages"
    )
    parser.add_argument(
        "--test_module",
        nargs="*",
        default=[],
        help="Name(s) of the Python module(s) containing the tests to run",
    )
    parser.add_argument("--hdl_toplevel_library", help="The library name for HDL toplevel module")
    parser.add_argument(
        "--hdl_toplevel_lang", default=None, help="Language of the HDL toplevel module"
    )
    parser.add_argument(
        "--gpi_interfaces",
        default=None,
        help="List of GPI interfaces to use, with the first one being the entry point",
    )
    parser.add_argument("--testcase", default=None, help="Name(s) of a specific testcase(s) to run")
    parser.add_argument("--seed", default=None, help="A specific random seed to use")
    parser.add_argument(
        "--test_args",
        default=[],
        action="append",
        help="Extra simulator-specific args forwarded to cocotb's runner.test(test_args=...).",
    )
    parser.add_argument(
        "--build_source",
        dest="build_sources",
        default=[],
        action="append",
        help="Source file (rlocationpath) to (re)build at test time via cocotb's runner.build().",
    )
    parser.add_argument(
        "--build_args",
        dest="build_args",
        default=[],
        action="append",
        help="Extra simulator-specific args forwarded to cocotb's runner.build(build_args=...).",
    )
    parser.add_argument("--plusargs", default=[], help="'plusargs' to set for the simulator")
    parser.add_argument(
        "--extra_env",
        nargs="*",
        default={},
        action=ParseDict,
        help="Extra environment variables to set",
    )
    parser.add_argument("--waves", action="store_true", default=None, help="Record signal traces")
    parser.add_argument("--gui", action="store_true", default=None, help="Record signal traces")
    parser.add_argument("--test_dir", default=None, help="Directory to run the build step in")
    parser.add_argument(
        "--precompiled_lib_path",
        dest="precompiled_lib_paths",
        default=[],
        action="append",
        help=(
            "Precompiled-library entry as `<vendor>:<absolute_path>`, "
            "resolved by the outer wrapper from `--precompiled_lib_dir` "
            "rlocationpaths. `<vendor>` may be empty (`:<absolute_path>`). "
            "The per-format runner patch reads the link-config file inside "
            "each dir, emits the appropriate link directive, and applies "
            "any vendor quirks. Repeatable."
        ),
    )
    parser.add_argument(
        "--test_sys_path",
        dest="test_sys_paths",
        default=[],
        action="append",
        help=(
            "Directory to prepend to `sys.path` so cocotb's `import_module` "
            "can find test modules by bare basename. Cocotb's runner "
            "rebuilds the simulator's PYTHONPATH from `sys.path` (see "
            "`cocotb_tools.runner.Simulator._set_env`), so this is the "
            "right hook — augmenting env vars wouldn't propagate. "
            "Repeatable."
        ),
    )

    return parser.parse_args()


# Regex matching a library declaration in Aldec's `library.cfg`:
#   xil_defaultlib = "./xil_defaultlib/xil_defaultlib.lib" ;
# Captures the library name (LHS identifier). Lines starting with `$`
# (`$INCLUDE`, `$WORKSPACE`, ...) are directives, not libraries, and are
# excluded by the leading character class.
_ALDEC_LIB_LINE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=")
_ALDEC_INCLUDE_LINE = re.compile(r"""^\s*\$INCLUDE\s*=\s*["']([^"']+)["']""")


def _parse_aldec_library_cfg(cfg_path: Path, _seen: Optional[set[Path]] = None) -> Sequence[str]:
    """Library names declared (transitively via $INCLUDE) in `cfg_path`.

    Aldec's library.cfg is the authoritative source for what's in a bundle;
    we use this list to inject `-L <name>` flags into cocotb's `asim`
    invocation so elaboration finds design units (e.g. `BUFG` in `unisim`)
    that live in precompiled libs but aren't in `xil_defaultlib` or `work` —
    the only two libraries `asim` searches by default.

    Includes are followed once each (cycle-guarded). Missing includes are
    skipped silently — vendor exports occasionally chain to optional
    simlib paths that aren't present locally.
    """
    if _seen is None:
        _seen = set()
    cfg_path = cfg_path.absolute()
    # vsimsa's `$INCLUDE` accepts either a `library.cfg` file or the
    # directory holding one; resolve a directory to its enclosed library.cfg.
    if cfg_path.is_dir():
        cfg_path = cfg_path / "library.cfg"
    if cfg_path in _seen or not cfg_path.exists():
        return []
    _seen.add(cfg_path)

    names: set[str] = set()
    for raw in cfg_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.split(";", 1)[0].split("--", 1)[0].split("//", 1)[0]
        include = _ALDEC_INCLUDE_LINE.match(line)
        if include:
            included = Path(include.group(1))
            if not included.is_absolute():
                included = cfg_path.parent / included
            names.update(_parse_aldec_library_cfg(included, _seen))
            continue
        match = _ALDEC_LIB_LINE.match(line)
        if match:
            names.add(match.group(1))
    return sorted(names)


def _parse_precompiled_lib_paths(entries: Sequence[str]) -> Sequence[Tuple[Path, str]]:
    """Parse `--precompiled_lib_path` values into `(absolute_path, vendor)` pairs.

    Inverse of the `<vendor>:<absolute_path>` wire format the outer wrapper
    emits.
    """
    out = []
    for entry in entries:
        vendor, _, abs_path = entry.partition(":")
        if not abs_path:
            raise ValueError(
                f"--precompiled_lib_path expects `<vendor>:<absolute_path>`, got {entry!r}."
            )
        out.append((Path(abs_path), vendor))
    return out


def _xilinx_aldec_quirks() -> Tuple[str, str]:
    """Vivado/Xilinx-specific augmentations to Aldec's `asim` invocation.

    Returns:
        (resolution, extra_tops):
        - `resolution`: `-t fs` — Xilinx MMCM/PLL sim models compute
          half-periods from clock fractions like 33913.043 ps that round-
          trip lossily at the default 1 ps precision, after which cocotb's
          period-accuracy assertions raise `ValueError: Unable to
          accurately represent …`. Higher precision is safe for designs
          that don't need it.
        - `extra_tops`: `xil_defaultlib.glbl` — BD/IP code references GSR/
          GTS/PRLD via hierarchical paths like `glbl.GSR`; Vivado compiles
          `glbl.v` into `xil_defaultlib`, so naming it as a sibling top is
          required for any design that touches those signals and harmless
          for designs that don't.
    """
    return ("-t fs", "xil_defaultlib.glbl")


def _patch_aldec_runner(runner: Any, libs: Sequence[Tuple[Path, str]]) -> None:
    # pylint: disable=protected-access,too-many-locals
    """Wire precompiled Aldec libraries into cocotb's Riviera/Active-HDL flow.

    Cocotb's `Riviera._build_command` / `_test_command` write the do-script
    to a temp file and return `[["vsimsa", "-do", "do", <do_path>]]`. There's
    no extension point to inject preamble Tcl, so we post-process the temp
    do-file after it's written.

    `libs` is a list of `(library_dir, vendor)` pairs. `library_dir` is a
    Riviera bundle root; `vendor` is an ecosystem id (e.g. `"xilinx"`) used
    to opt into vendor-specific quirks via `_xilinx_aldec_quirks` etc.

    Two transforms are needed:

    1. `_build_command` & `_test_command`: prepend `vmap -link` for each
       precompiled library so the libs are reachable when cocotb's own
       `acom`/`alog`/`asim` run.

    2. `_test_command` only: inject `-L <libname>` for every library
       discovered through the precompiled set's `library.cfg` into the
       `asim` line. Elaboration's library search list is `xil_defaultlib` +
       `work` by default; without explicit `-L` flags it can't find design
       units that live in precompiled libs (`BUFG` in `unisim`, etc.).
       Vendor quirks layer on top via the same asim-line rewrite.
    """
    if not libs:
        return

    lib_dirs = [d for d, _ in libs]
    vendors = {v for _, v in libs if v}

    vmap_block = "".join(f"vmap -link {d / 'library.cfg'}\n" for d in lib_dirs)

    # Xilinx IP primitives (GT quads, memory blocks, …) bake `$readmemb`/
    # `$readmemh` calls against bare filenames into their .v sources — e.g.
    # `$readmemb("fc_bank_103_gt_quad_bd_gt_quad_base_0_0.mem", …)`. The
    # filename lookup resolves against the simulator's cwd, which is
    # cocotb's `build_dir` — NOT the precompiled library tree where Vivado
    # actually dropped the .mem. Without this, those primitives `$finish`
    # at sim time 0 and the test exits before any cocotb code runs. Stage
    # every .mem from the precompiled set into cwd via Tcl `file copy` so
    # the bare filename lookup hits. Bare files (not in subdirs) because
    # that's what the IP source does.
    mem_files: list[Path] = []
    for lib_dir in lib_dirs:
        mem_files.extend(lib_dir.rglob("*.mem"))
    mem_block = "".join(f"file copy -force {m} .\n" for m in mem_files)

    extra_libs: set[str] = set()
    for lib_dir in lib_dirs:
        extra_libs.update(_parse_aldec_library_cfg(lib_dir / "library.cfg"))
    asim_l_flags = " ".join(f"-L {name}" for name in sorted(extra_libs))

    asim_resolution = ""
    asim_extra_tops = ""
    if "xilinx" in vendors:
        asim_resolution, glbl_top = _xilinx_aldec_quirks()
        # `xil_defaultlib.glbl` only resolves if xil_defaultlib is actually
        # in the linked set — Vivado export bundles always provide it, but
        # pure-simlib bundles (unisim/unimacro only) don't. Naming a top
        # that doesn't exist hits `VSIM: Error: Library "xil_defaultlib" …
        # does not exist`. Gate the glbl injection on the runtime check.
        if "xil_defaultlib" in extra_libs:
            asim_extra_tops = glbl_top

    def _prepend_vmap(cmds: Any) -> Any:
        if not cmds or len(cmds[0]) < 4:
            return cmds
        do_path = Path(cmds[0][3])
        original = do_path.read_text(encoding="utf-8")
        do_path.write_text(vmap_block + mem_block + original, encoding="utf-8")
        return cmds

    def _patch_asim_line(line: str) -> str:
        """Inject `-t <res>`, `-L …` flags, and `<extra_top>` into cocotb's
        generated asim invocation. Not idempotent — callers must invoke at
        most once per do-file."""
        if not line.lstrip().startswith("asim "):
            return line
        prefix_parts = [asim_resolution, asim_l_flags]
        prefix = " ".join(p for p in prefix_parts if p)
        if prefix:
            line = line.replace("asim ", f"asim {prefix} ", 1)
        if asim_extra_tops:
            # cocotb's template ends the asim line with `... <TOPLEVEL> <PLUSARGS>`;
            # we have no robust way to split TOPLEVEL from PLUSARGS, but
            # asim accepts multiple tops in any order so appending
            # `xil_defaultlib.glbl` to the end works for both cases.
            line = line.rstrip() + " " + asim_extra_tops
        return line

    def _prepend_vmap_and_inject_asim_libs(cmds: Any) -> Any:
        if not cmds or len(cmds[0]) < 4:
            return cmds
        do_path = Path(cmds[0][3])
        original = do_path.read_text(encoding="utf-8")
        injected = "\n".join(_patch_asim_line(line) for line in original.splitlines())
        if original.endswith("\n"):
            injected += "\n"
        do_path.write_text(vmap_block + mem_block + injected, encoding="utf-8")
        return cmds

    original_build = runner._build_command
    original_test = runner._test_command

    def patched_build() -> Any:
        return _prepend_vmap(original_build())

    def patched_test() -> Any:
        return _prepend_vmap_and_inject_asim_libs(original_test())

    runner._build_command = patched_build
    runner._test_command = patched_test


# Per-format runner patches. Keyed by the precompiled-library format family
# from `CocotbPrecompiledLibraryInfo.format`. Currently only `aldec` is wired
# up; absent formats raise loudly when a test attaches a bundle of that
# format. Adding a new format = implement one `_patch_<format>_runner` and
# register it here.
_RUNNER_PATCHES = {
    "aldec": _patch_aldec_runner,
}


# https://github.com/cocotb/cocotb/blob/683194d22c1b4969f5ed88fe7c607009b38254a7/src/cocotb_tools/runner.py#L564
def cocotb_get_abs_path(path: Union[Path, str]) -> Path:
    """A replacemenet for `cocotb.runner.get_abs_path` that does not resolve symlinks/sandbox-escape."""

    if Path(path).is_absolute():
        return Path(os.path.normpath(path))

    return Path(os.path.normpath(Path.cwd() / path))


def cocotb_main() -> None:
    """The entrypoint to use for cocotb subprocesses"""
    args = cocotb_parse_args()
    test_params = {
        k: v for (k, v) in vars(args).items() if k in _COCOTB_TEST_FLAGS and v is not None
    }

    # Prepend test-source directories to `sys.path` BEFORE importing
    # cocotb_tools.runner — when runner.test() runs, it serialises
    # `sys.path` into the simulator's PYTHONPATH, so additions made here
    # propagate to the simulator's embedded Python (where cocotb's
    # `import_module` ultimately runs).
    for sys_path_entry in args.test_sys_paths:
        if sys_path_entry not in sys.path:
            sys.path.insert(0, sys_path_entry)

    with warnings.catch_warnings(action="ignore"):
        # pylint: disable-next=import-outside-toplevel
        import cocotb_tools.runner

    # Patch out any known sandbox-escapes.
    cocotb_tools.runner.get_abs_path = cocotb_get_abs_path  # type: ignore[assignment]

    runner = cocotb_tools.runner.get_runner(args.sim)

    # Apply per-format precompiled-library patch (if any libs were passed in).
    # Outer wrapper already validated the format matches; this just plumbs.
    if args.precompiled_lib_paths:
        fmt = _SIM_FORMAT.get(args.sim)
        if fmt is None:
            raise NotImplementedError(
                f"Simulator {args.sim!r} has no known precompiled-library "
                f"format. Add it to `_SIM_FORMAT`."
            )
        patcher = _RUNNER_PATCHES.get(fmt)
        if patcher is None:
            raise NotImplementedError(
                f"No precompiled-library runner patch registered for format "
                f"{fmt!r}. Implement `_patch_{fmt}_runner` and register it in "
                f"`_RUNNER_PATCHES`."
            )
        patcher(runner, _parse_precompiled_lib_paths(args.precompiled_lib_paths))

    # For simulators whose pre-built work libraries aren't relocatable (GHDL
    # JIT backends bake sandbox paths into `.cf` files), redo the build step
    # at test time with the source files Bazel placed in runfiles, using a
    # writable build_dir.
    if args.build_sources:
        runfiles = Runfiles.Create()
        if not runfiles:
            raise EnvironmentError("Failed to locate runfiles.")
        sources = [str(_find_runfile(runfiles, src)) for src in args.build_sources]
        writable_build_dir = test_params.get("test_dir") or test_params.get("build_dir")
        build_params = {
            "sources": sources,
            "build_dir": writable_build_dir,
            "hdl_toplevel": test_params.get("hdl_toplevel"),
            "hdl_library": test_params.get("hdl_toplevel_library") or "work",
            "build_args": args.build_args,
        }
        build_params = {k: v for k, v in build_params.items() if v is not None}
        runner.build(**build_params)
        # The test step must use the freshly-built work library.
        test_params["build_dir"] = writable_build_dir

    runner.test(**test_params)

    # `runner.test()` returns normally whenever the simulator subprocess
    # exits with status 0 — but the simulator's exit code only reflects
    # what the SIMULATOR thinks. Cocotb's Python (running via VHPI/VPI
    # inside the simulator) can raise without the simulator noticing:
    # `ModuleNotFoundError` at test-module import, `RegressionManager`
    # crashes, `Traceback`s during testbench execution. In those cases the
    # simulator still exits cleanly and `runner.test()` returns normally,
    # which would silently report PASS to Bazel.
    #
    # Three signals — checked in order — backstop that gap:
    #   1. `results.xml` doesn't exist: cocotb never wrote its report.
    #      That can only happen if cocotb crashed before discovery (or
    #      never ran at all).
    #   2. `results.xml` has zero `<testcase>` elements: cocotb's
    #      regression manager ran but registered no tests. Usually means
    #      the testbench module raised during import.
    #   3. Any `<testcase>` has `<failure>` or `<error>`: regular test
    #      failure path.
    _enforce_cocotb_results(test_params)


def _enforce_cocotb_results(test_params: dict[str, Any]) -> None:
    """Read cocotb's results.xml and `sys.exit(1)` on any signal of failure.

    Returns normally only if cocotb wrote results.xml, registered at least
    one test, and none of the registered tests reported failure/error.
    """
    test_dir = test_params.get("test_dir")
    if not test_dir:
        return
    results_path = Path(test_dir) / "results.xml"
    if not results_path.exists():
        print(
            f"cocotb didn't produce {results_path} — the simulator likely "
            f"exited before cocotb's regression completed. Inspect the sim "
            f"transcript above for the Python traceback or crash.",
            file=sys.stderr,
        )
        sys.exit(1)
    try:
        tree = ElementTree.parse(results_path)
    except ElementTree.ParseError as exc:
        print(f"cocotb results.xml at {results_path} unparseable: {exc}", file=sys.stderr)
        sys.exit(1)
    testcases = tree.findall(".//testcase")
    if not testcases:
        print(
            f"cocotb registered zero tests in {results_path}. Most common "
            f"cause: the testbench Python module raised during import "
            f"(check sim transcript above for `Traceback` / `ModuleNotFoundError`). "
            f"Less commonly: no `@cocotb.test` functions defined.",
            file=sys.stderr,
        )
        sys.exit(1)
    failed_cases = [
        tc.get("name", "?")
        for tc in testcases
        if tc.find("failure") is not None or tc.find("error") is not None
    ]
    if failed_cases:
        print(
            f"cocotb reported {len(failed_cases)} failing test(s): " f"{', '.join(failed_cases)}",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    # This script subprocesses itself to take advantage of the fully constructed python environment
    # but uses a specific environment variable to indicate when to run different entrypoints.
    if os.getenv(COCOTB_PROCESS_WRAPPER) == __file__:
        cocotb_main()
    else:
        main()
