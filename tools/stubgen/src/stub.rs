//! The language-independent shape every parser produces.

/// A single generic / port / signal / instance on an entity or module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
    pub name: String,
    pub py_type: String,
}

/// Everything the renderer needs to emit one class.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntityStub {
    pub class_name: String,
    pub entity_name: String,
    /// `"vhdl"` or `"verilog"`. Only used in the rendered docstring.
    pub source_kind: &'static str,
    pub fields: Vec<Field>,
}

/// `slr_broadcast_tb` -> `SlrBroadcastTb`.
///
/// Mirrors Python's `str.capitalize()` per underscore-separated part, which
/// upper-cases the first character *and lower-cases the rest* — so `AXI_lite`
/// becomes `AxiLite`, not `AXILite`.
pub fn class_name(entity_id: &str) -> String {
    let mut out = String::with_capacity(entity_id.len());
    for part in entity_id.split('_') {
        let mut chars = part.chars();
        if let Some(first) = chars.next() {
            out.extend(first.to_uppercase());
            for c in chars {
                out.extend(c.to_lowercase());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_name_matches_python_capitalize() {
        assert_eq!(class_name("slr_broadcast_tb"), "SlrBroadcastTb");
        assert_eq!(class_name("counter"), "Counter");
        // `capitalize()` lower-cases the tail, so an all-caps part collapses.
        assert_eq!(class_name("AXI_lite"), "AxiLite");
        // Empty parts (leading/doubled underscores) contribute nothing.
        assert_eq!(class_name("_leading"), "Leading");
        assert_eq!(class_name("a__b"), "AB");
    }
}
