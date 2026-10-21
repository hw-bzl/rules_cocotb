"""cocotb_test"""

load(
    "//cocotb/private:cocotb_test.bzl",
    _cocotb_test = "cocotb_test",
)
load(
    "//cocotb/private:cocotb_test_info.bzl",
    _CocotbTestInfo = "CocotbTestInfo",
)

CocotbTestInfo = _CocotbTestInfo
cocotb_test = _cocotb_test
