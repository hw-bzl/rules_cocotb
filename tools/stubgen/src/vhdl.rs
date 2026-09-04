//! VHDL extraction via `vhdl_lang`'s parser.
//!
//! Parse-only: [`VHDLParser`] builds a syntax tree without loading `STD` /
//! `IEEE` or resolving names. That is enough because the stub output is a
//! coarse classification into eight cocotb handle classes, discriminated by
//! the terminal type mark, which the standard fixes. Full elaboration would
//! additionally resolve project-local aliases and subtypes — see
//! `cocotb_toolchain.vhdl_libraries`.

use std::collections::HashMap;
use std::path::Path;

use vhdl_lang::ast::{
    AnyDesignUnit, AnyPrimaryUnit, AnySecondaryUnit, ArchitectureBody, ConcurrentStatement,
    Declaration, EntityDeclaration, InstantiatedUnit, InterfaceDeclaration, InterfaceList,
    LabeledConcurrentStatement, ModeIndication, Name, ObjectClass, SubtypeIndication,
};
use vhdl_lang::{Diagnostic, Severity, SeverityMap, Source, VHDLParser, VHDLStandard};

use crate::stub::{class_name, EntityStub, Field};
use crate::types::{vhdl_type, ANY};

/// Extra fields an architecture contributes to its entity, keyed by the
/// lower-cased entity name (VHDL identifiers are case-insensitive).
#[derive(Default)]
struct ArchFields {
    signals: Vec<Field>,
    instances: Vec<Field>,
}

pub fn parse(path: &Path) -> Result<Vec<EntityStub>, String> {
    let source =
        Source::from_latin1_file(path).map_err(|err| format!("{}: {}", path.display(), err))?;
    parse_source(&source)
}

fn parse_source(source: &Source) -> Result<Vec<EntityStub>, String> {
    let path = source.file_name();
    let parser = VHDLParser::new(VHDLStandard::default());
    let mut diagnostics: Vec<Diagnostic> = Vec::new();
    let design_file = parser.parse_design_source(source, &mut diagnostics);

    // A syntax error leaves the tree truncated, which would silently emit a
    // stub missing whatever followed. rules_vhdl hands the same sources to a
    // simulator, so anything that fails here would fail the build regardless.
    // A `Diagnostic` carries an `ErrorCode` rather than a severity; the
    // mapping between the two is the `SeverityMap` a language server would let
    // the user configure. The default map is the right one here — a build
    // should not be able to demote a syntax error to a warning.
    let severities = SeverityMap::default();
    let errors: Vec<&Diagnostic> = diagnostics
        .iter()
        .filter(|d| severities[d.code] == Some(Severity::Error))
        .collect();
    if !errors.is_empty() {
        let mut report = format!("{}: failed to parse VHDL", path.display());
        for diagnostic in errors {
            report.push_str(&format!("\n  {}", diagnostic.message));
        }
        return Err(report);
    }

    let mut arch_fields: HashMap<String, ArchFields> = HashMap::new();
    // Architectures are collected first so their fields can be appended to
    // the owning entity's own ports in a single pass below. VHDL permits an
    // architecture to precede its entity in file order only across files, but
    // collecting up front costs nothing and removes the ordering question.
    for (_, unit) in &design_file.design_units {
        if let AnyDesignUnit::Secondary(AnySecondaryUnit::Architecture(arch)) = unit {
            collect_architecture(arch, &mut arch_fields);
        }
    }

    let mut stubs = Vec::new();
    for (_, unit) in &design_file.design_units {
        if let AnyDesignUnit::Primary(AnyPrimaryUnit::Entity(entity)) = unit {
            stubs.push(entity_stub(entity, &arch_fields));
        }
    }
    Ok(stubs)
}

fn entity_stub(
    entity: &EntityDeclaration,
    arch_fields: &HashMap<String, ArchFields>,
) -> EntityStub {
    let name = entity.ident.tree.item.to_string();

    let mut fields = Vec::new();
    for clause in [&entity.generic_clause, &entity.port_clause]
        .into_iter()
        .flatten()
    {
        collect_interface(clause, &mut fields);
    }

    // Signals before instances, matching how the two are declared: an
    // architecture's declarative part precedes its statement part.
    if let Some(extra) = arch_fields.get(&name.to_lowercase()) {
        fields.extend(extra.signals.iter().cloned());
        fields.extend(extra.instances.iter().cloned());
    }

    EntityStub {
        class_name: class_name(&name),
        entity_name: name,
        source_kind: "vhdl",
        fields,
    }
}

fn collect_interface(list: &InterfaceList, fields: &mut Vec<Field>) {
    for item in &list.items {
        // Only object interfaces (signals, constants, variables) become
        // handles. Interface types, subprograms and packages are generics
        // that carry no runtime object for cocotb to expose.
        let InterfaceDeclaration::Object(object) = item else {
            continue;
        };
        let ModeIndication::Simple(mode) = &object.mode else {
            // A view mode (`port p : view v`) names a mode view rather than a
            // subtype, so there is no type mark to classify.
            for ident in &object.idents {
                fields.push(Field {
                    name: ident.tree.item.to_string(),
                    py_type: ANY.to_string(),
                });
            }
            continue;
        };
        let py_type = subtype_py_type(&mode.subtype_indication);
        for ident in &object.idents {
            fields.push(Field {
                name: ident.tree.item.to_string(),
                py_type: py_type.to_string(),
            });
        }
    }
}

fn collect_architecture(arch: &ArchitectureBody, out: &mut HashMap<String, ArchFields>) {
    let entity = arch.entity_name.item.item.to_string().to_lowercase();
    let entry = out.entry(entity).or_default();

    for declaration in &arch.decl {
        let Declaration::Object(object) = &declaration.item else {
            continue;
        };
        if object.class != ObjectClass::Signal {
            continue;
        }
        let py_type = subtype_py_type(&object.subtype_indication);
        for ident in &object.idents {
            entry.signals.push(Field {
                name: ident.tree.item.to_string(),
                py_type: py_type.to_string(),
            });
        }
    }

    collect_instances(&arch.statements, entry);
}

/// Walk concurrent statements for component / entity instantiations.
///
/// Recurses through blocks and generate statements: cocotb exposes an
/// instance inside a generate as a child of the generate handle rather than
/// of the architecture, so the flattening here is a simplification. It keeps
/// the generated attribute present (typed) instead of absent, which is the
/// friendlier failure mode for a stub whose purpose is autocompletion.
fn collect_instances(statements: &[LabeledConcurrentStatement], entry: &mut ArchFields) {
    for statement in statements {
        match &statement.statement.item {
            ConcurrentStatement::Instance(instance) => {
                // An unlabelled instantiation is illegal VHDL, but the parser
                // is lenient enough to produce one; there is no attribute name
                // to emit without a label.
                let Some(label) = statement.label.tree.as_ref() else {
                    continue;
                };
                let unit = match &instance.unit {
                    InstantiatedUnit::Component(name)
                    | InstantiatedUnit::Entity(name, _)
                    | InstantiatedUnit::Configuration(name) => suffix(&name.item),
                };
                entry.instances.push(Field {
                    name: label.item.to_string(),
                    py_type: unit.map_or_else(|| ANY.to_string(), |n| class_name(&n)),
                });
            }
            ConcurrentStatement::Block(block) => collect_instances(&block.statements, entry),
            ConcurrentStatement::ForGenerate(generate) => {
                collect_instances(&generate.body.statements, entry);
            }
            ConcurrentStatement::IfGenerate(generate) => {
                for conditional in &generate.conds.conditionals {
                    collect_instances(&conditional.item.statements, entry);
                }
                if let Some(default) = &generate.conds.else_item {
                    collect_instances(&default.0.statements, entry);
                }
            }
            ConcurrentStatement::CaseGenerate(generate) => {
                for alternative in &generate.sels.alternatives {
                    collect_instances(&alternative.item.statements, entry);
                }
            }
            _ => {}
        }
    }
}

fn subtype_py_type(subtype: &SubtypeIndication) -> &'static str {
    suffix(&subtype.type_mark.item).map_or(ANY, |mark| vhdl_type(&mark))
}

/// The terminal identifier of a (possibly selected or indexed) name.
///
/// `ieee.std_logic_1164.std_logic` -> `std_logic`, and
/// `string(1 to 8)` -> `string`.
fn suffix(name: &Name) -> Option<String> {
    match name {
        Name::Designator(designator) => Some(designator.item.to_string()),
        Name::Selected(_, suffix) => Some(suffix.item.item.to_string()),
        Name::CallOrIndexed(call) => self::suffix(&call.name.item),
        Name::Slice(prefix, _) => self::suffix(&prefix.item),
        Name::SelectedAll(_) | Name::Attribute(_) | Name::External(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stubs(src: &str) -> Vec<EntityStub> {
        parse_source(&Source::inline(Path::new("test.vhd"), src)).unwrap()
    }

    /// `name -> py_type`, in declaration order.
    fn fields(stub: &EntityStub) -> Vec<(&str, &str)> {
        stub.fields
            .iter()
            .map(|f| (f.name.as_str(), f.py_type.as_str()))
            .collect()
    }

    #[test]
    fn entity_generics_and_ports() {
        let stubs = stubs(
            "
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
                data_out : out std_logic_vector(G_DATA_WIDTH-1 downto 0)
              );
            end entity;
            ",
        );
        assert_eq!(stubs.len(), 1);
        assert_eq!(stubs[0].class_name, "SlrBroadcast");
        assert_eq!(stubs[0].source_kind, "vhdl");
        assert_eq!(
            fields(&stubs[0]),
            [
                ("G_DATA_WIDTH", "IntegerObject"),
                ("G_NUM_SLRS", "IntegerObject"),
                ("clk_in", "LogicObject"),
                ("rst_n_in", "LogicObject"),
                ("data_out", "LogicArrayObject"),
            ]
        );
    }

    #[test]
    fn selected_type_marks_resolve_to_their_suffix() {
        let stubs = stubs(
            "
            entity dummy is
              port (
                clk : in ieee.std_logic_1164.std_logic;
                txt : in work.pkg.string(1 to 8)
              );
            end entity;
            ",
        );
        assert_eq!(fields(&stubs[0]), [("clk", "LogicObject"), ("txt", "Any")]);
    }

    #[test]
    fn non_standard_type_marks_fall_back_to_any() {
        // Records, and project-local aliases a parse-only run cannot resolve.
        let stubs = stubs(
            "
            entity dummy is
              port (
                s_axil_in  : in  axil_peripheral_in_t;
                s_axil_out : out axil_peripheral_out_t;
                vec        : in  logic_1d(7 downto 0)
              );
            end entity;
            ",
        );
        assert!(stubs[0].fields.iter().all(|f| f.py_type == ANY));
    }

    #[test]
    fn multiple_entities_in_one_file() {
        let stubs = stubs(
            "
            entity foo is
              port (clk_in : in std_logic);
            end entity;

            entity bar is
              generic (G_WIDTH : natural := 8);
            end entity;
            ",
        );
        let names: Vec<&str> = stubs.iter().map(|s| s.class_name.as_str()).collect();
        assert_eq!(names, ["Foo", "Bar"]);
    }

    #[test]
    fn architecture_signals_are_included_but_constants_are_not() {
        let stubs = stubs(
            "
            entity dut_tb is
              generic (G_WIDTH : positive := 8);
            end entity;

            architecture tb of dut_tb is
              constant C_CLK_PERIOD : time := 10 ns;
              signal clk_in, rst_n_in : std_logic := '0';
              signal data_bus : std_logic_vector(G_WIDTH-1 downto 0);
              signal axil_in  : axil_peripheral_in_t;
            begin
            end architecture;
            ",
        );
        assert_eq!(
            fields(&stubs[0]),
            [
                ("G_WIDTH", "IntegerObject"),
                ("clk_in", "LogicObject"),
                ("rst_n_in", "LogicObject"),
                ("data_bus", "LogicArrayObject"),
                ("axil_in", "Any"),
            ]
        );
    }

    #[test]
    fn instantiation_becomes_a_field_typed_by_the_instantiated_entity() {
        let stubs = stubs(
            "
            entity slr_broadcast is
              generic (G_DATA_WIDTH : integer := 8);
            end entity;

            entity slr_broadcast_tb is
            end entity;

            architecture tb of slr_broadcast_tb is
            begin
              dut : entity work.slr_broadcast(rtl)
                generic map (G_DATA_WIDTH => 8);
              other : entity somelib.mystery(arch);
              comp : some_component port map (clk => clk);
            end architecture;
            ",
        );
        assert_eq!(
            fields(&stubs[1]),
            [
                ("dut", "SlrBroadcast"),
                ("other", "Mystery"),
                ("comp", "SomeComponent"),
            ]
        );
    }

    #[test]
    fn instantiations_inside_generates_are_flattened_in() {
        let stubs = stubs(
            "
            entity top is
            end entity;

            architecture rtl of top is
            begin
              g_for : for i in 0 to 3 generate
                lane : entity work.lane;
              end generate;

              g_if : if true generate
                yes : entity work.yes_unit;
              else generate
                no : entity work.no_unit;
              end generate;

              blk : block
              begin
                inner : entity work.inner_unit;
              end block;
            end architecture;
            ",
        );
        let names: Vec<&str> = stubs[0].fields.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, ["lane", "yes", "no", "inner"]);
    }

    #[test]
    fn attribute_specification_does_not_synthesize_a_field() {
        // The Python generator's instance regex would pluck `foo : entity is`
        // out of this and attach a spurious `foo` field. A real parser cannot.
        let stubs = stubs(
            "
            entity foo is
            end entity;

            architecture rtl of foo is
              attribute foreign of foo : entity is \"vhpi (my_pkg,my_impl)\";
            begin
            end architecture;
            ",
        );
        assert!(stubs[0].fields.is_empty(), "{:?}", stubs[0].fields);
    }

    #[test]
    fn syntax_errors_fail_rather_than_emitting_a_truncated_stub() {
        let err = parse_source(&Source::inline(
            Path::new("bad.vhd"),
            "entity broken is port (clk : in std_logic",
        ))
        .unwrap_err();
        assert!(err.contains("failed to parse VHDL"), "{err}");
    }
}
