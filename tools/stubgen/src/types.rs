//! VHDL type mark -> cocotb handle class.

/// Every `cocotb.handle` name the generator may emit. Used both to compute
/// the minimal import set for a rendered module and to tell a real handle
/// class apart from a reference to another generated stub class.
pub const ALL_COCOTB_TYPES: &[&str] = &[
    "ArrayObject",
    "EnumObject",
    "HierarchyArrayObject",
    "HierarchyObject",
    "IntegerObject",
    "LogicArrayObject",
    "LogicObject",
    "RealObject",
];

/// The fallback for anything not in [`vhdl_type`] — records, user enums,
/// unresolved aliases, and every Verilog port.
pub const ANY: &str = "Any";

/// Map a VHDL type mark onto a cocotb handle class.
///
/// Only the terminal name matters: a subtype indication's constraint
/// (`std_logic_vector(7 downto 0)`) and any selected-name prefix
/// (`ieee.std_logic_1164.std_logic`) are stripped by the caller. Matching is
/// case-insensitive because VHDL identifiers are.
///
/// Names here are exactly those defined by `STD` and `IEEE`. A project-local
/// alias or subtype (`subtype byte is std_logic_vector(7 downto 0)`) is not
/// listed and falls through to [`ANY`] — resolving those is what
/// `cocotb_toolchain.vhdl_libraries` exists to enable.
pub fn vhdl_type(type_mark: &str) -> &'static str {
    match type_mark.to_ascii_lowercase().as_str() {
        // Single-bit logic.
        "std_logic" | "std_ulogic" | "bit" => "LogicObject",
        // Numeric single-value.
        "integer" | "natural" | "positive" => "IntegerObject",
        "real" => "RealObject",
        "boolean" => "EnumObject",
        // 1-D bit vectors.
        "std_logic_vector" | "std_ulogic_vector" | "signed" | "unsigned" | "bit_vector" => {
            "LogicArrayObject"
        }
        // Arrays of integers.
        "integer_vector" => "ArrayObject[IntegerObject]",
        _ => ANY,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_is_case_insensitive() {
        assert_eq!(vhdl_type("STD_LOGIC"), "LogicObject");
        assert_eq!(vhdl_type("Std_Logic_Vector"), "LogicArrayObject");
    }

    #[test]
    fn unknown_types_fall_through_to_any() {
        assert_eq!(vhdl_type("my_record_t"), ANY);
        // Project-local aliases are deliberately absent; see module docs.
        assert_eq!(vhdl_type("logic_2d"), ANY);
    }
}
