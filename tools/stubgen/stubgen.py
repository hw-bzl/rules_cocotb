"""Generate cocotb DUT stub classes from HDL sources.

The generator reads one or more HDL files (VHDL or Verilog / SystemVerilog),
extracts each top-level entity or module's port + parameter list (plus VHDL
architecture signals), and emits a single Python module with a
`cocotb.handle.HierarchyObject` subclass per entity/module. Downstream cocotb
tests annotate the DUT parameter directly:

```python
from my_dut_stubs import MyDut

async def test(dut: MyDut) -> None:
    dut.clk.value = 0
```

Subclassing `HierarchyObject` (rather than `typing.Protocol`) means the
generated class IS-A `HierarchyObject`, which is what cocotb passes the
test at runtime — so the type hint checks out without any `cast()` on the
test author's part.

Type-mapping notes:

* VHDL is strongly typed, so `std_logic`/`std_logic_vector`/`integer`/... map
  to specific cocotb handle classes (`LogicObject`, `LogicArrayObject`,
  `IntegerObject`, ...). Unknown types (records, user enums) fall through
  to `Any`.
* Verilog / SystemVerilog is essentially untyped at the port declaration
  level once you flatten `logic` / `wire` / `reg` — a vector may hold any
  data. Every Verilog port therefore maps to `Any`, giving the same escape
  hatch as if the tb accessed the DUT directly.

Usage:
    stubgen --output OUT.py IN.vhd IN.v ...
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import NamedTuple


class Field(NamedTuple):
    """A single generic / port / signal on an entity or module."""

    name: str
    py_type: str


class EntityStub(NamedTuple):
    """Everything the generator needs to emit one Protocol class."""

    class_name: str
    entity_name: str
    source_kind: str  # "vhdl" or "verilog"
    fields: tuple[Field, ...]


# VHDL type mark -> cocotb handle type. Match is case-insensitive.
_VHDL_TYPE_MAP: dict[str, str] = {
    # Single-bit logic.
    "logic": "LogicObject",
    "rlogic": "LogicObject",
    "std_logic": "LogicObject",
    "std_ulogic": "LogicObject",
    "bit": "LogicObject",
    # Numeric single-value.
    "integer": "IntegerObject",
    "natural": "IntegerObject",
    "positive": "IntegerObject",
    "real": "RealObject",
    "boolean": "EnumObject",
    # 1-D bit vectors.
    "logic_1d": "LogicArrayObject",
    "rlogic_1d": "LogicArrayObject",
    "std_logic_vector": "LogicArrayObject",
    "std_ulogic_vector": "LogicArrayObject",
    "signed": "LogicArrayObject",
    "unsigned": "LogicArrayObject",
    "bit_vector": "LogicArrayObject",
    # Arrays of integers.
    "integer_vector": "ArrayObject[IntegerObject]",
    "natural_1d": "ArrayObject[IntegerObject]",
    "integer_1d": "ArrayObject[IntegerObject]",
    # Higher-dimensional arrays.
    "logic_2d": "HierarchyArrayObject[LogicArrayObject]",
    "rlogic_2d": "HierarchyArrayObject[LogicArrayObject]",
    "logic_3d": "HierarchyArrayObject[HierarchyArrayObject[LogicArrayObject]]",
    "signed_2d": "HierarchyArrayObject[LogicArrayObject]",
    "unsigned_2d": "HierarchyArrayObject[LogicArrayObject]",
}

# All cocotb.handle names the generator may emit. Used to compute the minimal
# import set for the output module.
_ALL_COCOTB_TYPES = (
    "ArrayObject",
    "EnumObject",
    "HierarchyArrayObject",
    "HierarchyObject",
    "IntegerObject",
    "LogicArrayObject",
    "LogicObject",
    "RealObject",
)


# ---------------------------------------------------------------------------
# Comment stripping
# ---------------------------------------------------------------------------

_VHDL_COMMENT_RE = re.compile(r"--[^\n]*")
_C_LINE_COMMENT_RE = re.compile(r"//[^\n]*")
_C_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)


def _strip_vhdl_comments(text: str) -> str:
    return _VHDL_COMMENT_RE.sub("", text)


def _strip_verilog_comments(text: str) -> str:
    return _C_LINE_COMMENT_RE.sub("", _C_BLOCK_COMMENT_RE.sub("", text))


# ---------------------------------------------------------------------------
# VHDL parsing
# ---------------------------------------------------------------------------

_VHDL_ENTITY_START_RE = re.compile(
    r"\bentity\s+(?P<name>[a-zA-Z_]\w*)\s+is\b",
    re.IGNORECASE,
)
_VHDL_ENTITY_END_RE = re.compile(
    r"\bend\s+(?:entity\s+)?([a-zA-Z_]\w*)?\s*;",
    re.IGNORECASE,
)
_VHDL_GENERIC_KW = re.compile(r"\bgeneric\s*\(", re.IGNORECASE)
_VHDL_PORT_KW = re.compile(r"\bport\s*\(", re.IGNORECASE)


def _find_matching_paren(text: str, open_pos: int) -> int:
    """Return the index of the `)` that matches the `(` at `open_pos`.

    `text[open_pos]` must be `(`. Raises `ValueError` on unbalanced input.
    """
    depth = 0
    for i in range(open_pos, len(text)):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
    raise ValueError("unbalanced parentheses in VHDL entity body")


_VHDL_ARCHITECTURE_RE = re.compile(
    r"""
    \barchitecture\s+[a-zA-Z_]\w*\s+of\s+(?P<entity>[a-zA-Z_]\w*)\s+is
    (?P<decls>.*?)
    \bbegin\b
    """,
    re.DOTALL | re.IGNORECASE | re.VERBOSE,
)

_VHDL_SIGNAL_RE = re.compile(
    r"""
    \bsignal\s+
    (?P<names>[a-zA-Z_]\w*(?:\s*,\s*[a-zA-Z_]\w*)*)
    \s*:\s*
    (?P<subtype>[^;:=]+?)
    \s*(?::=[^;]+)?
    \s*;
    """,
    re.MULTILINE | re.IGNORECASE | re.VERBOSE,
)


def _vhdl_map_type(subtype_indication: str) -> str:
    """Map a VHDL subtype indication (e.g. `std_logic_vector(7 downto 0)`) to cocotb."""
    match = re.match(r"^\s*([A-Za-z_]\w*)", subtype_indication)
    if match is None:
        return "Any"
    type_mark = match.group(1).lower()
    return _VHDL_TYPE_MAP.get(type_mark, "Any")


def _split_declarations(body: str) -> list[str]:
    """Split a VHDL generic/port list body into individual declarations.

    VHDL uses `;` as a declaration separator, but a subtype indication can
    itself contain parenthesised expressions with semicolons (rare but legal
    in records). Track paren depth so we only split at top-level semicolons.
    """
    parts: list[str] = []
    depth = 0
    start = 0
    for i, ch in enumerate(body):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == ";" and depth == 0:
            parts.append(body[start:i].strip())
            start = i + 1
    tail = body[start:].strip()
    if tail:
        parts.append(tail)
    return [p for p in parts if p]


def _parse_vhdl_interface_element(decl: str) -> list[Field]:
    """Parse one VHDL interface element like `a, b : in std_logic := '0'`."""
    # Strip leading keyword (`signal`/`constant`) if present.
    decl = re.sub(r"^\s*(signal|constant)\b\s*", "", decl, flags=re.IGNORECASE)
    if ":" not in decl:
        return []
    lhs, rhs = decl.split(":", 1)
    names = [n.strip() for n in lhs.split(",") if n.strip()]
    # Drop optional mode keyword.
    rhs = rhs.strip()
    rhs = re.sub(r"^(in|out|inout|buffer|linkage)\b\s*", "", rhs, flags=re.IGNORECASE)
    # Drop default value.
    rhs = re.split(r":=", rhs, maxsplit=1)[0].strip()
    py_type = _vhdl_map_type(rhs)
    return [Field(name=n, py_type=py_type) for n in names]


def _parse_vhdl_entity(  # pylint: disable=too-many-locals
    text: str, start: int
) -> tuple[str, list[Field], int]:
    """Parse one VHDL entity beginning at `start` (position of `entity` keyword).

    Returns `(entity_name, fields, end_pos)` where `end_pos` is one past the
    entity's terminating `;`. Uses paren-balanced scanning so nested subtype
    constraints like `std_logic_vector(7 downto 0)` don't fool the extractor.
    """
    start_match = _VHDL_ENTITY_START_RE.match(text, start)
    if start_match is None:
        raise ValueError(f"expected `entity` at offset {start}")
    name = start_match.group("name")
    cursor = start_match.end()

    fields: list[Field] = []
    end_match = _VHDL_ENTITY_END_RE.search(text, cursor)
    end_pos = end_match.end() if end_match else len(text)

    offset = cursor
    while offset < (end_match.start() if end_match else len(text)):
        gen_match = _VHDL_GENERIC_KW.search(
            text, offset, end_match.start() if end_match else len(text)
        )
        port_match = _VHDL_PORT_KW.search(
            text, offset, end_match.start() if end_match else len(text)
        )
        candidates = [m for m in (gen_match, port_match) if m is not None]
        if not candidates:
            break
        next_match = min(candidates, key=lambda m: m.start())
        open_pos = next_match.end() - 1  # position of `(`
        close_pos = _find_matching_paren(text, open_pos)
        body = text[open_pos + 1 : close_pos]
        for decl in _split_declarations(body):
            fields.extend(_parse_vhdl_interface_element(decl))
        offset = close_pos + 1

    return name, fields, end_pos


def _parse_vhdl(text: str) -> list[EntityStub]:
    """Extract entity + architecture-signal stubs from VHDL source."""
    stripped = _strip_vhdl_comments(text)

    arch_signals: dict[str, list[Field]] = {}
    for arch in _VHDL_ARCHITECTURE_RE.finditer(stripped):
        key = arch.group("entity").lower()
        entries = arch_signals.setdefault(key, [])
        for match in _VHDL_SIGNAL_RE.finditer(arch.group("decls")):
            py_type = _vhdl_map_type(match.group("subtype"))
            for raw in match.group("names").split(","):
                entries.append(Field(name=raw.strip(), py_type=py_type))

    stubs: list[EntityStub] = []
    offset = 0
    while offset < len(stripped):
        entity_match = _VHDL_ENTITY_START_RE.search(stripped, offset)
        if entity_match is None:
            break
        name, fields, offset = _parse_vhdl_entity(stripped, entity_match.start())
        fields.extend(arch_signals.get(name.lower(), []))
        stubs.append(
            EntityStub(
                class_name=_class_name(name),
                entity_name=name,
                source_kind="vhdl",
                fields=tuple(fields),
            )
        )
    return stubs


# ---------------------------------------------------------------------------
# Verilog / SystemVerilog parsing
# ---------------------------------------------------------------------------

_VERILOG_MODULE_RE = re.compile(
    r"""
    \bmodule\s+(?P<name>[a-zA-Z_]\w*)\s*
    (?:\#\s*\((?P<params>[^)]*)\))?          # optional parameter list
    \s*\((?P<ports>.*?)\)\s*;                # port list
    """,
    re.DOTALL | re.VERBOSE,
)

_VERILOG_PORT_NAME_RE = re.compile(r"([a-zA-Z_]\w*)\s*(?:\[[^\]]*\])?\s*$")
_VERILOG_PARAM_RE = re.compile(
    r"""
    \bparameter\b\s*(?:\w+\s+)*             # optional type keywords
    (?P<name>[a-zA-Z_]\w*)                  # parameter name
    """,
    re.VERBOSE,
)


def _split_verilog_ports(port_list: str) -> list[str]:
    """Split a Verilog module port list into individual port declarations.

    Verilog uses `,` as the top-level separator; packed range specifiers
    contain nested brackets/parens that must not confuse the split.
    """
    parts: list[str] = []
    depth = 0
    start = 0
    for i, ch in enumerate(port_list):
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(port_list[start:i].strip())
            start = i + 1
    tail = port_list[start:].strip()
    if tail:
        parts.append(tail)
    return [p for p in parts if p]


def _parse_verilog_ports(port_list: str) -> list[Field]:
    """Extract port names from a Verilog module's port list.

    Verilog port declarations vary widely (ANSI vs non-ANSI, packed vs
    unpacked, user-defined interfaces). Rather than try to type each port
    precisely, we treat every port as `Any` — testbench code that reads
    `dut.some_port.value` retains the same runtime behavior it always had,
    and mypy doesn't second-guess the untyped world of Verilog.
    """
    fields: list[Field] = []
    for raw in _split_verilog_ports(port_list):
        # Handle ANSI-style: `input logic [7:0] name`.
        # The port name is the last identifier after any range specifier.
        match = _VERILOG_PORT_NAME_RE.search(raw)
        if match:
            fields.append(Field(name=match.group(1), py_type="Any"))
    return fields


def _parse_verilog_params(params: str) -> list[Field]:
    fields: list[Field] = []
    for match in _VERILOG_PARAM_RE.finditer(params):
        fields.append(Field(name=match.group("name"), py_type="Any"))
    return fields


def _parse_verilog(text: str) -> list[EntityStub]:
    stripped = _strip_verilog_comments(text)
    stubs: list[EntityStub] = []
    for module_match in _VERILOG_MODULE_RE.finditer(stripped):
        name = module_match.group("name")
        fields: list[Field] = []
        if params := module_match.group("params"):
            fields.extend(_parse_verilog_params(params))
        if ports := module_match.group("ports"):
            fields.extend(_parse_verilog_ports(ports))
        stubs.append(
            EntityStub(
                class_name=_class_name(name),
                entity_name=name,
                source_kind="verilog",
                fields=tuple(fields),
            )
        )
    return stubs


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def _class_name(entity_id: str) -> str:
    """`slr_broadcast_tb` -> `SlrBroadcastTb`."""
    return "".join(part.capitalize() for part in entity_id.split("_"))


def _dispatch(path: Path) -> list[EntityStub]:
    """Pick a parser based on file extension."""
    suffix = path.suffix.lower()
    text = path.read_text()
    if suffix in (".vhd", ".vhdl"):
        return _parse_vhdl(text)
    if suffix in (".v", ".sv", ".svh", ".vh"):
        return _parse_verilog(text)
    raise ValueError(f"unrecognised HDL extension: {path}")


def extract(paths: Iterable[Path]) -> list[EntityStub]:
    """Parse every input path in order, returning the concatenated stubs."""
    stubs: list[EntityStub] = []
    for path in paths:
        stubs.extend(_dispatch(path))
    return stubs


def render(stubs: Iterable[EntityStub]) -> str:  # pylint: disable=too-many-branches
    """Render a list of stubs to a formatted Python module string.

    Each stub becomes a `HierarchyObject` subclass. Subclassing (rather
    than `typing.Protocol`) lets testbench code annotate the DUT
    parameter directly — `async def test(dut: MyDut)` — because
    `MyDut` is-a `HierarchyObject`, which is what cocotb hands the
    test at runtime.

    Raises `ValueError` if two stubs would collide on the emitted class
    name (e.g. two entities in the same input set whose snake_case names
    both PascalCase to the same identifier). Silent duplication would let
    the second class definition win under Python's late-binding and mypy
    would type against whichever came last.
    """
    stubs = list(stubs)

    seen: dict[str, EntityStub] = {}
    duplicates: list[tuple[EntityStub, EntityStub]] = []
    for stub in stubs:
        prior = seen.get(stub.class_name)
        if prior is not None:
            duplicates.append((prior, stub))
        else:
            seen[stub.class_name] = stub
    if duplicates:
        report = ["duplicate stub class names:"]
        for prior, stub in duplicates:
            report.append(
                f"  '{stub.class_name}' from {stub.source_kind} entity "
                f"'{stub.entity_name}' collides with {prior.source_kind} "
                f"entity '{prior.entity_name}'"
            )
        raise ValueError("\n".join(report))

    if not stubs:
        return (
            '"""Auto-generated cocotb DUT stubs. Do not edit."""\n'
            "# No entities / modules found in the input HDL sources.\n"
        )

    # Determine minimal set of cocotb handle types to import. Every stub
    # subclasses `HierarchyObject`, so it's always required.
    used_types: set[str] = {"HierarchyObject"}
    needs_any = False
    for stub in stubs:
        for field in stub.fields:
            for name in re.findall(r"[A-Za-z_]\w*", field.py_type):
                if name in _ALL_COCOTB_TYPES:
                    used_types.add(name)
                elif name == "Any":
                    needs_any = True

    lines: list[str] = []
    lines.append('"""Auto-generated cocotb DUT stubs. Do not edit.')
    lines.append("")
    lines.append(f"Emitted from {len(stubs)} entity/module declaration(s).")
    lines.append('"""')
    lines.append("")
    if needs_any:
        lines.append("from typing import Any")
        lines.append("")
    lines.append("from cocotb.handle import (")
    for name in sorted(used_types):
        lines.append(f"    {name},")
    lines.append(")")

    for stub in stubs:
        lines.append("")
        lines.append("")
        lines.append(f"class {stub.class_name}(HierarchyObject):")
        lines.append(f'    """Typed view of {stub.source_kind} entity `{stub.entity_name}`."""')
        if not stub.fields:
            continue
        lines.append("")
        for field in stub.fields:
            lines.append(f"    {field.name}: {field.py_type}")

    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        required=True,
        help="Path to the Python module to emit.",
    )
    parser.add_argument(
        "sources",
        type=Path,
        nargs="+",
        help="HDL source files (.vhd/.vhdl/.v/.sv) to parse.",
    )
    args = parser.parse_args(argv)
    try:
        rendered = render(extract(args.sources))
    except ValueError as exc:
        print(f"stubgen: {exc}", file=sys.stderr)
        return 1
    args.output.write_text(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
