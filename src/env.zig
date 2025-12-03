const std = @import("std");
const config = @import("config.zig");

/// Build an environment map for spawning a child process under the given
/// profile. This starts from the current process environment and then:
/// - sets `HOME` to the profile's virtual home;
/// - sets `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`
///   based on profile overrides or defaults derived from HOME;
/// - applies additional variables from `profile.env`.
pub fn buildEnvMapForProfile(
    allocator: std.mem.Allocator,
    profile: *const config.Profile,
) !std.process.EnvMap {
    // Start from a copy of the parent environment.
    var env_map = try std.process.getEnvMap(allocator);

    const parent_home_opt = env_map.get("HOME");

    const home = try expandUserPath(allocator, profile.home, parent_home_opt);
    try env_map.put("HOME", home);

    const xdg_config_home = try resolveXdgPath(
        allocator,
        profile.config,
        home,
        &.{".config"},
        parent_home_opt,
    );
    try env_map.put("XDG_CONFIG_HOME", xdg_config_home);

    const xdg_data_home = try resolveXdgPath(
        allocator,
        profile.data,
        home,
        &.{ ".local", "share" },
        parent_home_opt,
    );
    try env_map.put("XDG_DATA_HOME", xdg_data_home);

    const xdg_cache_home = try resolveXdgPath(
        allocator,
        profile.cache,
        home,
        &.{".cache"},
        parent_home_opt,
    );
    try env_map.put("XDG_CACHE_HOME", xdg_cache_home);

    const xdg_state_home = try resolveXdgPath(
        allocator,
        profile.state,
        home,
        &.{ ".local", "state" },
        parent_home_opt,
    );
    try env_map.put("XDG_STATE_HOME", xdg_state_home);

    // Apply additional environment variables from the profile.
    var it = profile.env.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Values in profile.env are already owned by the config allocator.
        // We duplicate them so that the environment map owns its own copies.
        const key_copy = try allocator.dupe(u8, key);
        const value_copy = try allocator.dupe(u8, value);
        try env_map.put(key_copy, value_copy);
    }

    return env_map;
}

/// Expand `~` using the parent HOME.
///
/// Rules:
/// - if `path` does not start with `~`, it is duplicated as-is;
/// - if `path` is `~` or `~/...`, `parent_home` must be provided and will be
///   used as the base directory;
/// - other forms like `~user` are not interpreted specially and are duplicated.
fn expandUserPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    parent_home_opt: ?[]const u8,
) ![]const u8 {
    if (path.len == 0 or path[0] != '~') {
        return try allocator.dupe(u8, path);
    }

    const parent_home = parent_home_opt orelse
        return error.HomeNotSetForTilde;

    if (path.len == 1) {
        // Just "~"
        return try allocator.dupe(u8, parent_home);
    }

    if (path[1] == '/') {
        // "~/something" -> <parent_home>/something
        const suffix = path[1..];
        return try std.fs.path.join(allocator, &.{ parent_home, suffix });
    }

    // "~user" style - treat literally for now.
    return try allocator.dupe(u8, path);
}

/// Decide the XDG directory path for a given category.
///
/// - If `override_raw` is provided, it is expanded using the parent HOME;
/// - Otherwise, we derive the path from the profile HOME and `default_suffix`.
fn resolveXdgPath(
    allocator: std.mem.Allocator,
    override_raw: ?[]const u8,
    profile_home: []const u8,
    default_suffix: []const []const u8,
    parent_home_opt: ?[]const u8,
) ![]const u8 {
    if (override_raw) |raw| {
        return try expandUserPath(allocator, raw, parent_home_opt);
    }

    // Derive from the profile's HOME.
    return switch (default_suffix.len) {
        0 => allocator.dupe(u8, profile_home),
        1 => std.fs.path.join(allocator, &.{ profile_home, default_suffix[0] }),
        2 => blk: {
            const first = try std.fs.path.join(allocator, &.{ profile_home, default_suffix[0] });
            defer allocator.free(first);
            break :blk try std.fs.path.join(allocator, &.{ first, default_suffix[1] });
        },
        else => error.UnsupportedDefaultSuffix,
    };
}
