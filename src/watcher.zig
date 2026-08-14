const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const paths = @import("paths.zig");
const settings_mod = @import("settings.zig");
const path_matcher = @import("path_matcher.zig");
const debug_log = @import("debug_log.zig");

// ── Public API ──────────────────────────────────────────────────────────

pub const QUIET_WINDOW_NS: i128 = 200 * std.time.ns_per_ms;
pub const MAX_BATCH_EVENTS: usize = 64;
const MAX_WATCHER_LINE_BYTES: usize = std.fs.max_path_bytes;

pub const DrainEvent = union(enum) {
    path: []const u8,
    overflow,
};

pub const BatchState = struct {
    pending_count: usize = 0,
    last_event_ns: i128 = 0,

    pub fn noteEvent(self: *BatchState, now_ns: i128) void {
        self.pending_count += 1;
        self.last_event_ns = now_ns;
    }

    pub fn shouldFlush(self: BatchState, now_ns: i128) bool {
        if (self.pending_count == 0) return false;
        return self.pending_count >= MAX_BATCH_EVENTS or now_ns - self.last_event_ns >= QUIET_WINDOW_NS;
    }

    pub fn reset(self: *BatchState) void {
        self.* = .{};
    }
};

const LineDecoder = struct {
    buf: [MAX_WATCHER_LINE_BYTES + 4096]u8 = undefined,
    len: usize = 0,
    line_buf: [MAX_WATCHER_LINE_BYTES]u8 = undefined,
    discarding: bool = false,
    overflow_pending: bool = false,

    fn append(self: *LineDecoder, input: []const u8) void {
        for (input) |byte| {
            if (self.discarding) {
                if (byte == '\n') self.discarding = false;
                continue;
            }
            if (self.len == self.buf.len) {
                self.len = 0;
                self.discarding = byte != '\n';
                self.overflow_pending = true;
                continue;
            }
            self.buf[self.len] = byte;
            self.len += 1;
            if (self.len > MAX_WATCHER_LINE_BYTES and std.mem.indexOfScalar(u8, self.buf[0..self.len], '\n') == null) {
                self.len = 0;
                self.discarding = true;
                self.overflow_pending = true;
            }
        }
    }

    fn next(self: *LineDecoder) ?DrainEvent {
        if (self.overflow_pending) {
            self.overflow_pending = false;
            return .overflow;
        }
        while (true) {
            const nl = std.mem.indexOfScalar(u8, self.buf[0..self.len], '\n') orelse return null;
            const line = self.buf[0..nl];
            if (line.len <= self.line_buf.len) @memcpy(self.line_buf[0..line.len], line);
            const remaining = self.len - (nl + 1);
            if (remaining > 0) std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[nl + 1 .. self.len]);
            self.len = remaining;
            if (line.len == 0) continue;
            if (line[0] == 0 or line.len > self.line_buf.len) return .overflow;
            return .{ .path = self.line_buf[0..line.len] };
        }
    }

    fn feed(self: *LineDecoder, input: []const u8) ?DrainEvent {
        self.append(input);
        return self.next();
    }
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    pipe_read: posix.fd_t,
    pipe_write: posix.fd_t,
    thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    matcher: path_matcher.PathMatcher,
    read_buf: [4096]u8,
    decoder: LineDecoder,
    overflow_pending: std.atomic.Value(bool),
    // CFRunLoop cross-thread wakeup (macOS only).
    // Stored as usize for atomic access; 0 means not yet set.
    macos_run_loop: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    macos_stop_fn: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Initialize the watcher. Returns null if no index exists or platform unsupported.
    pub fn init(allocator: std.mem.Allocator) ?Watcher {
        if (builtin.os.tag != .macos and builtin.os.tag != .linux) return null;

        debug_log.log("Watcher.init: starting", .{});
        const cog_dir = paths.findCogDir(allocator) catch return null;
        defer allocator.free(cog_dir);

        // Check if index exists — no index means nothing to maintain
        const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return null;
        defer allocator.free(index_path);
        std.fs.accessAbsolute(index_path, .{}) catch return null;

        // Load index patterns from settings — no patterns means nothing to watch.
        // PathMatcher copies everything it needs, so the loaded settings are
        // released on every exit path below, including the early ones.
        const s = settings_mod.Settings.load(allocator) orelse return null;
        defer s.deinit(allocator);
        const code = s.code orelse return null;
        const patterns = code.index orelse return null;
        if (patterns.len == 0) return null;

        // Derive project root (parent of .cog)
        const project_root = std.fs.path.dirname(cog_dir) orelse return null;
        var matcher = path_matcher.PathMatcher.init(allocator, .{
            .project_root = project_root,
            .patterns = patterns,
            .external_roots = code.external_roots orelse &.{},
        }) catch |err| {
            debug_log.log("Watcher.init: path matcher setup failed error={s}", .{@errorName(err)});
            return null;
        };

        // Create pipe for inter-thread communication
        const pipe_fds = posix.pipe() catch {
            matcher.deinit();
            return null;
        };

        // Set both ends to non-blocking.
        // Write end: so the watcher thread never blocks on a full pipe.
        // Read end: so drainOne() returns null instead of blocking when
        // the pipe is empty (otherwise it holds the runtime mutex forever).
        setNonBlock(pipe_fds[0]);
        setNonBlock(pipe_fds[1]);

        debug_log.log("Watcher.init: root={s}, {d} patterns", .{ project_root, patterns.len });

        return .{
            .allocator = allocator,
            .pipe_read = pipe_fds[0],
            .pipe_write = pipe_fds[1],
            .thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .matcher = matcher,
            .read_buf = undefined,
            .decoder = .{},
            .overflow_pending = std.atomic.Value(bool).init(false),
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
        self.matcher.deinit();
    }

    /// File descriptor for the read end of the pipe, for use with poll().
    pub fn getFd(self: *const Watcher) posix.fd_t {
        return self.pipe_read;
    }

    /// Drain one newline-delimited watcher event.
    /// Path slices remain valid until the next drainOne() call.
    pub fn drainOne(self: *Watcher) ?DrainEvent {
        if (self.overflow_pending.swap(false, .acq_rel)) {
            debug_log.log("watcher: consuming pending overflow resync", .{});
            return .overflow;
        }
        if (self.decoder.next()) |event| return event;
        while (true) {
            const n = posix.read(self.pipe_read, &self.read_buf) catch return null;
            if (n == 0) return null;
            if (self.decoder.feed(self.read_buf[0..n])) |event| return event;
        }
    }
};

// ── Watch Bookkeeping ───────────────────────────────────────────────────

/// Watch-descriptor → canonical directory path registry.
///
/// The kernel reuses watch descriptors, and directories move and disappear
/// while watches are live, so every mutation has to release the path it
/// replaces. Keeping that ownership in one type means an allocation failure
/// can never strand a path the registry no longer references.
const WatchRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(i32, []const u8),

    fn init(allocator: std.mem.Allocator) WatchRegistry {
        return .{ .allocator = allocator, .entries = .empty };
    }

    fn deinit(self: *WatchRegistry) void {
        var it = self.entries.valueIterator();
        while (it.next()) |value| self.allocator.free(value.*);
        self.entries.deinit(self.allocator);
    }

    fn put(self: *WatchRegistry, wd: i32, dir_path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, dir_path);
        errdefer self.allocator.free(owned);
        const previous = try self.entries.fetchPut(self.allocator, wd, owned);
        if (previous) |entry| self.allocator.free(entry.value);
    }

    fn get(self: *const WatchRegistry, wd: i32) ?[]const u8 {
        return self.entries.get(wd);
    }

    fn remove(self: *WatchRegistry, wd: i32) void {
        if (self.entries.fetchRemove(wd)) |entry| self.allocator.free(entry.value);
    }

    fn count(self: *const WatchRegistry) usize {
        return self.entries.count();
    }

    /// Drop every watch at or below `prefix`, cancelling the kernel watch when
    /// an inotify descriptor is supplied. Allocation-free so it stays usable
    /// on the path where a directory has already vanished.
    fn removeSubtree(self: *WatchRegistry, prefix: []const u8, inotify_fd: ?posix.fd_t) usize {
        var removed: usize = 0;
        while (true) {
            var target: ?i32 = null;
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (!path_matcher.isContainedPath(entry.value_ptr.*, prefix)) continue;
                target = entry.key_ptr.*;
                break;
            }
            const wd = target orelse break;
            if (builtin.os.tag == .linux) {
                if (inotify_fd) |fd| _ = std.os.linux.inotify_rm_watch(fd, wd);
            }
            self.remove(wd);
            removed += 1;
        }
        return removed;
    }
};

/// What a subtree walk should do with what it finds. Collection and watch
/// registration share one traversal so their exclusion, depth, and symlink
/// cycle policy cannot drift apart.
const SubtreeVisitor = struct {
    logical_out: ?*std.ArrayListUnmanaged([]const u8) = null,
    registry: ?*WatchRegistry = null,
    inotify_fd: posix.fd_t = -1,
    watch_mask: u32 = 0,
};

fn walkWatchedSubtree(
    allocator: std.mem.Allocator,
    matcher: *path_matcher.PathMatcher,
    dir_path: []const u8,
    depth: usize,
    active: *std.AutoHashMap(path_matcher.DirectoryIdentity, void),
    visitor: SubtreeVisitor,
) !void {
    if (depth > matcher.recursionLimit()) {
        debug_log.log("Watcher.subtree: depth cap path={s} depth={d}", .{ dir_path, depth });
        return;
    }

    const canonical = std.fs.realpathAlloc(allocator, dir_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_log.log("Watcher.subtree: resolve {s} failed: {s}", .{ dir_path, @errorName(err) });
            return;
        },
    };
    defer allocator.free(canonical);

    if (!matcher.allowsPhysicalPath(canonical)) {
        debug_log.log("Watcher.subtree: rejected directory target={s}", .{canonical});
        return;
    }

    var dir = std.fs.openDirAbsolute(canonical, .{ .iterate = true }) catch |err| {
        debug_log.log("Watcher.subtree: open {s} failed: {s}", .{ canonical, @errorName(err) });
        return;
    };
    defer dir.close();

    const identity = path_matcher.directoryIdentity(dir) catch |err| {
        debug_log.log("Watcher.subtree: stat {s} failed: {s}", .{ canonical, @errorName(err) });
        return;
    };
    if (active.contains(identity)) {
        debug_log.log("Watcher.subtree: cycle path={s}", .{canonical});
        return;
    }
    try active.put(identity, {});
    defer _ = active.remove(identity);

    if (visitor.registry) |registry| try registerWatch(allocator, registry, visitor, canonical);

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (!path_matcher.isTraversableEntryName(entry.name)) continue;

        const child = try std.fs.path.join(allocator, &.{ canonical, entry.name });
        defer allocator.free(child);

        const stat = std.fs.cwd().statFile(child) catch continue;
        switch (stat.kind) {
            .directory => try walkWatchedSubtree(allocator, matcher, child, depth + 1, active, visitor),
            .file => if (visitor.logical_out) |out| try matcher.mapPhysicalToLogical(child, out),
            else => {},
        }
    }
}

fn registerWatch(
    allocator: std.mem.Allocator,
    registry: *WatchRegistry,
    visitor: SubtreeVisitor,
    canonical_dir: []const u8,
) !void {
    if (builtin.os.tag != .linux) return;

    const path_z = try allocator.dupeZ(u8, canonical_dir);
    defer allocator.free(path_z);

    const rc = std.os.linux.inotify_add_watch(visitor.inotify_fd, path_z.ptr, visitor.watch_mask);
    const wd: i32 = @intCast(@as(isize, @bitCast(rc)));
    if (wd < 0) {
        debug_log.log("Watcher.subtree: inotify_add_watch failed path={s} rc={d}", .{ canonical_dir, rc });
        return;
    }
    try registry.put(wd, canonical_dir);
}

// ── Shared Filtering ────────────────────────────────────────────────────

fn collectLogicalEvents(
    matcher: *path_matcher.PathMatcher,
    physical_path: []const u8,
    logical_paths: *std.ArrayListUnmanaged([]const u8),
) !void {
    try matcher.mapPhysicalToLogical(physical_path, logical_paths);
}

fn emitPhysicalPath(self: *Watcher, physical_path: []const u8) void {
    var logical_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (logical_paths.items) |path| self.allocator.free(path);
        logical_paths.deinit(self.allocator);
    }
    collectLogicalEvents(&self.matcher, physical_path, &logical_paths) catch return;
    for (logical_paths.items) |logical_path| {
        debug_log.log("Watcher.emit: physical={s} logical={s}", .{ physical_path, logical_path });
        _ = emitWatcherRecord(self, logical_path);
    }
}

fn setNonBlock(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    const nonblock: usize = @bitCast(@as(isize, @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })))));
    _ = posix.fcntl(fd, posix.F.SETFL, flags | nonblock) catch {};
}

fn emitWatcherRecord(self: *Watcher, record: []const u8) bool {
    if (record.len + 1 > 4096) {
        debug_log.log("watcher: record too large bytes={d}; signaling overflow", .{record.len});
        return emitOverflow(self);
    }
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..record.len], record);
    buf[record.len] = '\n';
    const written = posix.write(self.pipe_write, buf[0 .. record.len + 1]) catch |err| {
        debug_log.log("watcher: pipe write failed error={s}; signaling overflow", .{@errorName(err)});
        return emitOverflow(self);
    };
    if (written != record.len + 1) {
        debug_log.log("watcher: short pipe write bytes={d}/{d}; signaling overflow", .{ written, record.len + 1 });
        return emitOverflow(self);
    }
    return true;
}

fn emitOverflow(self: *Watcher) bool {
    const marker = "\x00\n";
    const written = posix.write(self.pipe_write, marker) catch |err| {
        self.overflow_pending.store(true, .release);
        debug_log.log("watcher: overflow marker write failed error={s}; atomic resync remains pending", .{@errorName(err)});
        return false;
    };
    if (written != marker.len) {
        self.overflow_pending.store(true, .release);
        debug_log.log("watcher: overflow marker short write bytes={d}/{d}; atomic resync remains pending", .{ written, marker.len });
        return false;
    }
    return true;
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
    const kFSEventStreamEventFlagMustScanSubDirs: u32 = 0x00000001;
    const kFSEventStreamEventFlagUserDropped: u32 = 0x00000002;
    const kFSEventStreamEventFlagKernelDropped: u32 = 0x00000004;
    const kFSEventStreamEventFlagRootChanged: u32 = 0x00000020;
    const kFSEventStreamEventFlagItemIsFile: u32 = 0x00010000;
    const kFSEventStreamEventFlagItemIsDir: u32 = 0x00020000;
    const kFSEventStreamEventFlagItemIsSymlink: u32 = 0x00040000;
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

    var watch_roots: std.ArrayListUnmanaged(path_matcher.WatchRoot) = .empty;
    defer {
        self.matcher.freeWatchRoots(watch_roots.items);
        watch_roots.deinit(self.allocator);
    }
    self.matcher.watchRoots(&watch_roots) catch return;
    if (watch_roots.items.len == 0) return;

    var cf_strings: std.ArrayListUnmanaged(CF.CFStringRef) = .empty;
    defer {
        for (cf_strings.items) |cf_string| cf.CFRelease(cf_string);
        cf_strings.deinit(self.allocator);
    }
    var path_values: std.ArrayListUnmanaged(?*const anyopaque) = .empty;
    defer path_values.deinit(self.allocator);
    for (watch_roots.items) |root| {
        const root_z = self.allocator.dupeZ(u8, root.physical_path) catch return;
        defer self.allocator.free(root_z);
        const cf_path = cf.CFStringCreateWithCString(null, root_z.ptr, CF.kCFStringEncodingUTF8) orelse return;
        cf_strings.append(self.allocator, cf_path) catch {
            cf.CFRelease(cf_path);
            return;
        };
        path_values.append(self.allocator, cf_path) catch return;
    }

    const cf_paths = cf.CFArrayCreate(null, path_values.items.ptr, @intCast(path_values.items.len), null) orelse return;
    defer cf.CFRelease(cf_paths);
    debug_log.log("Watcher.macos: watching {d} approved physical roots", .{watch_roots.items.len});

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
        CF.kFSEventStreamCreateFlagFileEvents,
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
        const overflow_flags = CF.kFSEventStreamEventFlagMustScanSubDirs |
            CF.kFSEventStreamEventFlagUserDropped |
            CF.kFSEventStreamEventFlagKernelDropped |
            CF.kFSEventStreamEventFlagRootChanged;
        if (flags & overflow_flags != 0) {
            debug_log.log("watcher.macos: overflow flags=0x{x}; requesting resync", .{flags});
            _ = emitOverflow(self);
            continue;
        }

        // Only care about create/modify/remove/rename
        const interesting = CF.kFSEventStreamEventFlagItemCreated |
            CF.kFSEventStreamEventFlagItemModified |
            CF.kFSEventStreamEventFlagItemRemoved |
            CF.kFSEventStreamEventFlagItemRenamed;
        if (flags & interesting == 0) continue;

        const abs_path = std.mem.span(event_paths[i]);
        if (self.matcher.ignoresPhysicalPath(abs_path)) continue;

        // A symlink appearing or disappearing changes which logical names a
        // physical path answers to — same rule the inotify backend applies.
        if (flags & CF.kFSEventStreamEventFlagItemIsSymlink != 0) {
            noteStructuralChange(self, abs_path, false);
        }

        // FSEvents reports a moved directory as one event and never enumerates
        // what it carried, so the subtree is reconciled explicitly rather than
        // left half-indexed.
        if (flags & CF.kFSEventStreamEventFlagItemIsDir != 0) {
            const structural = CF.kFSEventStreamEventFlagItemCreated |
                CF.kFSEventStreamEventFlagItemRemoved |
                CF.kFSEventStreamEventFlagItemRenamed;
            if (flags & structural == 0) continue;
            if (directoryExists(abs_path)) {
                debug_log.log("watcher.macos: directory appeared path={s}; indexing subtree", .{abs_path});
                emitPhysicalSubtree(self, abs_path);
            } else {
                debug_log.log("watcher.macos: directory vanished path={s}; requesting resync", .{abs_path});
                self.matcher.invalidateAliases();
                _ = emitOverflow(self);
            }
            continue;
        }

        if (flags & CF.kFSEventStreamEventFlagItemIsFile == 0) continue;
        emitPhysicalPath(self, abs_path);
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
    var registry = WatchRegistry.init(self.allocator);
    defer registry.deinit();

    const watch_mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
        linux.IN.MOVED_TO | linux.IN.MOVED_FROM;

    var watch_roots: std.ArrayListUnmanaged(path_matcher.WatchRoot) = .empty;
    defer {
        self.matcher.freeWatchRoots(watch_roots.items);
        watch_roots.deinit(self.allocator);
    }
    self.matcher.watchRoots(&watch_roots) catch return;
    for (watch_roots.items) |root| {
        addWatchSubtree(self, inotify_fd, watch_mask, root.physical_path, &registry);
    }
    debug_log.log("Watcher.linux: watching {d} approved physical roots, {d} directories", .{
        watch_roots.items.len,
        registry.count(),
    });

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
            if (event.mask & linux.IN.Q_OVERFLOW != 0) {
                debug_log.log("watcher.linux: inotify queue overflow; requesting resync", .{});
                _ = emitOverflow(self);
                continue;
            }

            // IN_IGNORED, IN_DELETE_SELF, IN_MOVE_SELF and IN_UNMOUNT arrive
            // without a name and regardless of the requested mask. They mean
            // this watch descriptor no longer describes a live directory in the
            // watched tree, so its bookkeeping has to go with it.
            const self_events = linux.IN.IGNORED | linux.IN.DELETE_SELF |
                linux.IN.MOVE_SELF | linux.IN.UNMOUNT;
            if (event.mask & self_events != 0) {
                handleWatchRetired(self, inotify_fd, event.mask, event.wd, &registry);
                continue;
            }

            const name = event.getName() orelse continue;
            const dir_path = registry.get(event.wd) orelse {
                debug_log.log("watcher.linux: event for retired wd={d}; ignoring", .{event.wd});
                continue;
            };

            const abs_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name }) catch {
                debug_log.log("watcher.linux: event path allocation failed; requesting resync", .{});
                _ = emitOverflow(self);
                continue;
            };
            defer self.allocator.free(abs_path);

            if (self.matcher.ignoresPhysicalPath(abs_path)) continue;

            const is_directory = event.mask & linux.IN.ISDIR != 0;
            const appeared = event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0;
            const vanished = event.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0;

            if (is_directory and appeared) {
                // inotify reports nothing about the contents a directory already
                // had when it was moved in, so the subtree is walked explicitly:
                // watch it, then index every file it brought with it.
                debug_log.log("watcher.linux: directory appeared path={s}; watching and indexing subtree", .{abs_path});
                addWatchSubtree(self, inotify_fd, watch_mask, abs_path, &registry);
                emitPhysicalSubtree(self, abs_path);
                noteStructuralChange(self, abs_path, true);
                continue;
            }

            if (is_directory and vanished) {
                // The descendants are already gone, so they cannot be
                // enumerated. Retire their watches and reconcile the index
                // through a full resync rather than leaving stale entries.
                const retired = registry.removeSubtree(abs_path, inotify_fd);
                debug_log.log(
                    "watcher.linux: directory vanished path={s}; retired {d} watches, requesting resync",
                    .{ abs_path, retired },
                );
                noteStructuralChange(self, abs_path, true);
                _ = emitOverflow(self);
                continue;
            }

            if (is_directory) continue;

            if (appeared or vanished) noteStructuralChange(self, abs_path, false);
            emitPhysicalPath(self, abs_path);
        }
    }
}

fn handleWatchRetired(
    self: *Watcher,
    inotify_fd: posix.fd_t,
    mask: u32,
    wd: i32,
    registry: *WatchRegistry,
) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;

    const dir_path = registry.get(wd) orelse {
        debug_log.log("watcher.linux: retired unknown wd={d} mask=0x{x}", .{ wd, mask });
        return;
    };

    // A moved or deleted watch root takes its whole subtree with it; the
    // descendant watches would otherwise keep reporting events under a path
    // that no longer exists.
    const moved_or_deleted = mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.UNMOUNT) != 0;
    if (moved_or_deleted) {
        const retired = registry.removeSubtree(dir_path, inotify_fd);
        debug_log.log("watcher.linux: watch root retired wd={d} mask=0x{x}; retired {d} watches, requesting resync", .{ wd, mask, retired });
        self.matcher.invalidateAliases();
        _ = emitOverflow(self);
        return;
    }

    debug_log.log("watcher.linux: watch ignored wd={d} path={s}", .{ wd, dir_path });
    registry.remove(wd);
}

fn addWatchSubtree(
    self: *Watcher,
    inotify_fd: posix.fd_t,
    mask: u32,
    dir_path: []const u8,
    registry: *WatchRegistry,
) void {
    if (builtin.os.tag != .linux) return;

    var active = std.AutoHashMap(path_matcher.DirectoryIdentity, void).init(self.allocator);
    defer active.deinit();
    walkWatchedSubtree(self.allocator, &self.matcher, dir_path, 0, &active, .{
        .registry = registry,
        .inotify_fd = inotify_fd,
        .watch_mask = mask,
    }) catch |err| {
        debug_log.log("Watcher.linux: watch setup failed path={s} error={s}; requesting resync", .{ dir_path, @errorName(err) });
        _ = emitOverflow(self);
    };
}

/// Index everything a directory already contained when it appeared. A resync is
/// requested rather than dropping the subtree if the walk cannot complete.
fn emitPhysicalSubtree(self: *Watcher, dir_path: []const u8) void {
    var logical_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (logical_paths.items) |path| self.allocator.free(path);
        logical_paths.deinit(self.allocator);
    }

    var active = std.AutoHashMap(path_matcher.DirectoryIdentity, void).init(self.allocator);
    defer active.deinit();
    walkWatchedSubtree(self.allocator, &self.matcher, dir_path, 0, &active, .{
        .logical_out = &logical_paths,
    }) catch |err| {
        debug_log.log("Watcher.subtree: walk failed path={s} error={s}; requesting resync", .{ dir_path, @errorName(err) });
        _ = emitOverflow(self);
        return;
    };

    debug_log.log("Watcher.subtree: reindexing {d} logical paths under {s}", .{ logical_paths.items.len, dir_path });
    for (logical_paths.items) |logical_path| _ = emitWatcherRecord(self, logical_path);
}

/// Symlinks are what create second logical names for a physical path, so a link
/// appearing or disappearing invalidates the alias table. Plain files and
/// directories are already covered by the prefix of an existing alias.
fn noteStructuralChange(self: *Watcher, physical_path: []const u8, is_directory: bool) void {
    if (is_directory) return;
    if (!isSymbolicLink(physical_path) and !self.matcher.isKnownAliasLink(physical_path)) return;
    debug_log.log("Watcher.aliases: symlink change at {s}; refreshing logical aliases", .{physical_path});
    self.matcher.invalidateAliases();
}

fn isSymbolicLink(physical_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.fs.readLinkAbsolute(physical_path, &buf) catch return false;
    return true;
}

fn directoryExists(physical_path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(physical_path, .{}) catch return false;
    dir.close();
    return true;
}
test "BatchState flushes on size threshold" {
    var state: BatchState = .{};
    state.noteEvent(0);
    state.pending_count = MAX_BATCH_EVENTS;
    try std.testing.expect(state.shouldFlush(0));
}

test "BatchState flushes after quiet window" {
    var state: BatchState = .{};
    state.noteEvent(10);
    try std.testing.expect(!state.shouldFlush(10 + QUIET_WINDOW_NS - 1));
    try std.testing.expect(state.shouldFlush(10 + QUIET_WINDOW_NS));
}

test "line decoder preserves multiple records from one read" {
    var decoder = LineDecoder{};

    const first_event = decoder.feed("first.zig\nsecond.zig\n").?;
    switch (first_event) {
        .path => |path| try std.testing.expectEqualStrings("first.zig", path),
        .overflow => return error.TestUnexpectedResult,
    }

    const second_event = decoder.next().?;
    switch (second_event) {
        .path => |path| try std.testing.expectEqualStrings("second.zig", path),
        .overflow => return error.TestUnexpectedResult,
    }
    try std.testing.expect(decoder.next() == null);
}

test "line decoder reports overflow and resumes at newline" {
    const allocator = std.testing.allocator;
    var decoder = LineDecoder{};
    var oversized = [_]u8{'a'} ** (MAX_WATCHER_LINE_BYTES + 1);
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &oversized);
    try input.appendSlice(allocator, "\nresynced.zig\n");

    try std.testing.expectEqual(DrainEvent.overflow, decoder.feed(input.items));
    const path_event = decoder.next().?;
    switch (path_event) {
        .path => |path| try std.testing.expectEqualStrings("resynced.zig", path),
        .overflow => return error.TestUnexpectedResult,
    }
}

test "line decoder handles many records from one read" {
    const allocator = std.testing.allocator;
    var decoder = LineDecoder{};
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(allocator);

    const record_count = 100;
    for (0..record_count) |_| try input.appendSlice(allocator, "a\n");
    try input.appendSlice(allocator, "last.zig\n");

    var decoded_count: usize = 0;
    var event = decoder.feed(input.items);
    while (event) |decoded| : (event = decoder.next()) {
        switch (decoded) {
            .path => |path| {
                decoded_count += 1;
                if (decoded_count == record_count + 1) try std.testing.expectEqualStrings("last.zig", path);
            },
            .overflow => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(record_count + 1, decoded_count);
}

fn writeTestFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    const file = try dir.createFile(path, .{});
    defer file.close();
    try file.writeAll(contents);
}

test "watch registry owns replaced and removed paths" {
    const allocator = std.testing.allocator;
    var registry = WatchRegistry.init(allocator);
    defer registry.deinit();

    try registry.put(1, "/project/src");
    try registry.put(1, "/project/lib");
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqualStrings("/project/lib", registry.get(1).?);

    try registry.put(2, "/project/docs");
    registry.remove(1);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.get(1) == null);
}

test "watch registry prunes only the moved subtree" {
    const allocator = std.testing.allocator;
    var registry = WatchRegistry.init(allocator);
    defer registry.deinit();

    try registry.put(1, "/project");
    try registry.put(2, "/project/src");
    try registry.put(3, "/project/src/deep");
    try registry.put(4, "/project/srcext");
    try registry.put(5, "/project/docs");

    try std.testing.expectEqual(@as(usize, 2), registry.removeSubtree("/project/src", null));
    try std.testing.expectEqual(@as(usize, 3), registry.count());
    try std.testing.expect(registry.get(2) == null);
    try std.testing.expect(registry.get(3) == null);
    try std.testing.expectEqualStrings("/project", registry.get(1).?);
    try std.testing.expectEqualStrings("/project/srcext", registry.get(4).?);
    try std.testing.expectEqualStrings("/project/docs", registry.get(5).?);
}

fn watchRegistryAllocationScenario(allocator: std.mem.Allocator) !void {
    var registry = WatchRegistry.init(allocator);
    defer registry.deinit();

    try registry.put(1, "/project");
    try registry.put(2, "/project/src");
    try registry.put(2, "/project/src-renamed");
    _ = registry.removeSubtree("/project/src", null);
    try registry.put(3, "/project/docs");
}

test "watch registry releases every path under allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        watchRegistryAllocationScenario,
        .{},
    );
}

fn expectContainsPath(observed: []const []const u8, expected: []const u8) !void {
    for (observed) |path| {
        if (std.mem.eql(u8, path, expected)) return;
    }
    std.debug.print("missing path {s} in:\n", .{expected});
    for (observed) |path| std.debug.print("  {s}\n", .{path});
    return error.TestExpectedPath;
}

fn collectSubtreeForTest(
    matcher: *path_matcher.PathMatcher,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var active = std.AutoHashMap(path_matcher.DirectoryIdentity, void).init(allocator);
    defer active.deinit();
    try walkWatchedSubtree(allocator, matcher, dir_path, 0, &active, .{ .logical_out = out });
}

test "watched subtree collection applies the shared exclusion policy" {
    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();

    try writeTestFile(project.dir, "src/main.zig", "pub fn main() void {}\n");
    try writeTestFile(project.dir, "node_modules/pkg/index.zig", "const dep = true;\n");
    try writeTestFile(project.dir, "zig-out/bin/tool.zig", "const tool = true;\n");
    try writeTestFile(project.dir, ".hidden/secret.zig", "const secret = true;\n");

    const project_root = try project.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var matcher = try path_matcher.PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{"**/*.zig"},
    });
    defer matcher.deinit();

    var logical: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (logical.items) |path| allocator.free(path);
        logical.deinit(allocator);
    }
    try collectSubtreeForTest(&matcher, allocator, project_root, &logical);

    try std.testing.expectEqual(@as(usize, 1), logical.items.len);
    try expectContainsPath(logical.items, "src/main.zig");
}

test "watched subtree collection reports every logical alias of moved-in files" {
    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();

    try writeTestFile(project.dir, "packages/app/main.zig", "pub fn main() void {}\n");
    try project.dir.symLink("packages/app", "app-link", .{ .is_directory = true });

    const project_root = try project.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var matcher = try path_matcher.PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{"**/*.zig"},
    });
    defer matcher.deinit();

    const moved_in = try project.dir.realpathAlloc(allocator, "packages");
    defer allocator.free(moved_in);

    var logical: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (logical.items) |path| allocator.free(path);
        logical.deinit(allocator);
    }
    try collectSubtreeForTest(&matcher, allocator, moved_in, &logical);

    try expectContainsPath(logical.items, "packages/app/main.zig");
    try expectContainsPath(logical.items, "app-link/main.zig");
}

test "watched subtree collection terminates symlink cycles and honors the depth cap" {
    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();

    try writeTestFile(project.dir, "a/shallow.zig", "const shallow = true;\n");
    try writeTestFile(project.dir, "a/b/c/too-deep.zig", "const deep = true;\n");
    try project.dir.symLink("..", "a/loop", .{ .is_directory = true });

    const project_root = try project.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var matcher = try path_matcher.PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{"**/*.zig"},
        .max_depth = 2,
    });
    defer matcher.deinit();

    var logical: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (logical.items) |path| allocator.free(path);
        logical.deinit(allocator);
    }
    try collectSubtreeForTest(&matcher, allocator, project_root, &logical);

    try std.testing.expectEqual(@as(usize, 1), logical.items.len);
    try expectContainsPath(logical.items, "a/shallow.zig");
}

test "recursive watch setup mirrors the collection policy" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();

    try writeTestFile(project.dir, "src/deep/main.zig", "pub fn main() void {}\n");
    try writeTestFile(project.dir, "node_modules/pkg/index.zig", "const dep = true;\n");
    try writeTestFile(project.dir, ".hidden/secret.zig", "const secret = true;\n");
    try project.dir.symLink("..", "src/loop", .{ .is_directory = true });

    const project_root = try project.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var matcher = try path_matcher.PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{"**/*.zig"},
    });
    defer matcher.deinit();

    const linux = std.os.linux;
    const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    const inotify_fd: posix.fd_t = @intCast(@as(isize, @bitCast(rc)));
    try std.testing.expect(inotify_fd >= 0);
    defer posix.close(inotify_fd);

    var registry = WatchRegistry.init(allocator);
    defer registry.deinit();

    var active = std.AutoHashMap(path_matcher.DirectoryIdentity, void).init(allocator);
    defer active.deinit();
    try walkWatchedSubtree(allocator, &matcher, project_root, 0, &active, .{
        .registry = &registry,
        .inotify_fd = inotify_fd,
        .watch_mask = linux.IN.MODIFY,
    });

    var watched: std.ArrayListUnmanaged([]const u8) = .empty;
    defer watched.deinit(allocator);
    var it = registry.entries.valueIterator();
    while (it.next()) |value| try watched.append(allocator, value.*);

    try expectContainsPath(watched.items, project_root);
    for (watched.items) |path| {
        try std.testing.expect(std.mem.indexOf(u8, path, "node_modules") == null);
        try std.testing.expect(std.mem.indexOf(u8, path, "/.hidden") == null);
    }
}

test "Watcher.init releases the settings it copies" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();

    try writeTestFile(project.dir, "src/main.zig", "pub fn main() void {}\n");
    try writeTestFile(project.dir, ".cog/index.scip", "");
    try writeTestFile(project.dir, ".cog/settings.json",
        \\{"code": {"index": ["**/*.zig"]}}
    );

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    try project.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var watcher = Watcher.init(allocator) orelse return error.TestUnexpectedResult;
    watcher.deinit();
}

test "watcher events match initial PathMatcher collection" {
    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    var external = std.testing.tmpDir(.{});
    defer external.cleanup();

    try writeTestFile(project.dir, "src/main.zig", "pub fn main() void {}\n");
    try writeTestFile(project.dir, "src/generated/skip.zig", "const skip = true;\n");
    try writeTestFile(external.dir, "shared.zig", "pub const shared = true;\n");
    try external.dir.symLink("lib", "lib-link", .{ .is_directory = true });
    try writeTestFile(external.dir, "lib/inner.zig", "pub const inner = true;\n");
    const external_root = try external.dir.realpathAlloc(allocator, ".");
    defer allocator.free(external_root);
    try project.dir.symLink("src", "src-link", .{ .is_directory = true });
    try project.dir.symLink("src/main.zig", "entry.zig", .{});
    try project.dir.symLink(external_root, "shared-link", .{ .is_directory = true });

    const project_root = try project.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);
    var matcher = try path_matcher.PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{ "**/*.zig", "!**/generated/**" },
        .external_roots = &.{external_root},
    });
    defer matcher.deinit();

    var collected: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        matcher.freeMatchedPaths(collected.items);
        collected.deinit(allocator);
    }
    try matcher.collect(&collected);

    var watched = std.StringHashMapUnmanaged(void){};
    defer {
        var it = watched.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        watched.deinit(allocator);
    }
    for (collected.items) |file| {
        var mapped: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (mapped.items) |path| allocator.free(path);
            mapped.deinit(allocator);
        }
        try collectLogicalEvents(&matcher, file.physical_path, &mapped);
        for (mapped.items) |path| {
            if (!watched.contains(path)) try watched.put(allocator, try allocator.dupe(u8, path), {});
        }
    }

    try std.testing.expectEqual(collected.items.len, watched.count());
    for (collected.items) |file| try std.testing.expect(watched.contains(file.logical_path));
}
