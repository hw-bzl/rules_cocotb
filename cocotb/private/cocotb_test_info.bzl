"""CocotbTestInfo provider."""

CocotbTestInfo = provider(
    doc = ("What a `cocotb_test` builds its simulator from. A rule that " +
           "builds on an existing test reads it rather than repeating the " +
           "test's attributes. The test's runfiles are its `DefaultInfo`'s, " +
           "and its environment, including `COCOTB_TEST_ARGS_FILE`, its " +
           "`RunEnvironmentInfo`'s."),
    fields = {
        "build_sources": ("list[File]: The HDL sources the simulator builds " +
                          "at test time. Empty for a simulator built ahead " +
                          "of the test."),
        "module": "Target: The Verilog/VHDL module under test.",
        "params": "list[str]: Verilog parameters or VHDL generics.",
        "sim": ("str: The simulator the test resolved to, from `sim` or the " +
                "toolchain's default."),
        "sim_opts": "list[str]: The simulator's code-generation arguments.",
    },
)
