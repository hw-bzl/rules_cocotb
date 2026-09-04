//! Verilog / SystemVerilog extraction.
//!
//! Delegates to `verible-verilog-syntax --printtree --export_json` and walks
//! the concrete syntax tree it prints. That covers the non-ANSI
//! `module m(a, b); input a;` form, nested constructs, and comments and string
//! literals, none of which the regex generator this replaced got right.
//!
//! Verible parses without preprocessing, so a macro is a `MacroIdentifier`
//! leaf rather than whatever it expands to. Ports that arrive that way are
//! skipped: their names are not knowable without expanding the macro, and a
//! missing attribute on the stub degrades to an unchecked one at runtime,
//! whereas the regex generator's guess (a single port literally named after
//! the macro) type-checked code that could not work.
//!
//! Every port, parameter, net, and variable types as `Any`: once `logic` /
//! `wire` / `reg` are flattened, a Verilog declaration says nothing about what
//! the vector holds, so a precise handle class cannot be inferred. Module
//! instantiations are the exception — those type as the instantiated module's
//! stub class, exactly as VHDL component instantiations do.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use runfiles::{rlocation, Runfiles};
use serde_json::Value;

use crate::stub::{class_name, EntityStub, Field};
use crate::types::ANY;

/// Baked in by `rustc_env` in this package's `BUILD.bazel`.
const VERIBLE_SYNTAX: &str = env!("VERIBLE_SYNTAX_RLOCATIONPATH");

static VERIBLE_SYNTAX_PATH: LazyLock<Option<PathBuf>> = LazyLock::new(|| {
    let runfiles = Runfiles::create().ok()?;
    rlocation!(runfiles, VERIBLE_SYNTAX)
});

/// Subtrees that hold a *type's* identifiers rather than a declared name.
/// Skipped when looking for the thing being declared, since several of them
/// sort before the name they belong to — `parameter logic [W-1:0] P` puts `W`
/// ahead of `P`.
const TYPE_SUBTREES: &[&str] = &[
    "kDataType",
    "kDeclarationDimensions",
    "kPackedDimensions",
    "kTrailingAssign",
    "kTypeInfo",
    "kUnpackedDimensions",
];

pub fn parse(path: &Path) -> Result<Vec<EntityStub>, String> {
    let tree = syntax_tree(path)?;
    Ok(collect_modules(&tree))
}

/// Run Verible over `path` and return the root of its syntax tree.
fn syntax_tree(path: &Path) -> Result<Value, String> {
    let exe = VERIBLE_SYNTAX_PATH.as_ref().ok_or_else(|| {
        format!("`verible-verilog-syntax` is missing from stubgen's runfiles (looked for '{VERIBLE_SYNTAX}')")
    })?;

    let output = Command::new(exe)
        .args(["--printtree", "--export_json"])
        .arg(path)
        .output()
        .map_err(|err| format!("{}: running {}: {}", path.display(), exe.display(), err))?;

    let Ok(parsed) = serde_json::from_slice::<Value>(&output.stdout) else {
        // Verible only fails to produce JSON when it did not run at all.
        return Err(format!(
            "{}: verible-verilog-syntax failed: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr).trim(),
        ));
    };

    // One entry, keyed by the path as passed.
    let entry = parsed
        .as_object()
        .and_then(|files| files.values().next())
        .ok_or_else(|| {
            format!(
                "{}: verible-verilog-syntax reported no files",
                path.display()
            )
        })?;

    // A parse error leaves the tree truncated or absent, and a stub rendered
    // from one silently drops whatever came after the error. Fail instead.
    if let Some(errors) = entry.get("errors").and_then(Value::as_array) {
        let mut report = vec![format!("{}: verilog parse error:", path.display())];
        for error in errors {
            let line = error.get("line").and_then(Value::as_u64).unwrap_or(0) + 1;
            let column = error.get("column").and_then(Value::as_u64).unwrap_or(0) + 1;
            let text = error.get("text").and_then(Value::as_str).unwrap_or("");
            report.push(format!("  {line}:{column}: syntax error at '{text}'"));
        }
        return Err(report.join("\n"));
    }

    entry
        .get("tree")
        .cloned()
        .ok_or_else(|| format!("{}: verible-verilog-syntax emitted no tree", path.display()))
}

fn tag(node: &Value) -> &str {
    node.get("tag").and_then(Value::as_str).unwrap_or_default()
}

fn children(node: &Value) -> impl Iterator<Item = &Value> {
    node.get("children")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        // Verible emits `null` for the optional slots a production did not
        // fill, so every child list is a fixed width.
        .filter(|child| !child.is_null())
}

/// Every node tagged `wanted`, in source order.
///
/// Does not descend into a match (an instantiation holds no instantiations) or
/// into any subtree tagged in `stop`.
fn descendants<'a>(node: &'a Value, wanted: &str, stop: &[&str]) -> Vec<&'a Value> {
    fn walk<'a>(node: &'a Value, wanted: &str, stop: &[&str], found: &mut Vec<&'a Value>) {
        for child in children(node) {
            let child_tag = tag(child);
            if child_tag == wanted {
                found.push(child);
            } else if !stop.contains(&child_tag) {
                walk(child, wanted, stop, found);
            }
        }
    }
    let mut found = Vec::new();
    walk(node, wanted, stop, &mut found);
    found
}

/// The first `SymbolIdentifier` leaf under `node`, skipping `stop` subtrees.
fn first_identifier<'a>(node: &'a Value, stop: &[&str]) -> Option<&'a str> {
    if tag(node) == "SymbolIdentifier" {
        return node.get("text").and_then(Value::as_str);
    }
    for child in children(node) {
        if stop.contains(&tag(child)) {
            continue;
        }
        if let Some(found) = first_identifier(child, stop) {
            return Some(found);
        }
    }
    None
}

fn collect_modules(tree: &Value) -> Vec<EntityStub> {
    descendants(tree, "kModuleDeclaration", &[])
        .into_iter()
        .filter_map(module_stub)
        .collect()
}

fn module_stub(declaration: &Value) -> Option<EntityStub> {
    let header = children(declaration).find(|c| tag(c) == "kModuleHeader")?;

    // The header's first identifier is the module name; the parameter and port
    // lists follow it.
    let name = first_identifier(header, &[])?;

    let mut fields: Vec<Field> = Vec::new();
    let mut push = |name: &str, py_type: String| {
        // `input a; wire a;` declares one signal twice. Keep the first, so a
        // port never loses its position to its own redeclaration.
        if !fields.iter().any(|f: &Field| f.name == name) {
            fields.push(Field {
                name: name.to_string(),
                py_type,
            });
        }
    };

    for parameter in descendants(header, "kParamDeclaration", &[]) {
        // `localparam` is not settable from outside the module, so it is not a
        // generic; only `parameter` counts.
        if children(parameter).next().map(tag) != Some("parameter") {
            continue;
        }
        if let Some(name) = first_identifier(parameter, TYPE_SUBTREES) {
            push(name, ANY.to_string());
        }
    }

    for list in descendants(header, "kPortDeclarationList", &[]) {
        for port in children(list) {
            // `kPortDeclaration` is the ANSI form, `kPort` the non-ANSI one.
            if !matches!(tag(port), "kPortDeclaration" | "kPort") {
                continue;
            }
            if let Some(name) = first_identifier(port, TYPE_SUBTREES) {
                push(name, ANY.to_string());
            }
        }
    }

    // Nets and variables before instantiations, matching how `vhdl.rs` orders
    // architecture signals ahead of component instantiations.
    let body: Vec<&Value> = children(declaration)
        .filter(|c| tag(c) == "kModuleItemList")
        .collect();
    let bases: Vec<&Value> = body
        .iter()
        .flat_map(|items| descendants(items, "kInstantiationBase", &["kModuleDeclaration"]))
        .collect();

    for items in &body {
        for net in descendants(items, "kNetVariable", &["kModuleDeclaration"]) {
            if let Some(name) = first_identifier(net, TYPE_SUBTREES) {
                push(name, ANY.to_string());
            }
        }
    }
    for base in &bases {
        // `logic [7:0] scratch;` parses as an instantiation of the type
        // `logic`; what tells the two apart is whether the declared names are
        // `kGateInstance` (an instance) or `kRegisterVariable` (a variable).
        for variable in descendants(base, "kRegisterVariable", &[]) {
            if let Some(name) = first_identifier(variable, TYPE_SUBTREES) {
                push(name, ANY.to_string());
            }
        }
    }

    for base in &bases {
        let instantiated = children(base)
            .find(|c| tag(c) == "kInstantiationType")
            .and_then(|t| first_identifier(t, &[]));
        for instance in descendants(base, "kGateInstance", &[]) {
            // `kParenGroup` holds the port connections, whose identifiers
            // would otherwise shadow the instance's own name.
            let Some(name) = first_identifier(instance, &["kParenGroup", "kUnpackedDimensions"])
            else {
                continue;
            };
            push(
                name,
                instantiated.map_or_else(|| ANY.to_string(), class_name),
            );
        }
    }

    Some(EntityStub {
        class_name: class_name(name),
        entity_name: name.to_string(),
        source_kind: "verilog",
        fields,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verible reads from disk, so a fixture has to be a real file.
    fn stubs(name: &str, source: &str) -> Result<Vec<EntityStub>, String> {
        let dir = std::env::temp_dir().join(format!("stubgen-verilog-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{name}.sv"));
        std::fs::write(&path, source).unwrap();
        parse(&path)
    }

    fn fields(stub: &EntityStub) -> Vec<(&str, &str)> {
        stub.fields
            .iter()
            .map(|f| (f.name.as_str(), f.py_type.as_str()))
            .collect()
    }

    #[test]
    fn extracts_ansi_ports_and_params() {
        let stubs = stubs(
            "adder",
            "module adder #(parameter WIDTH = 8) (\n\
             input  logic [WIDTH-1:0] x, // first\n\
             output logic [WIDTH-1:0] sum\n\
             );\nendmodule\n",
        )
        .unwrap();
        assert_eq!(stubs.len(), 1);
        assert_eq!(stubs[0].class_name, "Adder");
        assert_eq!(
            fields(&stubs[0]),
            [("WIDTH", ANY), ("x", ANY), ("sum", ANY)]
        );
    }

    #[test]
    fn block_comments_do_not_hide_modules() {
        let stubs = stubs(
            "real_one",
            "/* module ghost (); */ module real_one (input a);\nendmodule\n",
        )
        .unwrap();
        assert_eq!(stubs.len(), 1);
        assert_eq!(stubs[0].entity_name, "real_one");
    }

    /// The regex generator this replaced matched only the ANSI form and
    /// emitted a module with no ports at all here.
    #[test]
    fn non_ansi_ports_are_extracted() {
        let stubs = stubs(
            "nonansi",
            "module nonansi (a, b, c);\n\
             input a;\n\
             input [7:0] b;\n\
             output reg c;\n\
             endmodule\n",
        )
        .unwrap();
        assert_eq!(fields(&stubs[0]), [("a", ANY), ("b", ANY), ("c", ANY)]);
    }

    /// Verible does not preprocess, so the ports behind a macro are unknown.
    /// Emitting nothing is the point — the regex generator emitted one port
    /// literally named `PORTS`, which no testbench could ever poke.
    #[test]
    fn macro_ports_are_skipped_rather_than_guessed() {
        let stubs = stubs(
            "macros",
            "`define PORTS input clk, output q\n\
             module macros (`PORTS);\nendmodule\n",
        )
        .unwrap();
        assert_eq!(stubs.len(), 1);
        assert_eq!(fields(&stubs[0]), []);
    }

    #[test]
    fn localparams_are_not_generics() {
        let stubs = stubs(
            "lp",
            "module lp #(parameter W = 8, localparam D = 4) ();\nendmodule\n",
        )
        .unwrap();
        assert_eq!(fields(&stubs[0]), [("W", ANY)]);
    }

    #[test]
    fn instantiation_becomes_a_field_typed_by_the_instantiated_module() {
        let stubs = stubs(
            "wrap",
            "module wrap (input clk);\n\
             counter_reg u_counter (.clk(clk));\n\
             endmodule\n",
        )
        .unwrap();
        assert_eq!(
            fields(&stubs[0]),
            [("clk", ANY), ("u_counter", "CounterReg")]
        );
    }

    #[test]
    fn nets_and_variables_are_included_but_not_confused_with_instances() {
        let stubs = stubs(
            "internals",
            "module internals (input clk);\n\
             wire idle;\n\
             logic [7:0] scratch;\n\
             sub u_sub ();\n\
             endmodule\n",
        )
        .unwrap();
        assert_eq!(
            fields(&stubs[0]),
            [
                ("clk", ANY),
                ("idle", ANY),
                ("scratch", ANY),
                ("u_sub", "Sub"),
            ]
        );
    }

    #[test]
    fn instantiations_inside_generates_are_flattened_in() {
        let stubs = stubs(
            "gen",
            "module gen ();\n\
             genvar i;\n\
             generate\n\
               for (i = 0; i < 2; i++) begin : g\n\
                 leaf u_leaf ();\n\
               end\n\
             endgenerate\n\
             endmodule\n",
        )
        .unwrap();
        let names: Vec<&str> = stubs[0].fields.iter().map(|f| f.name.as_str()).collect();
        assert!(names.contains(&"u_leaf"), "{names:?}");
    }

    #[test]
    fn multiple_modules_in_one_file() {
        let stubs = stubs(
            "pair",
            "module first (input a);\nendmodule\n\
             module second (input b);\nendmodule\n",
        )
        .unwrap();
        let names: Vec<&str> = stubs.iter().map(|s| s.class_name.as_str()).collect();
        assert_eq!(names, ["First", "Second"]);
    }

    #[test]
    fn syntax_errors_fail_rather_than_emitting_a_truncated_stub() {
        let err = stubs("broken", "module broken (input a\nendmodule\n").unwrap_err();
        assert!(err.contains("verilog parse error"), "{err}");
    }
}
