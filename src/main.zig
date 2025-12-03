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
    } else if (std.mem.eql(u8, cmd, "add")) {
        if (idx + 1 >= args.len) {
            try stderr.writeAll("hikkoshi: add requires a home directory path\n");
            return;
        }
        const home_arg = args[idx + 1];
        const name_arg: ?[]const u8 = if (idx + 2 < args.len) args[idx + 2] else null;
        try cmdAddProfile(allocator, override_config_path, home_arg, name_arg);
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

    var cfg: hikko.Config = undefined;
    const have_cfg = try loadConfigOrPromptCreateFor(allocator, config_path, stderr, &cfg);
    if (!have_cfg) return;
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

    var cfg: hikko.Config = undefined;
    const have_cfg = try loadConfigOrPromptCreateFor(allocator, config_path, stderr, &cfg);
    if (!have_cfg) return;
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

fn deriveProfileNameFromHome(home_arg: []const u8) []const u8 {
    // Strip trailing slashes (but keep at least one character).
    var end = home_arg.len;
    while (end > 0 and home_arg[end - 1] == '/') {
        end -= 1;
    }
    if (end == 0) {
        return "";
    }

    var start: usize = 0;
    var i: usize = end;
    while (i > 0) {
        const ch = home_arg[i - 1];
        if (ch == '/') {
            start = i;
            break;
        }
        i -= 1;
    }

    return home_arg[start..end];
}

fn writeTomlSingleQuotedString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("'");
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (ch == '\'') {
            try writer.writeAll("''");
        } else {
            try writer.writeAll(&[_]u8{ch});
        }
    }
    try writer.writeAll("'");
}

fn cmdAddProfile(
    allocator: std.mem.Allocator,
    override_config_path: ?[]const u8,
    home_arg: []const u8,
    name_arg: ?[]const u8,
) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    if (home_arg.len == 0) {
        try stderr.writeAll("hikkoshi: add requires a non-empty home directory path\n");
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

    var cfg: hikko.Config = undefined;
    const have_cfg = try loadConfigOrPromptCreateFor(allocator, config_path, stderr, &cfg);
    if (!have_cfg) return;
    defer cfg.deinit();

    const profile_name = name_arg orelse deriveProfileNameFromHome(home_arg);
    if (profile_name.len == 0) {
        try stderr.writeAll(
            "hikkoshi: failed to derive profile name from home path\n",
        );
        return;
    }

    if (hikko.findProfile(&cfg, profile_name) != null) {
        try stderr.print("hikkoshi: profile '{s}' already exists\n", .{profile_name});
        return;
    }

    const existing = std.fs.cwd().readFileAlloc(allocator, config_path, std.math.maxInt(usize)) catch |err| {
        try stderr.print(
            "hikkoshi: failed to read config file '{s}': {s}\n",
            .{ config_path, @errorName(err) },
        );
        return err;
    };
    defer allocator.free(existing);

    var file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
        try stderr.print(
            "hikkoshi: failed to open config file '{s}' for writing: {s}\n",
            .{ config_path, @errorName(err) },
        );
        return err;
    };
    defer file.close();

    var file_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {};

    if (existing.len > 0) {
        try out.writeAll(existing);
        if (existing[existing.len - 1] != '\n') {
            try out.writeAll("\n");
        }
        try out.writeAll("\n");
    }

    try out.print("[profiles.{s}]\n", .{profile_name});
    try out.writeAll("home   = ");
    try writeTomlSingleQuotedString(out, home_arg);
    try out.writeAll("\n");

    try stdout.print(
        "hikkoshi: added profile '{s}' with home '{s}' to config '{s}'\n",
        .{ profile_name, home_arg, config_path },
    );
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

fn loadConfigOrPromptCreateFor(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    stderr: anytype,
    cfg: *hikko.Config,
) !bool {
    load: while (true) {
        cfg.* = hikko.loadConfig(allocator, config_path) catch |err| {
            if (err == error.FileNotFound) {
                const created = try maybeCreateExampleConfigAtPath(config_path, stderr);
                if (!created) {
                    return false;
                }
                continue :load;
            }
            return err;
        };

        return true;
    }
}

fn maybeCreateExampleConfigAtPath(config_path: []const u8, stderr: anytype) !bool {
    try stderr.print(
        "hikkoshi: config file not found at '{s}'\n",
        .{config_path},
    );
    try stderr.writeAll(
        "hint: create one with `hikkoshi example > ~/.config/hikkoshi/config.toml`\n",
    );

    const stdin_file = std.fs.File.stdin();
    if (!stdin_file.isTty()) {
        return false;
    }

    try stderr.writeAll("create an example config at this path now? [y/N] ");
    try stderr.flush();

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = stdin_file.reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    var answer_buf: [1]u8 = undefined;
    const count = stdin.readSliceShort(&answer_buf) catch |err| {
        if (err == error.EndOfStream) {
            return false;
        }
        return err;
    };
    if (count == 0) {
        return false;
    }

    const ch = answer_buf[0];
    if (ch != 'y' and ch != 'Y') {
        try stderr.writeAll("hikkoshi: not creating config file\n");
        return false;
    }

    const dir_path = std.fs.path.dirname(config_path) orelse ".";
    std.fs.cwd().makePath(dir_path) catch |err| {
        try stderr.print(
            "hikkoshi: failed to create config directory '{s}': {s}\n",
            .{ dir_path, @errorName(err) },
        );
        return false;
    };

    var file = std.fs.cwd().createFile(config_path, .{}) catch |err| {
        try stderr.print(
            "hikkoshi: failed to create config file '{s}': {s}\n",
            .{ config_path, @errorName(err) },
        );
        return false;
    };
    defer file.close();

    var file_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {};

    try hikko.printExampleConfig(out);

    try stderr.print(
        "hikkoshi: wrote example config to '{s}'\n",
        .{config_path},
    );

    return true;
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

    if (std.mem.eql(u8, child_argv[0], "--sh") and child_argv.len < 2) {
        try stderr.writeAll("hikkoshi: --sh requires a command string\n");
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

    var cfg: hikko.Config = undefined;
    const have_cfg = try loadConfigOrPromptCreateFor(allocator, config_path, stderr, &cfg);
    if (!have_cfg) return;
    defer cfg.deinit();

    const profile = hikko.findProfile(&cfg, profile_name) orelse {
        try stderr.print("hikkoshi: profile '{s}' not found\n", .{profile_name});
        return;
    };

    var env_map = try hikko.buildEnvMapForProfile(allocator, profile);

    const use_shell = std.mem.eql(u8, child_argv[0], "--sh");
    var shell_argv_storage: [3][]const u8 = undefined;
    const argv_for_child = blk: {
        if (!use_shell) break :blk child_argv;

        const shell_path = env_map.get("SHELL") orelse "/bin/sh";
        shell_argv_storage[0] = shell_path;
        shell_argv_storage[1] = "-lc";
        shell_argv_storage[2] = child_argv[1];
        break :blk shell_argv_storage[0..3];
    };

    var child = std.process.Child.init(argv_for_child, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.env_map = &env_map;

    const term = child.spawnAndWait() catch |err| {
        const cmd = argv_for_child[0];
        switch (err) {
            error.FileNotFound => {
                try stderr.print(
                    "hikkoshi: failed to spawn '{s}': command not found\n",
                    .{cmd},
                );
            },
            error.AccessDenied => {
                try stderr.print(
                    "hikkoshi: failed to spawn '{s}': access denied\n",
                    .{cmd},
                );
            },
            else => {
                try stderr.print(
                    "hikkoshi: failed to spawn '{s}': {s}\n",
                    .{ cmd, @errorName(err) },
                );
            },
        }
        return;
    };
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
        \\  hks [--config <path>] <profile> <command> [args...]
        \\  hks [--config <path>] add <home> [name]
        \\  hks [--config <path>] list
        \\  hks [--config <path>] show <profile>
        \\  hks [--config <path>] config-path
        \\  hks example
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
