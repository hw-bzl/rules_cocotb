//! Generate cocotb DUT stub classes from HDL sources.
//!
//! Reads HDL files (VHDL or Verilog / SystemVerilog), extracts each top-level
//! entity or module's port + generic list (plus VHDL architecture signals and
//! instantiations), and emits one Python module per source with a
//! `cocotb.handle.HierarchyObject` subclass per entity. Downstream cocotb
//! tests annotate the DUT parameter directly:
//!
//! ```python
//! from my_dut_stubs import MyDut
//!
//! async def test(dut: MyDut) -> None:
//!     dut.clk.value = 0
//! ```
//!
//! Subclassing `HierarchyObject` (rather than `typing.Protocol`) means the
//! generated class IS-A `HierarchyObject`, which is what cocotb passes the
//! test at runtime — so the type hint checks out without any `cast()` on the
//! test author's part.

mod cli;
mod render;
mod stub;
mod types;
mod verilog;
mod vhdl;

use std::collections::HashMap;
use std::path::Path;
use std::process::ExitCode;

use clap::Parser;

use crate::cli::Args;
use crate::stub::EntityStub;

fn main() -> ExitCode {
    let args = Args::parse();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("stubgen: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Process every `--stub` entry in one invocation — the calling aspect passes
/// one per HDL source in the library. Batching a library's sources into one
/// process lets sibling cross-references resolve in memory instead of needing
/// a second Bazel action pass.
fn run(args: &Args) -> Result<(), String> {
    let entries = args.stubs();
    if entries.is_empty() {
        return Ok(());
    }

    // Phase 1: parse each source, write its metadata, and thread the
    // just-written class names into the dep map so sibling sources see them.
    // Local (same-source) class names still win in `render`, so a
    // self-reference stays untyped-by-import as intended.
    let mut dep_metadata = load_dep_metadata(&args.dep_metadata)?;
    let mut per_src: Vec<(&Path, Vec<EntityStub>)> = Vec::new();
    for entry in &entries {
        let stubs = extract(&entry.src)?;
        write_metadata(&entry.metadata, &entry.module_import_path, &stubs)?;
        for stub in &stubs {
            dep_metadata
                .entry(stub.class_name.clone())
                .or_insert_with(|| entry.module_import_path.clone());
        }
        per_src.push((&entry.output, stubs));
    }

    // Phase 2: render each `.py` against the combined map.
    for (output, stubs) in &per_src {
        let rendered = render::render(stubs, &dep_metadata)?;
        std::fs::write(output, rendered).map_err(|err| format!("{}: {}", output.display(), err))?;
    }
    Ok(())
}

fn extract(path: &Path) -> Result<Vec<EntityStub>, String> {
    let extension = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match extension.as_str() {
        "vhd" | "vhdl" => vhdl::parse(path),
        "v" | "sv" | "svh" | "vh" => verilog::parse(path),
        _ => Err(format!("unrecognised HDL extension: {}", path.display())),
    }
}

/// Emit the sibling `.json` metadata file downstream stubgen runs consume.
///
/// Internal and tool-owned: the same binary writes and reads this within one
/// Bazel build, so the schema is only what a consumer needs in order to write
/// `from <module_import_path> import <ClassName>` for a cross-file reference.
fn write_metadata(
    path: &Path,
    module_import_path: &str,
    stubs: &[EntityStub],
) -> Result<(), String> {
    let mut class_names: Vec<&str> = stubs.iter().map(|s| s.class_name.as_str()).collect();
    class_names.sort_unstable();
    let data = serde_json::json!({
        "class_names": class_names,
        "module_import_path": module_import_path,
    });
    let mut text = serde_json::to_string_pretty(&data)
        .map_err(|err| format!("{}: {}", path.display(), err))?;
    text.push('\n');
    std::fs::write(path, text).map_err(|err| format!("{}: {}", path.display(), err))
}

/// Merge dep metadata files into a `class_name -> module_import_path` map.
///
/// First-seen wins on collision, matching Python's `from x import Y` /
/// `from z import Y` shadowing, and keeping the merge deterministic given the
/// stable input order Bazel's depset ordering provides. A cross-module
/// collision warns on stderr so a common name like `Fifo` does not silently
/// resolve to whichever library Bazel happened to visit first.
fn load_dep_metadata(paths: &[std::path::PathBuf]) -> Result<HashMap<String, String>, String> {
    let mut dep_metadata: HashMap<String, String> = HashMap::new();
    for path in paths {
        let text =
            std::fs::read_to_string(path).map_err(|err| format!("{}: {}", path.display(), err))?;
        let data: serde_json::Value =
            serde_json::from_str(&text).map_err(|err| format!("{}: {}", path.display(), err))?;
        let module = data["module_import_path"]
            .as_str()
            .ok_or_else(|| format!("{}: missing `module_import_path`", path.display()))?;
        let class_names = data["class_names"]
            .as_array()
            .ok_or_else(|| format!("{}: missing `class_names`", path.display()))?;
        for class_name in class_names {
            let Some(class_name) = class_name.as_str() else {
                return Err(format!("{}: non-string in `class_names`", path.display()));
            };
            match dep_metadata.get(class_name) {
                None => {
                    dep_metadata.insert(class_name.to_string(), module.to_string());
                }
                Some(existing) if existing != module => {
                    eprintln!(
                        "stubgen: warning: dep-metadata class '{class_name}' defined in both \
                         '{existing}' and '{module}'; using '{existing}'."
                    );
                }
                Some(_) => {}
            }
        }
    }
    Ok(dep_metadata)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn write(dir: &Path, name: &str, module: &str, class_names: &[&str]) -> PathBuf {
        let path = dir.join(name);
        let data = serde_json::json!({
            "class_names": class_names,
            "module_import_path": module,
        });
        std::fs::write(&path, serde_json::to_string(&data).unwrap()).unwrap();
        path
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("stubgen-test-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn metadata_is_deterministic_and_sorted() {
        let dir = tmpdir("metadata");
        let path = dir.join("m.json");
        write_metadata(
            &path,
            "pkg.x",
            &[
                EntityStub {
                    class_name: "Zebra".into(),
                    entity_name: "zebra".into(),
                    source_kind: "vhdl",
                    fields: vec![],
                },
                EntityStub {
                    class_name: "Alpha".into(),
                    entity_name: "alpha".into(),
                    source_kind: "vhdl",
                    fields: vec![],
                },
            ],
        )
        .unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "{\n  \"class_names\": [\n    \"Alpha\",\n    \"Zebra\"\n  ],\n  \
             \"module_import_path\": \"pkg.x\"\n}\n"
        );
    }

    #[test]
    fn dep_metadata_collision_resolves_first_seen_wins() {
        let dir = tmpdir("collision");
        let a = write(&dir, "a.json", "lib.a", &["Fifo"]);
        let b = write(&dir, "b.json", "lib.b", &["Fifo"]);
        let merged = load_dep_metadata(&[a, b]).unwrap();
        assert_eq!(merged["Fifo"], "lib.a");
    }

    #[test]
    fn dep_metadata_merges_distinct_classes() {
        let dir = tmpdir("merge");
        let a = write(&dir, "a.json", "lib.a", &["Foo"]);
        let b = write(&dir, "b.json", "lib.b", &["Bar"]);
        let merged = load_dep_metadata(&[a, b]).unwrap();
        assert_eq!(merged["Foo"], "lib.a");
        assert_eq!(merged["Bar"], "lib.b");
    }

    #[test]
    fn malformed_dep_metadata_is_an_error() {
        let dir = tmpdir("malformed");
        let path = dir.join("bad.json");
        std::fs::write(&path, "{\"class_names\": [\"Foo\"]}").unwrap();
        let err = load_dep_metadata(&[path]).unwrap_err();
        assert!(err.contains("missing `module_import_path`"), "{err}");
    }

    #[test]
    fn unrecognised_extension_is_an_error() {
        let err = extract(Path::new("thing.txt")).unwrap_err();
        assert!(err.contains("unrecognised HDL extension"), "{err}");
    }
}
