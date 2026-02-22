const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const paths = @import("paths.zig");
const tree_sitter_indexer = @import("tree_sitter_indexer.zig");

// ── Public API ──────────────────────────────────────────────────────────

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    pipe_read: posix.fd_t,
    pipe_write: posix.fd_t,
    thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    project_root: []const u8,
    read_buf: [4096]u8,
    read_len: usize,
    read_start: usize,
    // CFRunLoop cross-thread wakeup (macOS only).
    // Stored as usize for atomic access; 0 means not yet set.
    macos_run_loop: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    macos_stop_fn: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Initialize the watcher. Returns null if no index exists or platform unsupported.
    pub fn init(allocator: std.mem.Allocator) ?Watcher {
        if (builtin.os.tag != .macos and builtin.os.tag != .linux) return null;

        const cog_dir = paths.findCogDir(allocator) catch return null;
        defer allocator.free(cog_dir);

        // Check if index exists — no index means nothing to maintain
        const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return null;
        defer allocator.free(index_path);
        std.fs.accessAbsolute(index_path, .{}) catch return null;

        // Derive project root (parent of .cog)
        const project_root = std.fs.path.dirname(cog_dir) orelse return null;
        const owned_root = allocator.dupe(u8, project_root) catch return null;

        // Create pipe for inter-thread communication
        const pipe_fds = posix.pipe() catch {
            allocator.free(owned_root);
            return null;
        };

        // Set write end to non-blocking
        setNonBlock(pipe_fds[1]);

        return .{
            .allocator = allocator,
            .pipe_read = pipe_fds[0],
            .pipe_write = pipe_fds[1],
            .thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .project_root = owned_root,
            .read_buf = undefined,
            .read_len = 0,
            .read_start = 0,
            .macos_run_loop = std.atomic.Value(usize).init(0),
            .macos_stop_fn = std.atomic.Value(usize).init(0),
        };
    }

    /// Spawn the watcher thread.
    pub fn start(self: *Watcher) void {
        if (builtin.os.tag == .macos) {
            self.thread = std.Thread.spawn(.{}, watcherThreadMacos, .{self}) catch return;
        } else if (builtin.os.tag == .linux) {
            self.thread = std.Thread.spawn(.{}, watcherThreadLinux, .{self}) catch return;
        }
    }

    /// Stop the watcher thread and release resources.
    pub fn deinit(self: *Watcher) void {
        self.stop_flag.store(true, .release);

        // Wake up the macOS CFRunLoop so the thread exits immediately
        // instead of waiting for the next timeout.
        const rl_ptr = self.macos_run_loop.load(.acquire);
        const stop_fn_ptr = self.macos_stop_fn.load(.acquire);
        if (rl_ptr != 0 and stop_fn_ptr != 0) {
            const stop_fn: *const fn (*anyopaque) callconv(.c) void = @ptrFromInt(stop_fn_ptr);
            stop_fn(@ptrFromInt(rl_ptr));
        }

        // Write a byte to unblock any pending read on the pipe
        _ = posix.write(self.pipe_write, "!") catch {};

        if (self.thread) |t| t.join();

        posix.close(self.pipe_read);
        posix.close(self.pipe_write);
        self.allocator.free(self.project_root);
    }

    /// File descriptor for the read end of the pipe, for use with poll().
    pub fn getFd(self: *const Watcher) posix.fd_t {
        return self.pipe_read;
    }

    /// Drain one newline-delimited path from the pipe buffer.
    /// Returns a relative path slice valid until the next drainOne() call, or null.
    pub fn drainOne(self: *Watcher) ?[]const u8 {
        while (true) {
            // Scan for newline in existing buffer
            if (self.read_len > 0) {
                const data = self.read_buf[self.read_start .. self.read_start + self.read_len];
                if (std.mem.indexOfScalar(u8, data, '\n')) |nl| {
                    const line = data[0..nl];
                    self.read_start += nl + 1;
                    self.read_len -= nl + 1;
                    if (line.len > 0) return line;
                    continue; // skip empty lines
                }
            }

            // Compact buffer if needed
            if (self.read_start > 0 and self.read_len > 0) {
                std.mem.copyForwards(u8, &self.read_buf, self.read_buf[self.read_start .. self.read_start + self.read_len]);
            }
            self.read_start = 0;

            // Try to read more
            if (self.read_len >= self.read_buf.len) {
                // Buffer full with no newline — discard
                self.read_len = 0;
                return null;
            }

            const n = posix.read(self.pipe_read, self.read_buf[self.read_len..]) catch return null;
            if (n == 0) return null;
            self.read_len += n;
        }
    }
};

// ── Shared Filtering ────────────────────────────────────────────────────

fn shouldWatchPath(rel_path: []const u8) bool {
    // Check path components for excluded dirs and hidden files
    var it = std.mem.splitScalar(u8, rel_path, '/');
    var last_component: []const u8 = "";
    while (it.next()) |component| {
        if (component.len == 0) continue;
        // Skip hidden directories/files
        if (component[0] == '.') return false;
        // Skip common non-source directories
        if (isExcludedDir(component)) return false;
        last_component = component;
    }
    if (last_component.len == 0) return false;

    // Check file extension — only watch files tree-sitter can index
    const ext = std.fs.path.extension(last_component);
    if (ext.len == 0) return false;
    return tree_sitter_indexer.detectLanguage(ext) != null;
}

fn isExcludedDir(name: []const u8) bool {
    const excluded = [_][]const u8{
        "node_modules",
        "vendor",
        "target",
        "zig-out",
        "zig-cache",
        ".zig-cache",
        "build",
        "dist",
        "__pycache__",
    };
    for (excluded) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    return false;
}

fn makeRelative(abs_path: []const u8, root: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, abs_path, root)) return null;
    var rest = abs_path[root.len..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    if (rest.len == 0) return null;
    return rest;
}

fn setNonBlock(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    const nonblock: usize = @bitCast(@as(isize, @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })))));
    _ = posix.fcntl(fd, posix.F.SETFL, flags | nonblock) catch {};
}

// ── macOS Backend (FSEvents) ────────────────────────────────────────────
// Frameworks are loaded dynamically at runtime via std.DynLib so that
// cross-compilation works without macOS SDK stubs.

const CF = struct {
    // Opaque CF/FSEvents types
    const CFIndex = isize;
    const CFStringEncoding = u32;
    const CFAllocatorRef = ?*anyopaque;
    const CFStringRef = *anyopaque;
    const CFArrayRef = *anyopaque;
    const CFRunLoopRef = *anyopaque;
    const CFRunLoopMode = *anyopaque;

    const FSEventStreamRef = *anyopaque;
    const FSEventStreamEventId = u64;
    const FSEventStreamCreateFlags = u32;
    const ConstFSEventStreamRef = *const anyopaque;

    const FSEventStreamContext = extern struct {
        version: CFIndex = 0,
        info: ?*anyopaque = null,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copyDescription: ?*const anyopaque = null,
    };

    const FSEventStreamCallback = *const fn (
        stream: ConstFSEventStreamRef,
        info: ?*anyopaque,
        num_events: usize,
        event_paths: [*]const [*:0]const u8,
        event_flags: [*]const u32,
        event_ids: [*]const FSEventStreamEventId,
    ) callconv(.c) void;

    // Constants
    const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;
    const kFSEventStreamCreateFlagFileEvents: FSEventStreamCreateFlags = 0x00000010;
    const kFSEventStreamCreateFlagNoDefer: FSEventStreamCreateFlags = 0x00000002;
    const kFSEventStreamEventIdSinceNow: FSEventStreamEventId = 0xFFFFFFFFFFFFFFFF;

    // Event flags
    const kFSEventStreamEventFlagItemIsFile: u32 = 0x00010000;
    const kFSEventStreamEventFlagItemCreated: u32 = 0x00000100;
    const kFSEventStreamEventFlagItemModified: u32 = 0x00001000;
    const kFSEventStreamEventFlagItemRemoved: u32 = 0x00000200;
    const kFSEventStreamEventFlagItemRenamed: u32 = 0x00000800;

    // Function pointer types for dynamic loading
    const CFStringCreateWithCStringFn = *const fn (CFAllocatorRef, [*:0]const u8, CFStringEncoding) callconv(.c) ?CFStringRef;
    const CFArrayCreateFn = *const fn (CFAllocatorRef, [*]const ?*const anyopaque, CFIndex, ?*const anyopaque) callconv(.c) ?CFArrayRef;
    const CFReleaseFn = *const fn (*anyopaque) callconv(.c) void;
    const CFRunLoopGetCurrentFn = *const fn () callconv(.c) CFRunLoopRef;
    const CFRunLoopRunInModeFn = *const fn (CFRunLoopMode, f64, u8) callconv(.c) i32;
    const CFRunLoopStopFn = *const fn (*anyopaque) callconv(.c) void;

    const FSEventStreamCreateFn = *const fn (CFAllocatorRef, FSEventStreamCallback, *const FSEventStreamContext, CFArrayRef, FSEventStreamEventId, f64, FSEventStreamCreateFlags) callconv(.c) ?FSEventStreamRef;
    const FSEventStreamScheduleWithRunLoopFn = *const fn (FSEventStreamRef, CFRunLoopRef, CFRunLoopMode) callconv(.c) void;
    const FSEventStreamStartFn = *const fn (FSEventStreamRef) callconv(.c) bool;
    const FSEventStreamStopFn = *const fn (FSEventStreamRef) callconv(.c) void;
    const FSEventStreamInvalidateFn = *const fn (FSEventStreamRef) callconv(.c) void;
    const FSEventStreamReleaseFn = *const fn (FSEventStreamRef) callconv(.c) void;

    // Resolved function pointers
    CFStringCreateWithCString: CFStringCreateWithCStringFn = undefined,
    CFArrayCreate: CFArrayCreateFn = undefined,
    CFRelease: CFReleaseFn = undefined,
    CFRunLoopGetCurrent: CFRunLoopGetCurrentFn = undefined,
    CFRunLoopRunInMode: CFRunLoopRunInModeFn = undefined,
    CFRunLoopStop: CFRunLoopStopFn = undefined,

    FSEventStreamCreate: FSEventStreamCreateFn = undefined,
    FSEventStreamScheduleWithRunLoop: FSEventStreamScheduleWithRunLoopFn = undefined,
    FSEventStreamStart: FSEventStreamStartFn = undefined,
    FSEventStreamStop: FSEventStreamStopFn = undefined,
    FSEventStreamInvalidate: FSEventStreamInvalidateFn = undefined,
    FSEventStreamRelease: FSEventStreamReleaseFn = undefined,

    kCFRunLoopDefaultMode: CFRunLoopMode = undefined,

    cf_lib: std.DynLib = undefined,
    cs_lib: std.DynLib = undefined,

    fn load() ?CF {
        var self: CF = .{};

        self.cf_lib = std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") catch return null;
        self.cs_lib = std.DynLib.open("/System/Library/Frameworks/CoreServices.framework/CoreServices") catch {
            self.cf_lib.close();
            return null;
        };

        // CoreFoundation functions
        self.CFStringCreateWithCString = self.cf_lib.lookup(CFStringCreateWithCStringFn, "CFStringCreateWithCString") orelse {
            self.close();
            return null;
        };
        self.CFArrayCreate = self.cf_lib.lookup(CFArrayCreateFn, "CFArrayCreate") orelse {
            self.close();
            return null;
        };
        self.CFRelease = self.cf_lib.lookup(CFReleaseFn, "CFRelease") orelse {
            self.close();
            return null;
        };
        self.CFRunLoopGetCurrent = self.cf_lib.lookup(CFRunLoopGetCurrentFn, "CFRunLoopGetCurrent") orelse {
            self.close();
            return null;
        };
        self.CFRunLoopRunInMode = self.cf_lib.lookup(CFRunLoopRunInModeFn, "CFRunLoopRunInMode") orelse {
            self.close();
            return null;
        };
        self.CFRunLoopStop = self.cf_lib.lookup(CFRunLoopStopFn, "CFRunLoopStop") orelse {
            self.close();
            return null;
        };

        // CoreServices functions
        self.FSEventStreamCreate = self.cs_lib.lookup(FSEventStreamCreateFn, "FSEventStreamCreate") orelse {
            self.close();
            return null;
        };
        self.FSEventStreamScheduleWithRunLoop = self.cs_lib.lookup(FSEventStreamScheduleWithRunLoopFn, "FSEventStreamScheduleWithRunLoop") orelse {
            self.close();
            return null;
        };
        self.FSEventStreamStart = self.cs_lib.lookup(FSEventStreamStartFn, "FSEventStreamStart") orelse {
            self.close();
            return null;
        };
        self.FSEventStreamStop = self.cs_lib.lookup(FSEventStreamStopFn, "FSEventStreamStop") orelse {
            self.close();
            return null;
        };
        self.FSEventStreamInvalidate = self.cs_lib.lookup(FSEventStreamInvalidateFn, "FSEventStreamInvalidate") orelse {
            self.close();
            return null;
        };
        self.FSEventStreamRelease = self.cs_lib.lookup(FSEventStreamReleaseFn, "FSEventStreamRelease") orelse {
            self.close();
            return null;
        };

        // Global variable: kCFRunLoopDefaultMode is a pointer to a CFStringRef
        const mode_ptr = self.cf_lib.lookup(*const CFRunLoopMode, "kCFRunLoopDefaultMode") orelse {
            self.close();
            return null;
        };
        self.kCFRunLoopDefaultMode = mode_ptr.*;

        return self;
    }

    fn close(self: *CF) void {
        self.cs_lib.close();
        self.cf_lib.close();
    }
};

fn watcherThreadMacos(self: *Watcher) void {
    if (builtin.os.tag != .macos) return;

    // Load frameworks dynamically
    var cf = CF.load() orelse return;
    defer cf.close();

    // Check if shutdown was requested while we were loading frameworks.
    if (self.stop_flag.load(.acquire)) return;

    // Create CFString from project root
    const root_z = self.allocator.dupeZ(u8, self.project_root) catch return;
    defer self.allocator.free(root_z);

    const cf_path = cf.CFStringCreateWithCString(null, root_z.ptr, CF.kCFStringEncodingUTF8) orelse return;
    defer cf.CFRelease(cf_path);

    // Create CFArray with single path
    var path_values = [_]?*const anyopaque{cf_path};
    const cf_paths = cf.CFArrayCreate(null, &path_values, 1, null) orelse return;
    defer cf.CFRelease(cf_paths);

    // Create stream context pointing to self
    var context = CF.FSEventStreamContext{
        .info = @ptrCast(self),
    };

    const stream = cf.FSEventStreamCreate(
        null,
        &fseventsCallback,
        &context,
        cf_paths,
        CF.kFSEventStreamEventIdSinceNow,
        0.5, // 500ms latency for batching
        CF.kFSEventStreamCreateFlagFileEvents | CF.kFSEventStreamCreateFlagNoDefer,
    ) orelse return;

    const run_loop = cf.CFRunLoopGetCurrent();

    // Publish the run loop ref and stop function so deinit() can wake us up
    // via CFRunLoopStop() from the main thread.
    self.macos_run_loop.store(@intFromPtr(run_loop), .release);
    self.macos_stop_fn.store(@intFromPtr(cf.CFRunLoopStop), .release);

    cf.FSEventStreamScheduleWithRunLoop(stream, run_loop, cf.kCFRunLoopDefaultMode);
    if (!cf.FSEventStreamStart(stream)) {
        cf.FSEventStreamInvalidate(stream);
        cf.FSEventStreamRelease(stream);
        return;
    }

    // Run the event loop with periodic stop_flag checks.
    // CFRunLoopRunInMode returns after the timeout (0.5s) or when a source
    // fires, letting us check stop_flag without needing CFRunLoopStop().
    while (!self.stop_flag.load(.acquire)) {
        _ = cf.CFRunLoopRunInMode(cf.kCFRunLoopDefaultMode, 0.5, 0);
    }

    // Cleanup
    cf.FSEventStreamStop(stream);
    cf.FSEventStreamInvalidate(stream);
    cf.FSEventStreamRelease(stream);
}

fn fseventsCallback(
    _: CF.ConstFSEventStreamRef,
    info: ?*anyopaque,
    num_events: usize,
    event_paths: [*]const [*:0]const u8,
    event_flags: [*]const u32,
    _: [*]const CF.FSEventStreamEventId,
) callconv(.c) void {
    const self: *Watcher = @ptrCast(@alignCast(info orelse return));
    if (self.stop_flag.load(.acquire)) return;

    for (0..num_events) |i| {
        const flags = event_flags[i];

        // Only care about file events (not directory events)
        if (flags & CF.kFSEventStreamEventFlagItemIsFile == 0) continue;

        // Only care about create/modify/remove/rename
        const interesting = CF.kFSEventStreamEventFlagItemCreated |
            CF.kFSEventStreamEventFlagItemModified |
            CF.kFSEventStreamEventFlagItemRemoved |
            CF.kFSEventStreamEventFlagItemRenamed;
        if (flags & interesting == 0) continue;

        const abs_path = std.mem.span(event_paths[i]);
        const rel_path = makeRelative(abs_path, self.project_root) orelse continue;

        if (!shouldWatchPath(rel_path)) continue;

        // Write "rel_path\n" to pipe (non-blocking, drop on EAGAIN)
        _ = posix.write(self.pipe_write, rel_path) catch continue;
        _ = posix.write(self.pipe_write, "\n") catch continue;
    }
}

// ── Linux Backend (inotify) ─────────────────────────────────────────────

fn watcherThreadLinux(self: *Watcher) void {
    if (builtin.os.tag != .linux) return;

    const linux = std.os.linux;

    // Create inotify instance
    const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    const inotify_fd: posix.fd_t = @intCast(@as(isize, @bitCast(rc)));
    if (inotify_fd < 0) return;
    defer posix.close(inotify_fd);

    // Watch descriptor → directory path mapping
    var wd_map = std.AutoHashMap(i32, []const u8).init(self.allocator);
    defer {
        var it = wd_map.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        wd_map.deinit();
    }

    const watch_mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
        linux.IN.MOVED_TO | linux.IN.MOVED_FROM;

    // Recursively add watches starting from project root
    addWatchRecursive(self, inotify_fd, watch_mask, self.project_root, &wd_map);

    // Event buffer
    var event_buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

    while (!self.stop_flag.load(.acquire)) {
        // Poll on inotify fd with timeout
        var fds = [_]posix.pollfd{.{
            .fd = inotify_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const poll_rc = posix.poll(&fds, 500) catch continue;
        if (poll_rc == 0) continue;
        if (fds[0].revents & posix.POLL.IN == 0) continue;

        const bytes_read = posix.read(inotify_fd, &event_buf) catch continue;
        if (bytes_read == 0) continue;

        var offset: usize = 0;
        while (offset < bytes_read) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&event_buf[offset]));
            offset += @sizeOf(linux.inotify_event) + event.len;

            const name = event.getName() orelse continue;
            const dir_path = wd_map.get(event.wd) orelse continue;

            // Build full relative path
            const rel_dir = makeRelative(dir_path, self.project_root) orelse "";
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const rel_path = if (rel_dir.len > 0)
                std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ rel_dir, name }) catch continue
            else
                std.fmt.bufPrint(&path_buf, "{s}", .{name}) catch continue;

            // If a new directory is created, add a watch for it
            if (event.mask & linux.IN.CREATE != 0 and event.mask & linux.IN.ISDIR != 0) {
                if (!isExcludedDir(name) and name[0] != '.') {
                    const abs_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name }) catch continue;
                    addWatchRecursive(self, inotify_fd, watch_mask, abs_path, &wd_map);
                    self.allocator.free(abs_path);
                }
                continue;
            }

            // Only process file events
            if (event.mask & linux.IN.ISDIR != 0) continue;

            if (!shouldWatchPath(rel_path)) continue;

            // Write "rel_path\n" to pipe
            _ = posix.write(self.pipe_write, rel_path) catch continue;
            _ = posix.write(self.pipe_write, "\n") catch continue;
        }
    }
}

fn addWatchRecursive(
    self: *Watcher,
    inotify_fd: posix.fd_t,
    mask: u32,
    dir_path: []const u8,
    wd_map: *std.AutoHashMap(i32, []const u8),
) void {
    if (builtin.os.tag != .linux) return;

    const linux = std.os.linux;

    const path_z = self.allocator.dupeZ(u8, dir_path) catch return;
    defer self.allocator.free(path_z);

    const rc = linux.inotify_add_watch(inotify_fd, path_z.ptr, mask);
    const wd: i32 = @intCast(@as(isize, @bitCast(rc)));
    if (wd < 0) return;

    const owned_path = self.allocator.dupe(u8, dir_path) catch return;
    wd_map.put(wd, owned_path) catch {
        self.allocator.free(owned_path);
        return;
    };

    // Recurse into subdirectories
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;
        if (isExcludedDir(entry.name)) continue;

        const child = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        defer self.allocator.free(child);
        addWatchRecursive(self, inotify_fd, mask, child, wd_map);
    }
}
