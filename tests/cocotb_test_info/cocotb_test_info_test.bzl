"""Analysis tests for `CocotbTestInfo`."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//cocotb:defs.bzl", "CocotbTestInfo")

def _cocotb_test_info_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[CocotbTestInfo]

    asserts.equals(env, ctx.attr.sim, info.sim)
    asserts.equals(env, ctx.attr.module.label, info.module.label)
    asserts.equals(env, ["WIDTH=8"], info.params)
    asserts.equals(env, ctx.attr.sim_opts, info.sim_opts)
    asserts.equals(env, ctx.attr.build_sources, [f.basename for f in info.build_sources])

    return analysistest.end(env)

cocotb_test_info_test = analysistest.make(
    _cocotb_test_info_test_impl,
    attrs = {
        "build_sources": attr.string_list(doc = "The basenames `build_sources` should hold."),
        "module": attr.label(doc = "The module `module` should be."),
        "sim": attr.string(doc = "The simulator `sim` should be."),
        "sim_opts": attr.string_list(doc = "What `sim_opts` should be."),
    },
)
