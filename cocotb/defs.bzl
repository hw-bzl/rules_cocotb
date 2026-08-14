"""Cocotb rules"""

load(
    "//cocotb/private:cocotb_precompiled_library_info.bzl",
    _CocotbPrecompiledLibraryInfo = "CocotbPrecompiledLibraryInfo",
)
load(
    "//cocotb/private:cocotb_simulators.bzl",
    _CocotbSimInfo = "CocotbSimInfo",
)
load(
    ":cocotb_activehdl_sim.bzl",
    _cocotb_activehdl_sim = "cocotb_activehdl_sim",
)
load(
    ":cocotb_dsim_sim.bzl",
    _cocotb_dsim_sim = "cocotb_dsim_sim",
)
load(
    ":cocotb_ghdl_sim.bzl",
    _cocotb_ghdl_sim = "cocotb_ghdl_sim",
)
load(
    ":cocotb_icarus_sim.bzl",
    _cocotb_icarus_sim = "cocotb_icarus_sim",
)
load(
    ":cocotb_nvc_sim.bzl",
    _cocotb_nvc_sim = "cocotb_nvc_sim",
)
load(
    ":cocotb_questa_sim.bzl",
    _cocotb_questa_sim = "cocotb_questa_sim",
)
load(
    ":cocotb_riviera_sim.bzl",
    _cocotb_riviera_sim = "cocotb_riviera_sim",
)
load(
    ":cocotb_stubgen.bzl",
    _cocotb_stubgen = "cocotb_stubgen",
)
load(
    ":cocotb_test.bzl",
    _cocotb_test = "cocotb_test",
)
load(
    ":cocotb_toolchain.bzl",
    _cocotb_toolchain = "cocotb_toolchain",
)
load(
    ":cocotb_vcs_sim.bzl",
    _cocotb_vcs_sim = "cocotb_vcs_sim",
)
load(
    ":cocotb_verilator_sim.bzl",
    _cocotb_verilator_sim = "cocotb_verilator_sim",
)
load(
    ":cocotb_xcelium_sim.bzl",
    _cocotb_xcelium_sim = "cocotb_xcelium_sim",
)

CocotbPrecompiledLibraryInfo = _CocotbPrecompiledLibraryInfo
CocotbSimInfo = _CocotbSimInfo
cocotb_activehdl_sim = _cocotb_activehdl_sim
cocotb_dsim_sim = _cocotb_dsim_sim
cocotb_ghdl_sim = _cocotb_ghdl_sim
cocotb_icarus_sim = _cocotb_icarus_sim
cocotb_nvc_sim = _cocotb_nvc_sim
cocotb_questa_sim = _cocotb_questa_sim
cocotb_riviera_sim = _cocotb_riviera_sim
cocotb_stubgen = _cocotb_stubgen
cocotb_test = _cocotb_test
cocotb_toolchain = _cocotb_toolchain
cocotb_vcs_sim = _cocotb_vcs_sim
cocotb_verilator_sim = _cocotb_verilator_sim
cocotb_xcelium_sim = _cocotb_xcelium_sim
