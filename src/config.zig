const std = @import("std");

pub const Priority = enum { interactive, standard, batch };

pub const Kind = enum {
    chat,
    embedding,
};

pub const MatambaParseError = std.json.ParseError(std.json.Scanner) || std.mem.Allocator.Error || error{ NoModels, InvalidBudget, DuplicateName, UnknownAliasTarget, AliasCycle };

pub const Model = struct {
    name: []const u8,
    gguf_path: []const u8,
    n_ctx: u32,
    n_parallel: u8,
    kind: Kind,
};

pub const Alias = struct { name: []const u8, targets: []const []const u8 };

pub const Listen = struct { host: []const u8 = "127.0.0.1", port: u16 = 8080 };

pub const Team = struct { name: []const u8 };

pub const User = struct { name: []const u8, teams: []const []const u8, priority: Priority };

pub const Config = struct { listen: Listen = .{}, memory_budget_mb: u32, models: []const Model, aliases: []const Alias = &.{}, users: []const User = &.{}, teams: []const Team = &.{} };

pub fn contains(names: []const []const u8, target: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, target)) {
            return true;
        }
    }
    return false;
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) MatambaParseError!std.json.Parsed(Config) {
    const parsed = try std.json.parseFromSlice(Config, allocator, bytes, .{ .allocate = .alloc_always });

    var dups = std.StringHashMapUnmanaged(Model){};
    defer dups.deinit(allocator);
    errdefer parsed.deinit();

    for (parsed.value.models) |value| {
        const model_exists = try dups.getOrPut(allocator, value.name);
        if (model_exists.found_existing) {
            return MatambaParseError.DuplicateName;
        }
    }

    for (parsed.value.aliases) |value| {
        const model_exists = try dups.getOrPut(allocator, value.name);
        if (model_exists.found_existing) {
            return MatambaParseError.DuplicateName;
        }
    }

    for (parsed.value.aliases) |alias| {
        for (alias.targets) |target| {
            if (std.mem.eql(u8, alias.name, target)) {
                return MatambaParseError.AliasCycle;
            }
        }
    }

    for (parsed.value.aliases) |alias| {
        for (alias.targets) |target| {
            _ = dups.get(target) orelse return MatambaParseError.UnknownAliasTarget;
        }
    }

    for (parsed.value.teams) |value| {
        const model_exists = try dups.getOrPut(allocator, value.name);
        if (model_exists.found_existing) {
            return MatambaParseError.DuplicateName;
        }
    }

    if (parsed.value.models.len == 0) {
        return MatambaParseError.NoModels;
    }

    if (parsed.value.memory_budget_mb == 0) {
        return MatambaParseError.InvalidBudget;
    }

    return parsed;
}
