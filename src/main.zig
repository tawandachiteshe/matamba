const std = @import("std");
const Io = std.Io;
const ReadFileAllocError = Io.Dir.ReadFileAllocError;

const cfg = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args: []const []const u8 = try init.minimal.args.toSlice(arena);
    var std_out_buf: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &std_out_buf);
    const out = &stdout_writer.interface;

    if (args.len < 2) {
        std.log.err("usage: matamba <config.json>", .{});
        std.process.exit(1);
    }

    const config_path: []const u8 = args[1];

    const cwd = Io.Dir.cwd();
    const config_bytes = cwd.readFileAlloc(init.io, config_path, arena, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        switch (err) {
            ReadFileAllocError.FileNotFound => std.log.err("config file not found: {s} \n", .{config_path}),
            ReadFileAllocError.FileTooBig => std.log.err("config file too big \n", .{}),
            else => std.debug.print("Unknown error: {s} \n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };

    const parsed_cfg = cfg.parse(arena, config_bytes) catch |err| {
        switch (err) {
            cfg.MatambaParseError.AliasCycle => std.log.err("two aliases point at each other in a loop", .{}),
            else => std.log.err("An error occurred: {s}", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
    defer parsed_cfg.deinit();
    const config: cfg.Config = parsed_cfg.value;

    try out.print("loaded {d} models, {d} aliases, {d} teams, {d} users", .{ config.models.len, config.aliases.len, config.teams.len, config.users.len });
    try out.flush();
}

test {
    _ = @import("config_test.zig");
}
