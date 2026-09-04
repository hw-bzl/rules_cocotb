"""Expose `verible-verilog-syntax` from the registered Verible toolchain."""

VERIBLE_TOOLCHAIN_TYPE = str(Label("@rules_verible//verible:toolchain_type"))

def _verible_syntax_impl(ctx):
    toolchain = ctx.toolchains[VERIBLE_TOOLCHAIN_TYPE]

    # An executable rule owns `ctx.outputs.executable` and has to write it
    # itself, so the toolchain's binary is symlinked rather than forwarded.
    # The symlink is also what makes the label stable: the underlying file
    # lives at a different path in each of the five per-platform repos.
    ctx.actions.symlink(
        output = ctx.outputs.executable,
        target_file = toolchain.verible_syntax,
        is_executable = True,
    )

    return [DefaultInfo(
        executable = ctx.outputs.executable,
        files = depset([ctx.outputs.executable]),
        runfiles = ctx.runfiles(files = [toolchain.verible_syntax]),
    )]

verible_syntax = rule(
    doc = """\
Resolve the registered `verible_toolchain` and expose only its
`verible-verilog-syntax` binary.

`stubgen` parses Verilog by shelling out to
`verible-verilog-syntax --printtree --export_json` and needs nothing else
from Verible, so this narrows the toolchain to that one binary rather than
forwarding all four. `@rules_verible//verible:current_verible_toolchain`
would pull the other three into every `CocotbStubgen` action's inputs, and
its `runfiles` omits `verible-verilog-syntax` anyway.
""",
    implementation = _verible_syntax_impl,
    executable = True,
    toolchains = [VERIBLE_TOOLCHAIN_TYPE],
)
