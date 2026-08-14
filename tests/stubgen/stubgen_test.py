"""Tests for the HDL -> Protocol stub generator."""

# We use `[stub] = _parse_...(src)` to both extract the single expected result
# and assert exactly one stub was produced. Pylint's static shape inference
# can't see through the parser, so silence its "unbalanced" warning.
# pylint: disable=unbalanced-tuple-unpacking

from textwrap import dedent

import pytest
from stubgen import EntityStub, Field, _parse_verilog, _parse_vhdl, render

# ---------------------------------------------------------------------------
# VHDL
# ---------------------------------------------------------------------------


def test_vhdl_entity_generics_and_ports() -> None:
    """A single VHDL entity with scalar generics + ports round-trips cleanly."""
    src = dedent("""
        library ieee;
        use ieee.std_logic_1164.all;
        entity slr_broadcast is
          generic (
            G_DATA_WIDTH : integer := 8;
            G_NUM_SLRS   : natural := 4
          );
          port (
            clk_in   : in  std_logic;
            rst_n_in : in  std_logic;
            data_in  : in  std_logic_vector(G_DATA_WIDTH-1 downto 0);
            data_out : out std_logic_vector(G_DATA_WIDTH-1 downto 0)
          );
        end entity;
        """)
    [stub] = _parse_vhdl(src)
    assert stub == EntityStub(
        class_name="SlrBroadcast",
        entity_name="slr_broadcast",
        source_kind="vhdl",
        fields=(
            Field("G_DATA_WIDTH", "IntegerObject"),
            Field("G_NUM_SLRS", "IntegerObject"),
            Field("clk_in", "LogicObject"),
            Field("rst_n_in", "LogicObject"),
            Field("data_in", "LogicArrayObject"),
            Field("data_out", "LogicArrayObject"),
        ),
    )


def test_vhdl_k2_custom_type_aliases() -> None:
    """K2's `logic`/`logic_1d`/`logic_2d` aliases map to sensible cocotb handles."""
    src = dedent("""
        entity dummy is
          port (
            single    : in  logic;
            vec       : in  logic_1d(7 downto 0);
            two_dim   : out logic_2d(0 to 3)(15 downto 0);
            three_dim : out logic_3d(0 to 1)(0 to 3)(7 downto 0)
          );
        end entity;
        """)
    [stub] = _parse_vhdl(src)
    types = {f.name: f.py_type for f in stub.fields}
    assert types == {
        "single": "LogicObject",
        "vec": "LogicArrayObject",
        "two_dim": "HierarchyArrayObject[LogicArrayObject]",
        "three_dim": "HierarchyArrayObject[HierarchyArrayObject[LogicArrayObject]]",
    }


def test_vhdl_unknown_types_fall_back_to_any() -> None:
    """Record-typed ports fall through to `Any`."""
    src = dedent("""
        entity dummy is
          port (
            s_axil_in  : in  axil_peripheral_in_t;
            s_axil_out : out axil_peripheral_out_t
          );
        end entity;
        """)
    [stub] = _parse_vhdl(src)
    assert stub.fields == (
        Field("s_axil_in", "Any"),
        Field("s_axil_out", "Any"),
    )


def test_vhdl_multiple_entities_in_one_file() -> None:
    """A file with several entities emits one stub per entity."""
    src = dedent("""
        entity foo is
          port (clk_in : in logic);
        end entity;

        entity bar is
          generic (G_WIDTH : natural := 8);
          port (data_out : out logic_1d(G_WIDTH-1 downto 0));
        end entity;
        """)
    stubs = _parse_vhdl(src)
    assert [s.class_name for s in stubs] == ["Foo", "Bar"]


def test_vhdl_architecture_signals_included() -> None:
    """Signals declared in an architecture surface on the entity's stub."""
    src = dedent("""
        entity dut_tb is
          generic (G_WIDTH : positive := 8);
        end entity;

        architecture tb of dut_tb is
          constant C_CLK_PERIOD : time := 10 ns;
          signal clk_in, rst_n_in : std_logic := '0';
          signal data_bus : std_logic_vector(G_WIDTH-1 downto 0);
          signal axil_in  : axil_peripheral_in_t;
        begin
          -- ...
        end architecture;
        """)
    [stub] = _parse_vhdl(src)
    types = {f.name: f.py_type for f in stub.fields}
    assert types == {
        "G_WIDTH": "IntegerObject",
        "clk_in": "LogicObject",
        "rst_n_in": "LogicObject",
        "data_bus": "LogicArrayObject",
        "axil_in": "Any",
    }


def test_vhdl_entity_name_to_class_name() -> None:
    """Snake-case entity names become PascalCase class names."""
    [stub] = _parse_vhdl("entity slr_accumulate_tb is end entity;")
    assert stub.class_name == "SlrAccumulateTb"


# ---------------------------------------------------------------------------
# Verilog / SystemVerilog
# ---------------------------------------------------------------------------


def test_verilog_module_ports_all_any() -> None:
    """Verilog ports all map to `Any` — the language is untyped for our purposes."""
    src = dedent("""
        module counter #(
            parameter WIDTH = 8
        ) (
            input  logic         clk,
            input  logic         rst_n,
            input  logic [7:0]   data_in,
            output logic [7:0]   data_out,
            inout  wire          bidir
        );
        endmodule
        """)
    [stub] = _parse_verilog(src)
    assert stub.class_name == "Counter"
    assert stub.source_kind == "verilog"
    names = [f.name for f in stub.fields]
    assert names == ["WIDTH", "clk", "rst_n", "data_in", "data_out", "bidir"]
    assert all(f.py_type == "Any" for f in stub.fields)


def test_verilog_non_ansi_bare_names() -> None:
    """Non-ANSI-style modules that just list port names still work."""
    src = dedent("""
        module top (clk, rst_n, data);
        endmodule
        """)
    [stub] = _parse_verilog(src)
    assert [f.name for f in stub.fields] == ["clk", "rst_n", "data"]


def test_verilog_stripped_comments() -> None:
    """C-style comments are removed before parsing."""
    src = dedent("""
        // A ping counter
        /* block
           comment */
        module ping (input logic clk /* inline */);
        endmodule
        """)
    [stub] = _parse_verilog(src)
    assert [f.name for f in stub.fields] == ["clk"]


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def test_render_emits_valid_python() -> None:
    """The rendered module compiles and imports only the types it uses."""
    stubs = [
        EntityStub(
            class_name="Simple",
            entity_name="simple",
            source_kind="vhdl",
            fields=(
                Field("clk", "LogicObject"),
                Field("data", "LogicArrayObject"),
            ),
        )
    ]
    src = render(stubs)
    compile(src, "<generated>", "exec")
    assert "from cocotb.handle import (" in src
    assert "HierarchyObject," in src  # always imported for the base class
    assert "LogicObject," in src
    assert "LogicArrayObject," in src
    assert "IntegerObject" not in src  # unused
    assert "Any" not in src  # no Any-typed fields
    assert "class Simple(HierarchyObject):" in src


def test_render_imports_any_when_needed() -> None:
    """Verilog stubs use `Any`, which must be imported from typing."""
    stubs = [
        EntityStub(
            class_name="V",
            entity_name="v",
            source_kind="verilog",
            fields=(Field("clk", "Any"),),
        )
    ]
    src = render(stubs)
    compile(src, "<generated>", "exec")
    assert "from typing import Any" in src


def test_render_empty_input() -> None:
    """No stubs still yields a valid (empty) module."""
    src = render([])
    compile(src, "<generated>", "exec")


def test_mixed_vhdl_and_verilog_render_together() -> None:
    """A single rendered module can host stubs from both languages."""
    stubs = [
        EntityStub("Vhd", "vhd", "vhdl", (Field("clk", "LogicObject"),)),
        EntityStub("Ver", "ver", "verilog", (Field("clk", "Any"),)),
    ]
    src = render(stubs)
    compile(src, "<generated>", "exec")
    assert "class Vhd(HierarchyObject):" in src
    assert "class Ver(HierarchyObject):" in src
    assert "from typing import Any" in src
    assert "from cocotb.handle import (" in src


def test_render_rejects_duplicate_class_names() -> None:
    """Two entities that PascalCase to the same class name fail loudly."""
    stubs = [
        EntityStub("Dut", "dut", "vhdl", (Field("clk", "LogicObject"),)),
        EntityStub("Dut", "d_u_t", "verilog", (Field("clk", "Any"),)),
    ]
    with pytest.raises(ValueError, match="duplicate stub class names"):
        render(stubs)


def test_parse_and_render_flags_within_file_collision() -> None:
    """Two entities in one VHDL file with colliding class names fail render()."""
    src = dedent("""
        entity dut is
          port (clk : in logic);
        end entity;

        entity d_u_t is
          port (clk : in logic);
        end entity;
        """)
    stubs = _parse_vhdl(src)
    assert [s.class_name for s in stubs] == ["Dut", "DUT"]
    # Force a collision (the parser lands on distinct names above) to prove
    # render() rejects duplicates surfaced from a single input file.
    stubs[1] = stubs[1]._replace(class_name="Dut")
    with pytest.raises(ValueError, match="duplicate stub class names"):
        render(stubs)
