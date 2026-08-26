"""Module extension backing a synthetic external HDL repo for `//tests/stubgen`.

Renders both the VHDL source and the `vhdl_library` target inside a repo
rule, so the coverage stresses not just the "dep in another workspace"
path but also "HDL content that never existed on disk until the repo
rule ran." Consumers reference the emitted target as
`@cocotb_stubgen_ext_hdl//:ext_dep_dut`.
"""

_EXT_DEP_DUT_VHD = """\
library ieee;
use ieee.std_logic_1164.all;

entity ext_dep_dut is
    port (
        clk    : in  std_logic;
        rst    : in  std_logic;
        data   : out std_logic_vector(7 downto 0)
    );
end entity ext_dep_dut;
"""

_BUILD_BAZEL = """\
load("@rules_vhdl//vhdl:defs.bzl", "vhdl_library")

# Root-package target — deliberately keeps `ctx.label.package` empty so the
# aspect's stub `module_import_path` falls through the `stem`-only branch.
vhdl_library(
    name = "ext_dep_dut",
    srcs = ["ext_dep_dut.vhd"],
    visibility = ["//visibility:public"],
)
"""

def _ext_hdl_repo_impl(rctx):
    rctx.file("ext_dep_dut.vhd", _EXT_DEP_DUT_VHD)
    rctx.file("BUILD.bazel", _BUILD_BAZEL)

_ext_hdl_repo = repository_rule(
    implementation = _ext_hdl_repo_impl,
    doc = "Render a self-contained external HDL repo used to test cross-workspace stubgen.",
)

def _ext_hdl_impl(mctx):
    _ext_hdl_repo(name = "cocotb_stubgen_ext_hdl")

    # Content of the emitted repo is fully determined by the string literals
    # in this file — no host or environment reads — so Bazel can skip
    # recording this extension's result in `MODULE.bazel.lock`.
    return mctx.extension_metadata(reproducible = True)

ext_hdl = module_extension(
    implementation = _ext_hdl_impl,
    doc = "Instantiates the `cocotb_stubgen_ext_hdl` repo exactly once per module.",
)
