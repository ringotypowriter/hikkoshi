const std = @import("std");
const toml = @import("toml");

pub const EnvMap = std.StringHashMap([]const u8);

pub const Profile = struct {
    /// Profile name (key under `profiles.` in the TOML).
    name: []const u8,

    /// Required: virtual HOME directory (can contain `~`, expansion happens later).
    home: []const u8,

    /// Optional overrides for XDG directories (can contain `~`).
    config: ?[]const u8,
    data: ?[]const u8,
    cache: ?[]const u8,
    state: ?[]const u8,

    /// Additional environment variables for this profile.
    /// `HOME` and all `XDG_*` keys are ignored while constructing this map.
    env: EnvMap,
};

pub const ProfileMap = std.StringHashMap(Profile);

pub const Config = struct {
    allocator: std.mem.Allocator,
    profiles: ProfileMap,

    pub fn deinit(self: *Config) void {
        // Free all allocated strings and maps.
        var it = self.profiles.iterator();
        while (it.next()) |entry| {
            var profile = entry.value_ptr.*;
            const allocator = self.allocator;

            allocator.free(profile.name);
            allocator.free(profile.home);

            if (profile.config) |v| allocator.free(v);
            if (profile.data) |v| allocator.free(v);
            if (profile.cache) |v| allocator.free(v);
            if (profile.state) |v| allocator.free(v);

            var env_it = profile.env.iterator();
            while (env_it.next()) |env_entry| {
                allocator.free(env_entry.key_ptr.*);
                allocator.free(env_entry.value_ptr.*);
            }
            profile.env.deinit();
        }
        self.profiles.deinit();
    }
};

/// Decide which configuration file path to use.
///
/// Priority:
/// - `override_path` argument (from `--config`);
/// - `HIKKOSHI_CONFIG` env var;
/// - default: `$HOME/.config/hikkoshi/config.toml`.
///
/// Returned path is freshly allocated with `allocator` and must be freed by the caller.
pub fn resolveConfigPath(
    allocator: std.mem.Allocator,
    override_path: ?[]const u8,
) ![]const u8 {
    if (override_path) |p| {
        return try allocator.dupe(u8, p);
    }

    // Environment variable takes precedence over default.
    if (std.process.getEnvVarOwned(allocator, "HIKKOSHI_CONFIG")) |env_path| {
        return env_path;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    // Fallback to $HOME/.config/hikkoshi/config.toml
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.HomeNotSet,
        else => return err,
    };
    defer allocator.free(home);

    const path = try std.fs.path.join(
        allocator,
        &.{ home, ".config", "hikkoshi", "config.toml" },
    );
    return path;
}

/// Load configuration from TOML file at `path`.
///
/// The function uses zig-toml to map the schema into an intermediate structure
/// and then copies data into a runtime-owned `Config`. The returned `Config`
/// must be later `deinit`-ed by the caller.
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    var cfg = Config{
        .allocator = allocator,
        .profiles = ProfileMap.init(allocator),
    };
    errdefer cfg.deinit();
    const ParserType = toml.Parser(toml.Table);

    // Read the entire file into memory first, then let zig-toml parse from a string.
    const content = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(content);

    var parser = ParserType.init(allocator);
    var parsed = try parser.parseString(content);
    defer parsed.deinit();

    const root_table = parsed.value;

    const profiles_value = root_table.get("profiles") orelse return cfg;

    const profiles_table_ptr = switch (profiles_value) {
        .table => |t| t,
        else => return error.InvalidConfig,
    };

    var profiles_it = profiles_table_ptr.iterator();
    while (profiles_it.next()) |entry| {
        const profile_name_raw = entry.key_ptr.*;
        const profile_value = entry.value_ptr.*;

        const profile_table_ptr = switch (profile_value) {
            .table => |t| t,
            else => return error.InvalidConfig,
        };

        const home_value = profile_table_ptr.get("home") orelse return error.InvalidConfig;
        const home_raw = switch (home_value) {
            .string => |s| s,
            else => return error.InvalidConfig,
        };

        const name = try allocator.dupe(u8, profile_name_raw);
        const home = try allocator.dupe(u8, home_raw);

        const config_path = blk: {
            if (profile_table_ptr.get("config")) |val| {
                break :blk switch (val) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => return error.InvalidConfig,
                };
            } else break :blk null;
        };

        const data_path = blk: {
            if (profile_table_ptr.get("data")) |val| {
                break :blk switch (val) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => return error.InvalidConfig,
                };
            } else break :blk null;
        };

        const cache_path = blk: {
            if (profile_table_ptr.get("cache")) |val| {
                break :blk switch (val) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => return error.InvalidConfig,
                };
            } else break :blk null;
        };

        const state_path = blk: {
            if (profile_table_ptr.get("state")) |val| {
                break :blk switch (val) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => return error.InvalidConfig,
                };
            } else break :blk null;
        };

        var env_map = EnvMap.init(allocator);

        if (profile_table_ptr.get("env")) |env_val| {
            const env_table_ptr = switch (env_val) {
                .table => |t| t,
                else => return error.InvalidConfig,
            };

            var env_it = env_table_ptr.iterator();
            while (env_it.next()) |env_entry| {
                const key = env_entry.key_ptr.*;
                const value = env_entry.value_ptr.*;

                // Ignore attempts to override HOME or XDG_* via env table.
                if (std.mem.eql(u8, key, "HOME")) continue;
                if (std.mem.startsWith(u8, key, "XDG_")) continue;

                const value_str = switch (value) {
                    .string => |s| s,
                    else => return error.InvalidConfig,
                };

                const key_copy = try allocator.dupe(u8, key);
                const value_copy = try allocator.dupe(u8, value_str);
                try env_map.put(key_copy, value_copy);
            }
        }

        const profile = Profile{
            .name = name,
            .home = home,
            .config = config_path,
            .data = data_path,
            .cache = cache_path,
            .state = state_path,
            .env = env_map,
        };

        try cfg.profiles.put(name, profile);
    }

    return cfg;
}

/// Find a profile by name. Returns `null` if the profile is not defined.
pub fn findProfile(cfg: *const Config, name: []const u8) ?*const Profile {
    return cfg.profiles.getPtr(name);
}

/// Iterate all profile names. The returned slice is allocated with `allocator`
/// and must be freed by the caller. Names themselves are not duplicated.
pub fn collectProfileNames(
    cfg: *const Config,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error![][]const u8 {
    const count = cfg.profiles.count();
    var names = try allocator.alloc([]const u8, count);

    var i: usize = 0;
    var it = cfg.profiles.iterator();
    while (it.next()) |entry| {
        names[i] = entry.key_ptr.*;
        i += 1;
    }

    return names;
}

/// Print an example configuration to the given writer.
pub fn printExampleConfig(writer: anytype) !void {
    try writer.writeAll(
        \\# Example hikkoshi configuration
        \\# Save as: ~/.config/hikkoshi/config.toml
        \\
        \\[profiles.example]
        \\home   = "~/profiles/example"
        \\# config = "~/profiles/example/.config"
        \\# data   = "~/profiles/example/.local/share"
        \\# cache  = "~/profiles/example/.cache"
        \\# state  = "~/profiles/example/.local/state"
        \\
        \\[profiles.example.env]
        \\APP_ENV = "example"
        \\EDITOR  = "nvim"
        \\
    );
}
