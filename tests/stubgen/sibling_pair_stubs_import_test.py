"""Regression: sibling `.vhd` files in one `vhdl_library` must cross-reference.

`sibling_top.vhd` and `sibling_inner.vhd` live in the same `vhdl_library`;
`sibling_top`'s architecture instantiates `sibling_inner`. Before the
aspect split into metadata + render phases, the per-src render only saw
transitive-dep metadata — never its own library's siblings — so this
`inner_inst` field would downgrade to `Any`.
"""

from tests.stubgen.sibling_inner import SiblingInner
from tests.stubgen.sibling_top import SiblingTop


def test_sibling_top_inner_inst_typed_against_sibling_class() -> None:
    """The nested-inst field carries the sibling stub class, not `Any`."""
    assert SiblingTop.__annotations__["inner_inst"] is SiblingInner
