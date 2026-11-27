const std = @import("std");
const Io = std.Io;

const cfg = @import("config.zig");

// pub fn main(init: std.process.Init) !void {}

test {
    _ = @import("config_test.zig");
}
