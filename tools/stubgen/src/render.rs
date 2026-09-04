//! Render extracted stubs to a Python module.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use crate::stub::EntityStub;
use crate::types::{ALL_COCOTB_TYPES, ANY};

/// True if `py_type` is a single PascalCase identifier that could name a
/// generated stub class.
///
/// Bare identifiers are the only shape such a reference takes, since they all
/// come from `class_name()`. Composite types like `ArrayObject[IntegerObject]`
/// are already resolved. `Any` short-circuits: it is the "unresolved"
/// sentinel, never a user class, even if some module were named `any`.
fn is_bare_class_ref(py_type: &str) -> bool {
    if py_type == ANY {
        return false;
    }
    let mut chars = py_type.chars();
    match chars.next() {
        Some(first) if first.is_ascii_uppercase() => {}
        _ => return false,
    }
    chars.all(|c| c.is_alphanumeric() || c == '_')
}

/// Build the `class_name -> stub` map, rejecting collisions.
///
/// Two entities whose names PascalCase to the same identifier would leave
/// Python's late binding to pick whichever class was defined last, so fail
/// loudly instead of emitting a module that silently mistypes one of them.
fn reject_duplicate_class_names(stubs: &[EntityStub]) -> Result<HashSet<String>, String> {
    let mut seen: HashMap<&str, &EntityStub> = HashMap::new();
    let mut report = vec!["duplicate stub class names:".to_string()];
    let mut collided = false;
    for stub in stubs {
        match seen.get(stub.class_name.as_str()) {
            Some(prior) => {
                collided = true;
                report.push(format!(
                    "  '{}' from {} entity '{}' collides with {} entity '{}'",
                    stub.class_name,
                    stub.source_kind,
                    stub.entity_name,
                    prior.source_kind,
                    prior.entity_name,
                ));
            }
            None => {
                seen.insert(&stub.class_name, stub);
            }
        }
    }
    if collided {
        return Err(report.join("\n"));
    }
    Ok(seen.keys().map(|k| (*k).to_string()).collect())
}

/// Rewrite each field's type against locals, cocotb builtins, and dep
/// metadata, returning the set of imports the dep-resolved ones need.
///
/// A class reference that resolves nowhere downgrades to `Any`, keeping the
/// runtime handle attribute-permissive rather than naming a class that the
/// module will not import.
fn resolve_field_types(
    stubs: &mut [EntityStub],
    known_class_names: &HashSet<String>,
    dep_metadata: &HashMap<String, String>,
) -> BTreeMap<String, String> {
    let mut imports_needed = BTreeMap::new();
    for stub in stubs.iter_mut() {
        for field in &mut stub.fields {
            if !is_bare_class_ref(&field.py_type)
                || ALL_COCOTB_TYPES.contains(&field.py_type.as_str())
                || known_class_names.contains(&field.py_type)
            {
                continue;
            }
            match dep_metadata.get(&field.py_type) {
                Some(module) => {
                    imports_needed.insert(field.py_type.clone(), module.clone());
                }
                None => field.py_type = ANY.to_string(),
            }
        }
    }
    imports_needed
}

/// Collect the cocotb handle classes used, plus whether `Any` appears.
///
/// `HierarchyObject` is always present because every stub subclasses it.
fn collect_type_usage(stubs: &[EntityStub]) -> (BTreeSet<&'static str>, bool) {
    let mut used: BTreeSet<&'static str> = BTreeSet::new();
    used.insert("HierarchyObject");
    let mut needs_any = false;
    for stub in stubs {
        for field in &stub.fields {
            // Split on the brackets of composite types like
            // `ArrayObject[IntegerObject]` to see both halves.
            for word in field
                .py_type
                .split(|c: char| !c.is_alphanumeric() && c != '_')
            {
                if let Some(known) = ALL_COCOTB_TYPES.iter().find(|t| **t == word) {
                    used.insert(known);
                } else if word == ANY {
                    needs_any = true;
                }
            }
        }
    }
    (used, needs_any)
}

fn render_dep_imports(imports_needed: &BTreeMap<String, String>, lines: &mut Vec<String>) {
    let mut by_module: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for (class, module) in imports_needed {
        by_module
            .entry(module.as_str())
            .or_default()
            .insert(class.as_str());
    }
    for (module, names) in by_module {
        lines.push(String::new());
        if names.len() == 1 {
            lines.push(format!(
                "from {} import {}",
                module,
                names.iter().next().unwrap()
            ));
        } else {
            lines.push(format!("from {module} import ("));
            for name in names {
                lines.push(format!("    {name},"));
            }
            lines.push(")".to_string());
        }
    }
}

const EMPTY_MODULE: &str = "\"\"\"Auto-generated cocotb DUT stubs. Do not edit.\"\"\"\n\
                            # No entities / modules found in the input HDL sources.\n";

/// Render stubs to a formatted Python module.
///
/// Each stub becomes a `HierarchyObject` subclass. Subclassing (rather than
/// `typing.Protocol`) lets testbench code annotate the DUT parameter directly
/// — `async def test(dut: MyDut)` — because `MyDut` is-a `HierarchyObject`,
/// which is what cocotb hands the test at runtime.
///
/// `dep_metadata` maps class names exported by dependency stub modules to the
/// dotted module they live in. A field referencing one renders typed with a
/// matching import; a field resolvable neither locally nor there falls back
/// to `Any`.
pub fn render(
    stubs: &[EntityStub],
    dep_metadata: &HashMap<String, String>,
) -> Result<String, String> {
    let known_class_names = reject_duplicate_class_names(stubs)?;

    if stubs.is_empty() {
        return Ok(EMPTY_MODULE.to_string());
    }

    let mut stubs = stubs.to_vec();
    let imports_needed = resolve_field_types(&mut stubs, &known_class_names, dep_metadata);
    let (used_types, needs_any) = collect_type_usage(&stubs);

    let mut lines = vec![
        "\"\"\"Auto-generated cocotb DUT stubs. Do not edit.".to_string(),
        String::new(),
        format!("Emitted from {} entity/module declaration(s).", stubs.len()),
        "\"\"\"".to_string(),
        String::new(),
    ];
    if needs_any {
        lines.push("from typing import Any".to_string());
        lines.push(String::new());
    }
    lines.push("from cocotb.handle import (".to_string());
    for name in &used_types {
        lines.push(format!("    {name},"));
    }
    lines.push(")".to_string());
    render_dep_imports(&imports_needed, &mut lines);

    for stub in &stubs {
        lines.push(String::new());
        lines.push(String::new());
        lines.push(format!("class {}(HierarchyObject):", stub.class_name));
        lines.push(format!(
            "    \"\"\"Typed view of {} entity `{}`.\"\"\"",
            stub.source_kind, stub.entity_name
        ));
        if stub.fields.is_empty() {
            continue;
        }
        lines.push(String::new());
        for field in &stub.fields {
            lines.push(format!("    {}: {}", field.name, field.py_type));
        }
    }

    lines.push(String::new());
    Ok(lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stub::Field;

    fn stub(class: &str, fields: &[(&str, &str)]) -> EntityStub {
        EntityStub {
            class_name: class.to_string(),
            entity_name: class.to_lowercase(),
            source_kind: "vhdl",
            fields: fields
                .iter()
                .map(|(n, t)| Field {
                    name: n.to_string(),
                    py_type: t.to_string(),
                })
                .collect(),
        }
    }

    #[test]
    fn empty_input_renders_placeholder_module() {
        assert_eq!(render(&[], &HashMap::new()).unwrap(), EMPTY_MODULE);
    }

    #[test]
    fn duplicate_class_names_are_rejected() {
        let err = render(&[stub("Foo", &[]), stub("Foo", &[])], &HashMap::new()).unwrap_err();
        assert!(err.contains("duplicate stub class names"), "{err}");
    }

    #[test]
    fn unresolvable_class_reference_downgrades_to_any() {
        let out = render(&[stub("Top", &[("dut", "Missing")])], &HashMap::new()).unwrap();
        assert!(out.contains("    dut: Any"), "{out}");
        assert!(out.contains("from typing import Any"), "{out}");
    }

    #[test]
    fn dep_resolved_reference_emits_an_import() {
        let deps = HashMap::from([("Counter".to_string(), "tests.stubgen.counter".to_string())]);
        let out = render(&[stub("Tb", &[("dut", "Counter")])], &deps).unwrap();
        assert!(
            out.contains("from tests.stubgen.counter import Counter"),
            "{out}"
        );
        assert!(out.contains("    dut: Counter"), "{out}");
    }

    #[test]
    fn composite_types_pull_in_both_imports() {
        let out = render(
            &[stub("Top", &[("v", "ArrayObject[IntegerObject]")])],
            &HashMap::new(),
        )
        .unwrap();
        assert!(out.contains("    ArrayObject,"), "{out}");
        assert!(out.contains("    IntegerObject,"), "{out}");
        assert!(!out.contains("from typing import Any"), "{out}");
    }
}
