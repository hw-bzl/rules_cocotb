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
import bisect
import json
import re
import sys
from collections.abc import Iterable, Mapping
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

_VHDL_ARCHITECTURE_HEADER_RE = re.compile(
    r"\barchitecture\s+[a-zA-Z_]\w*\s+of\s+(?P<entity>[a-zA-Z_]\w*)\s+is\b",
    re.IGNORECASE,
)

# Matches `<label> : [component ]entity [<lib>.]<name>[(<arch>)]` — the label
# is the identifier cocotb exposes as a child handle on the parent hierarchy.
# Both direct entity instantiations (`work.dut`) and configuration-less
# component instantiations are captured; the referenced entity name is used
# to look up a class from the current stub set for typed nested access.
#
# The `(?!is\b)` guard rejects VHDL attribute specifications of the form
# `attribute foreign of <ent> : entity is "binding";` — `is` is a reserved
# word, so no real entity can bear that name, but the shared `<x> : entity`
# skeleton would otherwise let attribute specs masquerade as instantiations
# and inject a spurious `<ent>: Is` field on the enclosing architecture.
_VHDL_INSTANCE_RE = re.compile(
    r"""
    \b(?P<label>[a-zA-Z_]\w*)\s*:\s*
    (?:component\s+)?entity\s+
    (?:[a-zA-Z_]\w*\s*\.\s*)?              # optional library prefix
    (?P<name>(?!is\b)[a-zA-Z_]\w*)
    (?:\s*\(\s*[a-zA-Z_]\w*\s*\))?         # optional (architecture)
    """,
    re.IGNORECASE | re.VERBOSE,
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


def _collect_vhdl_arch_fields(stripped: str) -> dict[str, list[Field]]:
    """Build `entity_name.lower() -> extra Field list` from architecture bodies.

    Two sources feed the map: (a) `signal` declarations inside each
    architecture, and (b) component / entity instantiations, each attributed
    to the last architecture header that appears before it in the text.
    VHDL disallows nested architectures, so that lookback is unambiguous;
    robust body extraction via regex would otherwise trip on nested
    `end process`/`end loop`.
    """
    arch_signals: dict[str, list[Field]] = {}
    for arch in _VHDL_ARCHITECTURE_RE.finditer(stripped):
        entries = arch_signals.setdefault(arch.group("entity").lower(), [])
        for match in _VHDL_SIGNAL_RE.finditer(arch.group("decls")):
            py_type = _vhdl_map_type(match.group("subtype"))
            for raw in match.group("names").split(","):
                entries.append(Field(name=raw.strip(), py_type=py_type))

    arch_headers = list(_VHDL_ARCHITECTURE_HEADER_RE.finditer(stripped))
    header_ends = [h.end() for h in arch_headers]
    for inst in _VHDL_INSTANCE_RE.finditer(stripped):
        # `arch_headers` is finditer-order (sorted by position). Binary-search
        # for the last header whose `end()` is ≤ inst.start() — avoids a full
        # O(N) rescan per instance.
        idx = bisect.bisect_right(header_ends, inst.start()) - 1
        if idx < 0:
            continue
        entity = arch_headers[idx].group("entity").lower()
        arch_signals.setdefault(entity, []).append(
            Field(
                name=inst.group("label"),
                py_type=_class_name(inst.group("name")),
            ),
        )
    return arch_signals


def _parse_vhdl(text: str) -> list[EntityStub]:
    """Extract entity + architecture-signal stubs from VHDL source."""
    stripped = _strip_vhdl_comments(text)
    arch_signals = _collect_vhdl_arch_fields(stripped)

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


_BARE_CLASS_REF_RE = re.compile(r"[A-Z]\w*")


def _is_bare_class_ref(py_type: str) -> bool:
    """True if `py_type` is a single PascalCase identifier that could name a user class.

    Bare identifiers are the only shape a user-defined class reference can
    take here (they come from `_class_name()`). Composite types like
    `ArrayObject[IntegerObject]` and lowercase primitives skip resolution.
    `Any` also shortcuts out — it's the `typing.Any` sentinel that means
    "unresolved," never a user class, even if a Verilog module happened to
    be named `any` and produced a colliding `Any` class name elsewhere.
    """
    if py_type == "Any":
        return False
    return _BARE_CLASS_REF_RE.fullmatch(py_type) is not None


def _reject_duplicate_class_names(stubs: list[EntityStub]) -> dict[str, EntityStub]:
    """Return `class_name -> EntityStub` map, raising on collision.

    Silent duplication would let Python's late-binding hand mypy whichever
    class came last, so we fail loudly instead.
    """
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
    return seen


def _resolve_field_types(
    stubs: list[EntityStub],
    known_class_names: set[str],
    dep_metadata: Mapping[str, str],
) -> tuple[list[EntityStub], dict[str, str]]:
    """Resolve each field's `py_type` against locals, cocotb builtins, and dep_metadata.

    Returns `(resolved_stubs, imports_needed)` where `imports_needed` maps
    class name → module import path for every dep-metadata-resolved reference.
    Unresolvable class references downgrade to `Any` so the runtime handle
    stays attribute-permissive.
    """
    imports_needed: dict[str, str] = {}
    resolved_stubs: list[EntityStub] = []
    for stub in stubs:
        resolved_fields: list[Field] = []
        for field in stub.fields:
            if not _is_bare_class_ref(field.py_type):
                resolved_fields.append(field)
            elif field.py_type in _ALL_COCOTB_TYPES:
                resolved_fields.append(field)
            elif field.py_type in known_class_names:
                resolved_fields.append(field)
            elif field.py_type in dep_metadata:
                resolved_fields.append(field)
                imports_needed[field.py_type] = dep_metadata[field.py_type]
            else:
                resolved_fields.append(field._replace(py_type="Any"))
        resolved_stubs.append(stub._replace(fields=tuple(resolved_fields)))
    return resolved_stubs, imports_needed


def _collect_type_usage(stubs: list[EntityStub]) -> tuple[set[str], bool]:
    """Return (cocotb handle types used, whether `Any` appears anywhere).

    `HierarchyObject` is always present since every stub subclasses it.
    """
    used_types: set[str] = {"HierarchyObject"}
    needs_any = False
    for stub in stubs:
        for field in stub.fields:
            for name in re.findall(r"[A-Za-z_]\w*", field.py_type):
                if name in _ALL_COCOTB_TYPES:
                    used_types.add(name)
                elif name == "Any":
                    needs_any = True
    return used_types, needs_any


def _render_dep_imports(imports_needed: Mapping[str, str]) -> list[str]:
    """Format the `from <module> import ...` block for dep-resolved classes."""
    if not imports_needed:
        return []
    by_module: dict[str, list[str]] = {}
    for class_name, module in imports_needed.items():
        by_module.setdefault(module, []).append(class_name)
    lines: list[str] = []
    for module in sorted(by_module):
        names = sorted(by_module[module])
        lines.append("")
        if len(names) == 1:
            lines.append(f"from {module} import {names[0]}")
        else:
            lines.append(f"from {module} import (")
            for name in names:
                lines.append(f"    {name},")
            lines.append(")")
    return lines


def render(
    stubs: Iterable[EntityStub],
    dep_metadata: Mapping[str, str] | None = None,
) -> str:
    """Render a list of stubs to a formatted Python module string.

    Each stub becomes a `HierarchyObject` subclass. Subclassing (rather
    than `typing.Protocol`) lets testbench code annotate the DUT
    parameter directly — `async def test(dut: MyDut)` — because
    `MyDut` is-a `HierarchyObject`, which is what cocotb hands the
    test at runtime.

    `dep_metadata` maps class names exported by dependency stub modules
    to the dotted Python module they live in (loaded from sibling
    `.json` files emitted by prior `stubgen` invocations). A field that
    references a class in `dep_metadata` renders typed with a matching
    `from <module> import <Class>` line; a field that references a class
    resolvable neither locally nor via `dep_metadata` still falls back
    to `Any` — same behavior as when `dep_metadata` is empty.

    Raises `ValueError` if two stubs would collide on the emitted class
    name (e.g. two entities in the same input set whose snake_case names
    both PascalCase to the same identifier).
    """
    stubs = list(stubs)
    seen = _reject_duplicate_class_names(stubs)

    if not stubs:
        return (
            '"""Auto-generated cocotb DUT stubs. Do not edit."""\n'
            "# No entities / modules found in the input HDL sources.\n"
        )

    stubs, imports_needed = _resolve_field_types(
        stubs,
        set(seen.keys()),
        dep_metadata or {},
    )
    used_types, needs_any = _collect_type_usage(stubs)

    lines: list[str] = [
        '"""Auto-generated cocotb DUT stubs. Do not edit.',
        "",
        f"Emitted from {len(stubs)} entity/module declaration(s).",
        '"""',
        "",
    ]
    if needs_any:
        lines.append("from typing import Any")
        lines.append("")
    lines.append("from cocotb.handle import (")
    for name in sorted(used_types):
        lines.append(f"    {name},")
    lines.append(")")
    lines.extend(_render_dep_imports(imports_needed))

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


def write_metadata(
    path: Path,
    module_import_path: str,
    stubs: Iterable[EntityStub],
) -> None:
    """Emit the sibling `.json` metadata file for downstream stubgen runs.

    Internal, tool-owned: the same `stubgen` binary writes and reads this
    within one Bazel build, so the schema is only what a consumer needs to
    write `from <module_import_path> import <ClassName>` for a cross-file
    class reference.
    """
    data = {
        "module_import_path": module_import_path,
        "class_names": sorted(stub.class_name for stub in stubs),
    }
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def _load_dep_metadata(paths: Iterable[Path]) -> dict[str, str]:
    """Merge dep metadata files into a `class_name -> module_import_path` map.

    First-seen wins on collision — matches Python's `from x import Y` /
    `from z import Y` shadowing semantics, and keeps the merge deterministic
    given a stable input order (which Bazel provides via its depset ordering).
    A cross-module collision emits a stderr warning so the caller notices when
    a common name like `Fifo` gets silently resolved to whichever library
    Bazel happened to visit first.
    """
    dep_metadata: dict[str, str] = {}
    for path in paths:
        data = json.loads(path.read_text())
        module = data["module_import_path"]
        for class_name in data["class_names"]:
            existing = dep_metadata.get(class_name)
            if existing is None:
                dep_metadata[class_name] = module
            elif existing != module:
                print(
                    f"stubgen: warning: dep-metadata class {class_name!r} "
                    f"defined in both {existing!r} and {module!r}; using "
                    f"{existing!r}.",
                    file=sys.stderr,
                )
    return dep_metadata


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint.

    Processes every `--stub` entry in one invocation — the calling aspect
    passes an entry per HDL source in the library. Batching all of a
    library's srcs into one process amortizes the Python/sandbox startup
    cost (which is ~10-50× the actual per-src work) and lets sibling
    cross-references resolve in-memory instead of via a separate Bazel
    action pass.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stub",
        nargs=4,
        action="append",
        default=[],
        metavar=("SRC", "OUTPUT", "METADATA", "MODULE_IMPORT_PATH"),
        help=(
            "One HDL source with its per-src outputs and dotted Python "
            "import path. Repeat once per src in the library."
        ),
    )
    parser.add_argument(
        "--dep-metadata",
        type=Path,
        action="append",
        default=[],
        help=(
            "Path to a dependency library's `.json` metadata file. May be "
            "repeated. Class names found in these files are typed rather "
            "than downgraded to `Any` when referenced by a field."
        ),
    )
    args = parser.parse_args(argv)
    if not args.stub:
        return 0
    try:
        # Phase 1: parse each src, write its metadata, and thread the just-
        # written class names into the dep_metadata map so sibling srcs'
        # render pass sees them. Local (same-src) class names still take
        # precedence in `render()`, so a self-reference stays untyped-by-
        # import as intended.
        dep_metadata = _load_dep_metadata(args.dep_metadata)
        per_src: list[tuple[Path, list[EntityStub]]] = []
        for src, output, metadata, module_import_path in args.stub:
            stubs = extract([Path(src)])
            write_metadata(Path(metadata), module_import_path, stubs)
            for stub in stubs:
                dep_metadata.setdefault(stub.class_name, module_import_path)
            per_src.append((Path(output), stubs))

        # Phase 2: render each `.py` with the combined dep_metadata.
        for output, stubs in per_src:
            rendered = render(stubs, dep_metadata=dep_metadata)
            output.write_text(rendered)
    except ValueError as exc:
        print(f"stubgen: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
