const std = @import("std");
const hikko = @import("hikkoshi");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try run(allocator, args);
}

fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    if (args.len <= 1) {
        try printUsage(stderr);
        return;
    }

    var idx: usize = 1;
    var override_config_path: ?[]const u8 = null;

    // Optional global flag: --config <path>
    if (idx < args.len and std.mem.eql(u8, args[idx], "--config")) {
        if (idx + 1 >= args.len) {
            try stderr.writeAll("hikkoshi: --config requires a path argument\n");
            try printUsage(stderr);
            return;
        }
        override_config_path = args[idx + 1];
        idx += 2;
    }

    if (idx >= args.len) {
        try printUsage(stderr);
        return;
    }

    const cmd = args[idx];

    if (std.mem.eql(u8, cmd, "list")) {
        try cmdList(allocator, override_config_path);
        return;
    } else if (std.mem.eql(u8, cmd, "show")) {
        if (idx + 1 >= args.len) {
            try stderr.writeAll("hikkoshi: show requires a profile name\n");
            return;
        }
        const profile_name = args[idx + 1];
        try cmdShow(allocator, override_config_path, profile_name);
        return;
    } else if (std.mem.eql(u8, cmd, "config-path")) {
        try cmdConfigPath(allocator, override_config_path);
        return;
    } else if (std.mem.eql(u8, cmd, "example")) {
        try cmdExample();
        return;
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printUsage(stderr);
        return;
    }

    // Otherwise: treat as profile name.
    const profile_name = cmd;
    if (idx + 1 >= args.len) {
        try stderr.writeAll("hikkoshi: missing command to run\n");
        try printUsage(stderr);
        return;
    }

    const child_argv = args[idx + 1 ..];
    try cmdRunProfile(allocator, override_config_path, profile_name, child_argv);
}

fn cmdList(allocator: std.mem.Allocator, override_config_path: ?[]const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const config_path = hikko.resolveConfigPath(allocator, override_config_path) catch |err| {
        switch (err) {
            error.HomeNotSet => {
                try stderr.writeAll(
                    "hikkoshi: HOME is not set and no config path is specified\n",
                );
                return;
            },
            else => return err,
        }
    };
    defer allocator.free(config_path);

    var cfg = hikko.loadConfig(allocator, config_path) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print(
                "hikkoshi: config file not found at '{s}'\n",
                .{config_path},
            );
            try stderr.writeAll(
                "hint: create one with `hikkoshi example > ~/.config/hikkoshi/config.toml`\n",
            );
            return;
        }
        return err;
    };
    defer cfg.deinit();

    const names = try hikko.collectProfileNames(&cfg, allocator);
    defer allocator.free(names);

    std.sort.block([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (names) |name| {
        try stdout.print("{s}\n", .{name});
    }
}

fn cmdShow(
    allocator: std.mem.Allocator,
    override_config_path: ?[]const u8,
    profile_name: []const u8,
) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const config_path = hikko.resolveConfigPath(allocator, override_config_path) catch |err| {
        switch (err) {
            error.HomeNotSet => {
                try stderr.writeAll(
                    "hikkoshi: HOME is not set and no config path is specified\n",
                );
                return;
            },
            else => return err,
        }
    };
    defer allocator.free(config_path);

    var cfg = hikko.loadConfig(allocator, config_path) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print(
                "hikkoshi: config file not found at '{s}'\n",
                .{config_path},
            );
            try stderr.writeAll(
                "hint: create one with `hikkoshi example > ~/.config/hikkoshi/config.toml`\n",
            );
            return;
        }
        return err;
    };
    defer cfg.deinit();

    const profile = hikko.findProfile(&cfg, profile_name) orelse {
        try stderr.print("hikkoshi: profile '{s}' not found\n", .{profile_name});

        const names = try hikko.collectProfileNames(&cfg, allocator);
        defer allocator.free(names);
        if (names.len > 0) {
            try stderr.writeAll("available profiles:\n");
            std.sort.block([]const u8, names, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            for (names) |name| {
                try stderr.print("  {s}\n", .{name});
            }
        }
        return;
    };

    var env_map = try hikko.buildEnvMapForProfile(allocator, profile);

    const home = env_map.get("HOME") orelse "";
    const xdg_config_home = env_map.get("XDG_CONFIG_HOME") orelse "";
    const xdg_data_home = env_map.get("XDG_DATA_HOME") orelse "";
    const xdg_cache_home = env_map.get("XDG_CACHE_HOME") orelse "";
    const xdg_state_home = env_map.get("XDG_STATE_HOME") orelse "";

    try stdout.print("profile: {s}\n", .{profile.name});
    try stdout.print("  HOME            = {s}\n", .{home});
    try stdout.print("  XDG_CONFIG_HOME = {s}\n", .{xdg_config_home});
    try stdout.print("  XDG_DATA_HOME   = {s}\n", .{xdg_data_home});
    try stdout.print("  XDG_CACHE_HOME  = {s}\n", .{xdg_cache_home});
    try stdout.print("  XDG_STATE_HOME  = {s}\n", .{xdg_state_home});

    if (profile.env.count() > 0) {
        try stdout.writeAll("  env:\n");
        var it = profile.env.iterator();
        while (it.next()) |entry| {
            try stdout.print("    {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
}

fn cmdConfigPath(allocator: std.mem.Allocator, override_config_path: ?[]const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const config_path = hikko.resolveConfigPath(allocator, override_config_path) catch |err| {
        switch (err) {
            error.HomeNotSet => {
                try stderr.writeAll(
                    "hikkoshi: HOME is not set and no config path is specified\n",
                );
                return;
            },
            else => return err,
        }
    };
    defer allocator.free(config_path);

    try stdout.print("{s}\n", .{config_path});
}

fn cmdExample() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try hikko.printExampleConfig(stdout);
}

fn cmdRunProfile(
    allocator: std.mem.Allocator,
    override_config_path: ?[]const u8,
    profile_name: []const u8,
    child_argv: []const []const u8,
) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    if (child_argv.len == 0) {
        try stderr.writeAll("hikkoshi: missing command to run\n");
        return;
    }

    const config_path = hikko.resolveConfigPath(allocator, override_config_path) catch |err| {
        switch (err) {
            error.HomeNotSet => {
                try stderr.writeAll(
                    "hikkoshi: HOME is not set and no config path is specified\n",
                );
                return;
            },
            else => return err,
        }
    };
    defer allocator.free(config_path);

    var cfg = hikko.loadConfig(allocator, config_path) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print(
                "hikkoshi: config file not found at '{s}'\n",
                .{config_path},
            );
            try stderr.writeAll(
                "hint: create one with `hikkoshi example > ~/.config/hikkoshi/config.toml`\n",
            );
            return;
        }
        return err;
    };
    defer cfg.deinit();

    const profile = hikko.findProfile(&cfg, profile_name) orelse {
        try stderr.print("hikkoshi: profile '{s}' not found\n", .{profile_name});
        return;
    };

    var env_map = try hikko.buildEnvMapForProfile(allocator, profile);

    var child = std.process.Child.init(child_argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.env_map = &env_map;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            std.process.exit(@intCast(code));
        },
        .Signal, .Stopped, .Unknown => {
            // Map abnormal terminations to a generic non-zero exit.
            std.process.exit(1);
        },
    }
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  hikkoshi [--config <path>] <profile> <command> [args...]
        \\  hikkoshi [--config <path>] list
        \\  hikkoshi [--config <path>] show <profile>
        \\  hikkoshi [--config <path>] config-path
        \\  hikkoshi example
        \\
        \\Options:
        \\  --config <path>   Use an explicit config file path instead of the default.
        \\
        \\Configuration:
        \\  Default config path is: $HOME/.config/hikkoshi/config.toml
        \\  Or override via the HIKKOSHI_CONFIG environment variable.
        \\
        \\TOML schema (per profile):
        \\  [profiles.<name>]
        \\  home   = \"~/profiles/<name>\"
        \\  # config = \"~/profiles/<name>/.config\"
        \\  # data   = \"~/profiles/<name>/.local/share\"
        \\  # cache  = \"~/profiles/<name>/.cache\"
        \\  # state  = \"~/profiles/<name>/.local/state\"
        \\
        \\  [profiles.<name>.env]
        \\  KEY = \"VALUE\"
        \\
    );
}
