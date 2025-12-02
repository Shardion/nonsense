pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}).init;
    const alloc = dba.allocator();
    var arg_iterator = try std.process.argsWithAllocator(alloc);
    defer arg_iterator.deinit();

    var maybe_mode: ?[*:0]const u8 = null;
    var maybe_name: ?[*:0]const u8 = null;
    var remaining_args: std.ArrayList([]const u8) = try std.ArrayList([]const u8).initCapacity(alloc, 12);
    defer remaining_args.deinit(alloc);

    // Skip argv[0], the process name
    _ = arg_iterator.skip();

    while (arg_iterator.next()) |arg| {
        if (maybe_mode == null) {
            maybe_mode = arg;
        } else if (maybe_name == null) {
            maybe_name = arg;
        } else {
            try remaining_args.append(alloc, arg);
        }
    }

    const container = std.process.getEnvVarOwned(alloc, "container");
    var contained: bool = false;
    if (container) |containerType| {
        defer alloc.free(containerType);
        contained = std.mem.eql(u8, containerType, "flatpak");
    } else |_| {}

    if (maybe_mode) |mode| {
        if (maybe_name) |name| {
            if (std.mem.indexOf(u8, std.mem.span(name), "/")) |_| {
                std.debug.print("Name cannot contain `/`.\n", .{});
                return;
            }

            if (std.mem.eql(u8, "wrap", std.mem.span(mode))) {
                if (remaining_args.items.len <= 0) {
                    std.debug.print("Must have a program to wrap when run in wrap mode.\n", .{});
                    return;
                }

                try mode_wrap(alloc, name, contained, remaining_args);
            } else if (std.mem.eql(u8, "kill", std.mem.span(mode))) {
                try mode_kill(alloc, name, contained);
            } else if (std.mem.eql(u8, "spawn", std.mem.span(mode))) {
                _ = try mode_spawn(alloc, name, contained, true);
            } else if (std.mem.eql(u8, "exec", std.mem.span(mode))) {
                try mode_exec(alloc, name);
            } else if (std.mem.eql(u8, "sleep", std.mem.span(mode))) {
                try mode_sleep();
            } else {
                std.debug.print("Invalid mode: {s}\n", .{mode});
                return;
            }
        } else {
            std.debug.print("A name is required.\n", .{});
            return;
        }
    } else {
        std.debug.print("A mode is required.\n", .{});
        return;
    }
}

fn mode_wrap(alloc: std.mem.Allocator, name: [*:0]const u8, contained: bool, remaining_args: std.ArrayList([]const u8)) !void {
    if (remaining_args.items.len <= 0) {
        @panic("Must have a program to wrap when run in wrap mode.");
    }
    std.debug.print("Wrap mode.\n", .{});
    var wrap_child = std.process.Child.init(remaining_args.items, alloc);
    try wrap_child.spawn();
    try wrap_child.waitForSpawn();
    const children = try mode_spawn(alloc, name, contained, false);
    _ = try wrap_child.wait();
    for (children.items) |child| {
        _ = try @constCast(&child).kill();
        _ = try @constCast(&child).wait();
    }
}

fn mode_kill(alloc: std.mem.Allocator, name: [*:0]const u8, contained: bool) !void {
    std.debug.print("Kill mode.\n", .{});
    var discord_pids = try find_discord_flatpak_pids(alloc, contained);
    defer discord_pids.deinit(alloc);
    var children = try std.ArrayList(std.process.Child).initCapacity(alloc, 2);
    defer children.deinit(alloc);
    for (discord_pids.items) |discord_pid| {
        try children.append(alloc, try kill_in_discord_flatpak(alloc, name, contained, discord_pid));
    }
    for (children.items) |child| {
        _ = try @constCast(&child).wait();
    }
}

fn kill_in_discord_flatpak(alloc: std.mem.Allocator, name: [*:0]const u8, contained: bool, pid: []const u8) !std.process.Child {
    const filename = try std.mem.concat(alloc, u8, &.{ "/tmp/", std.mem.span(name), ".nonsense-game" });
    const command = try containment_helper(alloc, contained, &.{
        "flatpak",
        "run",
        "--parent-share-pids",
        try std.mem.concat(alloc, u8, &.{ "--parent-pid=", pid }),
        // Uses `pkill`. This is fine, because all of the Discord Flatpaks have
        // it installed.
        "--command=pkill",
        "com.discordapp.Discord",
        "-f",
        filename,
    });
    var child = std.process.Child.init(command, alloc);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    try child.waitForSpawn();
    return child;
}

fn mode_spawn(alloc: std.mem.Allocator, name: [*:0]const u8, contained: bool, wait: bool) !std.ArrayList(std.process.Child) {
    std.debug.print("Spawn mode.\n", .{});
    var discord_pids = try find_discord_flatpak_pids(alloc, contained);
    defer discord_pids.deinit(alloc);
    var children = try std.ArrayList(std.process.Child).initCapacity(alloc, 2);
    for (discord_pids.items) |discord_pid| {
        try children.append(alloc, try spawn_in_discord_flatpak(alloc, name, contained, discord_pid));
    }
    if (wait) {
        for (children.items) |child| {
            _ = try @constCast(&child).wait();
        }
    }
    return children;
}

fn find_discord_flatpak_pids(alloc: std.mem.Allocator, contained: bool) !std.ArrayList([]const u8) {
    std.debug.print("Discovering Discord instances.\n", .{});
    const run_result: std.process.Child.RunResult = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = try containment_helper_array(alloc, contained, &.{
            "flatpak",
            "ps",
            "--columns=application,child-pid",
        }),
    });
    defer alloc.free(run_result.stderr);
    var stdout_lines = std.mem.splitAny(u8, run_result.stdout, "\n");
    var discord_pids = try std.ArrayList([]const u8).initCapacity(alloc, 2);
    while (stdout_lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "com.discordapp.Discord")) {
            const maybe_last_space_index = std.mem.lastIndexOfScalar(u8, line, '\t');
            if (maybe_last_space_index) |last_space_index| {
                try discord_pids.append(alloc, line[last_space_index..]);
            }
        }
    }
    return discord_pids;
}

fn spawn_in_discord_flatpak(alloc: std.mem.Allocator, name: [*:0]const u8, contained: bool, pid: []const u8) !std.process.Child {
    std.debug.print("Spawning inside Discord Flatpak.\n", .{});
    var child = std.process.Child.init(try containment_helper(alloc, contained, &.{
        "flatpak",
        "run",
        "--parent-share-pids",
        try std.mem.concat(alloc, u8, &.{ "--parent-pid=", pid }),
        try std.mem.concat(alloc, u8, &.{ "--command=", @ptrCast(try std.fs.selfExePathAlloc(alloc)) }),
        "com.discordapp.Discord",
        "exec",
        std.mem.span(name),
    }), alloc);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    try child.waitForSpawn();
    return child;
}

fn mode_exec(alloc: std.mem.Allocator, name: [*:0]const u8) !void {
    std.debug.print("Exec mode.\n", .{});
    // No need to free in this function...
    const self_name: [*:0]const u8 = try alloc.dupeZ(u8, try copy_to_temp(alloc, name));
    //defer alloc.free(self_name);

    const new_argv: []const []const u8 = &.{
        std.mem.span(self_name),
        "sleep",
        std.mem.span(name),
    };

    // Hastily copied from std.process.execve
    const argv_buf = try alloc.allocSentinel(?[*:0]const u8, new_argv.len, null);
    for (new_argv, 0..) |arg, i| argv_buf[i] = (try alloc.dupeZ(u8, arg)).ptr;

    _ = std.os.linux.execve(self_name, argv_buf.ptr, &.{});
}

fn copy_to_temp(alloc: std.mem.Allocator, name: [*:0]const u8) ![]u8 {
    if (std.mem.indexOf(u8, std.mem.span(name), "/")) |_| {
        @panic("Attempted to make a filename containing `/`");
    }

    // TODO: This is very awful and insecure, but I don't think there's a way to
    //       do it better, because Discord sucks really badly and parses names
    //       by `realpath`ing the process `/proc/self/exe`
    const filename = try std.mem.concat(alloc, u8, &.{ "/tmp/", std.mem.span(name), ".nonsense-game" });
    try std.fs.copyFileAbsolute(try std.fs.selfExePathAlloc(alloc), filename, .{});
    return filename;
}

fn mode_sleep() !void {
    std.debug.print("Sleep mode.\n", .{});
    while (true) {
        std.Thread.sleep(std.math.maxInt(u64));
    }
}

// TODO: This unavoidably leaks memory, but it doesn't really matter that much...
fn containment_helper(alloc: std.mem.Allocator, contained: bool, command: []const []const u8) ![]const []const u8 {
    if (contained) {
        return try std.mem.concat(alloc, []const u8, &.{ &.{ "flatpak-spawn", "--host" }, command });
    }
    return command;
}

fn containment_helper_array(alloc: std.mem.Allocator, contained: bool, command: []const [*:0]const u8) ![]const []const u8 {
    const cmd_buf = try alloc.alloc([]const u8, command.len);
    for (command, 0..) |entry, i| cmd_buf[i] = std.mem.span(entry);
    if (contained) {
        return try std.mem.concat(alloc, []const u8, &.{ &.{ "flatpak-spawn", "--host" }, cmd_buf });
    }
    return cmd_buf;
}

const std = @import("std");

