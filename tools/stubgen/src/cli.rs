//! Command line parsing.

use std::path::PathBuf;

use clap::Parser;

/// Generate cocotb DUT stub classes from HDL sources.
#[derive(Debug, Parser)]
#[command(name = "stubgen", version, about, long_about = None)]
pub struct Args {
    /// One HDL source with its per-source outputs and dotted Python import
    /// path. Repeat once per source in the library.
    #[arg(
        long = "stub",
        value_names = ["SRC", "OUTPUT", "METADATA", "MODULE_IMPORT_PATH"],
        num_args = 4,
        action = clap::ArgAction::Append,
    )]
    stub: Vec<String>,

    /// A dependency library's `.json` metadata file. Class names found in
    /// these are typed rather than downgraded to `Any`.
    #[arg(long = "dep-metadata", value_name = "PATH")]
    pub dep_metadata: Vec<PathBuf>,

    /// A VHDL standard library source and the library name it belongs to.
    ///
    /// Accepted for interface parity with fully elaborating generators but
    /// unused here: this generator resolves types from the parse tree alone,
    /// keying off each port's terminal type mark.
    #[arg(
        long = "vhdl-library",
        value_names = ["NAME", "PATH"],
        num_args = 2,
        action = clap::ArgAction::Append,
    )]
    vhdl_library: Vec<String>,
}

/// One HDL source and where its two outputs go.
#[derive(Debug, PartialEq, Eq)]
pub struct StubEntry {
    pub src: PathBuf,
    pub output: PathBuf,
    pub metadata: PathBuf,
    pub module_import_path: String,
}

impl Args {
    /// The `--stub` groups, reassembled.
    ///
    /// clap flattens a repeated multi-value flag into one list, and `num_args`
    /// guarantees the length is a multiple of four, so chunking recovers the
    /// groups in the order they were passed.
    ///
    /// `slice::as_chunks` would destructure more cleanly, but it only
    /// stabilised in Rust 1.88 and consumers compile this tool with whatever
    /// toolchain they have registered.
    #[allow(clippy::chunks_exact_to_as_chunks)]
    pub fn stubs(&self) -> Vec<StubEntry> {
        self.stub
            .chunks_exact(4)
            .map(|group| StubEntry {
                src: group[0].clone().into(),
                output: group[1].clone().into(),
                metadata: group[2].clone().into(),
                module_import_path: group[3].clone(),
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(items: &[&str]) -> Result<Args, clap::Error> {
        Args::try_parse_from(std::iter::once("stubgen").chain(items.iter().copied()))
    }

    #[test]
    fn parses_repeated_flags_in_any_order() {
        let args = parse(&[
            "--dep-metadata",
            "a.json",
            "--stub",
            "x.vhd",
            "x.py",
            "x.json",
            "pkg.x",
            "--vhdl-library",
            "ieee",
            "std_logic_1164.vhd",
            "--stub",
            "y.vhd",
            "y.py",
            "y.json",
            "pkg.y",
        ])
        .unwrap();
        assert_eq!(args.dep_metadata, [PathBuf::from("a.json")]);
        let stubs = args.stubs();
        assert_eq!(stubs.len(), 2);
        assert_eq!(stubs[0].module_import_path, "pkg.x");
        assert_eq!(stubs[1].src, PathBuf::from("y.vhd"));
    }

    #[test]
    fn truncated_flag_group_is_an_error() {
        assert!(parse(&["--stub", "x.vhd", "x.py"]).is_err());
    }

    #[test]
    fn unknown_flag_is_an_error() {
        assert!(parse(&["--nope"]).is_err());
    }

    #[test]
    fn no_arguments_is_accepted() {
        assert!(parse(&[]).unwrap().stubs().is_empty());
    }
}
