// M0 test suite for src/config.zig (Zig 0.16).
// Put this file at src/config_test.zig and make sure `zig build test` reaches it
// (for example: `test { _ = @import("config_test.zig"); }` in config.zig or main.zig).
//
// Assumes: config.parse(gpa, bytes) returns a value with `.value: Config` and `.deinit()`,
// e.g. std.json.Parsed(Config). Adjust the two or three lines that touch `.value` if yours differs.
//
// Error names from std.json (UnknownField, InvalidEnumTag, MissingField, UnexpectedEndOfInput)
// are from memory. If 0.16 returns a different error, change the expectation to what the
// parser really returns: the point is that your code passes it through untouched.

const std = @import("std");
const config = @import("config.zig");
const testing = std.testing;

fn expectErr(expected: anyerror, src: []const u8) !void {
    if (config.parse(testing.allocator, src)) |ok| {
        var cfg = ok;
        cfg.deinit();
        std.debug.print("expected {s}, but parse succeeded\n", .{@errorName(expected)});
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

const model_a =
    \\{"name":"a","gguf_path":"/m/a.gguf","n_ctx":4096,"n_parallel":2,"kind":"chat"}
;
const model_b =
    \\{"name":"b","gguf_path":"/m/b.gguf","n_ctx":2048,"n_parallel":1,"kind":"embedding"}
;
const head = "{\"memory_budget_mb\":1000,\"models\":[" ++ model_a ++ "]";

// ---------------------------------------------------------------- happy paths

test "minimal config loads with defaults" {
    var cfg = try config.parse(testing.allocator, head ++ "}");
    defer cfg.deinit();
    try testing.expectEqualStrings("127.0.0.1", cfg.value.listen.host);
    try testing.expectEqual(@as(u16, 8080), cfg.value.listen.port);
    try testing.expectEqual(@as(usize, 1), cfg.value.models.len);
    try testing.expectEqual(@as(usize, 0), cfg.value.aliases.len);
    try testing.expectEqual(@as(usize, 0), cfg.value.teams.len);
    try testing.expectEqual(@as(usize, 0), cfg.value.users.len);
}

test "enums parse from their tag names" {
    var cfg = try config.parse(testing.allocator, "{\"memory_budget_mb\":1000,\"models\":[" ++ model_a ++ "," ++ model_b ++ "]}");
    defer cfg.deinit();
    try testing.expectEqual(config.Kind.chat, cfg.value.models[0].kind);
    try testing.expectEqual(config.Kind.embedding, cfg.value.models[1].kind);
}

test "full example config loads" {
    // Copy config.json to src/testdata/full.json (paths in @embedFile are relative to this file).
    var cfg = try config.parse(testing.allocator, @embedFile("testdata/full.json"));
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 3), cfg.value.models.len);
    try testing.expectEqual(@as(usize, 3), cfg.value.aliases.len);
    try testing.expectEqual(@as(usize, 2), cfg.value.teams.len);
    try testing.expectEqual(@as(usize, 2), cfg.value.users.len);
    try testing.expectEqual(config.Priority.batch, cfg.value.users[1].priority);
}

test "strings survive freeing the input buffer" {
    // Catches parsed strings pointing into the input (see ParseOptions.allocate).
    const gpa = testing.allocator;
    const buf = try gpa.dupe(u8, head ++ "}");
    var cfg = try config.parse(gpa, buf);
    defer cfg.deinit();
    @memset(buf, 'X');
    gpa.free(buf);
    try testing.expectEqualStrings("a", cfg.value.models[0].name);
    try testing.expectEqualStrings("/m/a.gguf", cfg.value.models[0].gguf_path);
}

test "alias chain through another alias is fine" {
    var cfg = try config.parse(testing.allocator, head ++
        \\,"aliases":[{"name":"x","targets":["y"]},{"name":"y","targets":["a"]}]}
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 2), cfg.value.aliases.len);
}

// ---------------------------------------------------------------- errors from std.json

test "truncated JSON keeps the parser's own error" {
    try expectErr(error.UnexpectedEndOfInput, "{\"memory_budget_mb\":1000,");
}

test "misspelled field is rejected" {
    try expectErr(error.UnknownField, "{\"memory_budget_mb\":1000,\"modles\":[" ++ model_a ++ "]}");
}

test "misspelled enum value is rejected" {
    try expectErr(error.InvalidEnumTag, "{\"memory_budget_mb\":1000,\"models\":[" ++
        \\{"name":"a","gguf_path":"/m/a.gguf","n_ctx":4096,"n_parallel":2,"kind":"chta"}
    ++ "]}");
}

test "required field missing" {
    try expectErr(error.MissingField, "{\"models\":[" ++ model_a ++ "]}");
}

// ---------------------------------------------------------------- your validation rules

test "no models" {
    try expectErr(error.NoModels, "{\"memory_budget_mb\":1000,\"models\":[]}");
}

test "zero memory budget" {
    // Add InvalidBudget to your error set for this one.
    try expectErr(error.InvalidBudget, "{\"memory_budget_mb\":0,\"models\":[" ++ model_a ++ "]}");
}

test "duplicate model name" {
    try expectErr(error.DuplicateName, "{\"memory_budget_mb\":1000,\"models\":[" ++ model_a ++ "," ++ model_a ++ "]}");
}

test "alias may not share a model's name" {
    try expectErr(error.DuplicateName, head ++
        \\,"aliases":[{"name":"a","targets":["a"]}]}
    );
}

test "duplicate team name" {
    try expectErr(error.DuplicateName, head ++
        \\,"teams":[{"name":"sales"},{"name":"sales"}]}
    );
}

test "unknown alias target" {
    try expectErr(error.UnknownAliasTarget, head ++
        \\,"aliases":[{"name":"fast","targets":["nope"]}]}
    );
}

test "alias pointing at itself is a cycle" {
    try expectErr(error.AliasCycle, head ++
        \\,"aliases":[{"name":"x","targets":["x"]}]}
    );
}

test "two-alias cycle" {
    try expectErr(error.AliasCycle, head ++
        \\,"aliases":[{"name":"x","targets":["y"]},{"name":"y","targets":["x","a"]}]}
    );
}

test "three-alias cycle hidden behind a valid target" {
    try expectErr(error.AliasCycle, head ++
        \\,"aliases":[{"name":"x","targets":["a","y"]},{"name":"y","targets":["z"]},{"name":"z","targets":["x"]}]}
    );
}

test "diamond is not a cycle" {
    // x -> y, x -> z, y -> a, z -> a: two paths to the same node is fine.
    var cfg = try config.parse(testing.allocator, head ++
        \\,"aliases":[{"name":"x","targets":["y","z"]},{"name":"y","targets":["a"]},{"name":"z","targets":["a"]}]}
    );
    defer cfg.deinit();
}

test "user in unknown team" {
    try expectErr(error.UnknownTeam, head ++
        \\,"users":[{"name":"t","teams":["hr"],"priority":"interactive"}]}
    );
}

test "invalid port" {
    try expectErr(error.InvalidPort, "{\"memory_budget_mb\":1000,\"listen\":{\"host\":\"0.0.0.0\",\"port\":0},\"models\":[" ++ model_a ++ "]}");
}
