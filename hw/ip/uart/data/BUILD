# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

package(default_visibility = ["//visibility:public"])

load("//rules:autogen.bzl", "autogen_hjson_header")

autogen_hjson_header(
    name = "uart_regs",
    srcs = [
        "uart.hjson",
    ],
)

filegroup(
    name = "all_files",
    srcs = glob(["**"]),
)
