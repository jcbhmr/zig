//! This API is non-allocating, non-fallible, and thread-safe.
//!
//! The tradeoff is that users of this API must provide the storage
//! for each `Progress.Node`.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const testing = std.testing;
const assert = std.debug.assert;
const Progress = @This();
const posix = std.posix;

/// `null` if the current node (and its children) should
/// not print on update()
terminal: ?std.fs.File,

/// Is this a windows API terminal (note: this is not the same as being run on windows
/// because other terminals exist like MSYS/git-bash)
is_windows_terminal: bool,

/// Whether the terminal supports ANSI escape codes.
supports_ansi_escape_codes: bool,

update_thread: ?std.Thread,

/// Atomically set by SIGWINCH as well as the root done() function.
redraw_event: std.Thread.ResetEvent,
/// Indicates a request to shut down and reset global state.
/// Accessed atomically.
done: bool,

refresh_rate_ns: u64,
initial_delay_ns: u64,

rows: u16,
cols: u16,
/// Needed because terminal escape codes require one to take scrolling into
/// account.
newline_count: u16,

/// Accessed only by the update thread.
draw_buffer: []u8,

/// This is in a separate array from `node_storage` but with the same length so
/// that it can be iterated over efficiently without trashing too much of the
/// CPU cache.
node_parents: []Node.Parent,
node_storage: []Node.Storage,
node_freelist: []Node.OptionalIndex,
node_freelist_first: Node.OptionalIndex,
node_end_index: u32,

pub const Options = struct {
    /// User-provided buffer with static lifetime.
    ///
    /// Used to store the entire write buffer sent to the terminal. Progress output will be truncated if it
    /// cannot fit into this buffer which will look bad but not cause any malfunctions.
    ///
    /// Must be at least 200 bytes.
    draw_buffer: []u8,
    /// How many nanoseconds between writing updates to the terminal.
    refresh_rate_ns: u64 = 60 * std.time.ns_per_ms,
    /// How many nanoseconds to keep the output hidden
    initial_delay_ns: u64 = 500 * std.time.ns_per_ms,
    /// If provided, causes the progress item to have a denominator.
    /// 0 means unknown.
    estimated_total_items: usize = 0,
    root_name: []const u8 = "",
};

/// Represents one unit of progress. Each node can have children nodes, or
/// one can use integers with `update`.
pub const Node = struct {
    index: OptionalIndex,

    pub const max_name_len = 38;

    const Storage = extern struct {
        /// Little endian.
        completed_count: u32,
        /// 0 means unknown.
        /// Little endian.
        estimated_total_count: u32,
        name: [max_name_len]u8,
    };

    const Parent = enum(u16) {
        /// Unallocated storage.
        unused = std.math.maxInt(u16) - 1,
        /// Indicates root node.
        none = std.math.maxInt(u16),
        /// Index into `node_storage`.
        _,

        fn unwrap(i: @This()) ?Index {
            return switch (i) {
                .unused, .none => return null,
                else => @enumFromInt(@intFromEnum(i)),
            };
        }
    };

    const OptionalIndex = enum(u16) {
        none = std.math.maxInt(u16),
        /// Index into `node_storage`.
        _,

        fn unwrap(i: @This()) ?Index {
            if (i == .none) return null;
            return @enumFromInt(@intFromEnum(i));
        }

        fn toParent(i: @This()) Parent {
            assert(@intFromEnum(i) != @intFromEnum(Parent.unused));
            return @enumFromInt(@intFromEnum(i));
        }
    };

    /// Index into `node_storage`.
    const Index = enum(u16) {
        _,

        fn toParent(i: @This()) Parent {
            assert(@intFromEnum(i) != @intFromEnum(Parent.unused));
            assert(@intFromEnum(i) != @intFromEnum(Parent.none));
            return @enumFromInt(@intFromEnum(i));
        }

        fn toOptional(i: @This()) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }
    };

    /// Create a new child progress node. Thread-safe.
    ///
    /// Passing 0 for `estimated_total_items` means unknown.
    pub fn start(node: Node, name: []const u8, estimated_total_items: usize) Node {
        const node_index = node.index.unwrap() orelse return .{ .index = .none };
        const parent = node_index.toParent();

        const freelist_head = &global_progress.node_freelist_first;
        var opt_free_index = @atomicLoad(Node.OptionalIndex, freelist_head, .seq_cst);
        while (opt_free_index.unwrap()) |free_index| {
            const freelist_ptr = freelistByIndex(free_index);
            opt_free_index = @cmpxchgWeak(Node.OptionalIndex, freelist_head, opt_free_index, freelist_ptr.*, .seq_cst, .seq_cst) orelse {
                // We won the allocation race.
                return init(free_index, parent, name, estimated_total_items);
            };
        }

        const free_index = @atomicRmw(u32, &global_progress.node_end_index, .Add, 1, .monotonic);
        if (free_index >= global_progress.node_storage.len) {
            // Ran out of node storage memory. Progress for this node will not be tracked.
            _ = @atomicRmw(u32, &global_progress.node_end_index, .Sub, 1, .monotonic);
            return .{ .index = .none };
        }

        return init(@enumFromInt(free_index), parent, name, estimated_total_items);
    }

    /// This is the same as calling `start` and then `end` on the returned `Node`. Thread-safe.
    pub fn completeOne(n: Node) void {
        const index = n.index.unwrap() orelse return;
        const storage = storageByIndex(index);
        _ = @atomicRmw(u32, &storage.completed_count, .Add, 1, .monotonic);
    }

    /// Thread-safe.
    pub fn setCompletedItems(n: Node, completed_items: usize) void {
        const index = n.index.unwrap() orelse return;
        const storage = storageByIndex(index);
        @atomicStore(u32, &storage.completed_count, std.math.lossyCast(u32, completed_items), .monotonic);
    }

    /// Thread-safe. 0 means unknown.
    pub fn setEstimatedTotalItems(n: Node, count: usize) void {
        const index = n.index.unwrap() orelse return;
        const storage = storageByIndex(index);
        @atomicStore(u32, &storage.estimated_total_count, std.math.lossyCast(u32, count), .monotonic);
    }

    /// Finish a started `Node`. Thread-safe.
    pub fn end(n: Node) void {
        const index = n.index.unwrap() orelse return;
        const parent_ptr = parentByIndex(index);
        if (parent_ptr.unwrap()) |parent_index| {
            _ = @atomicRmw(u32, &storageByIndex(parent_index).completed_count, .Add, 1, .monotonic);
            @atomicStore(Node.Parent, parent_ptr, .unused, .seq_cst);

            const freelist_head = &global_progress.node_freelist_first;
            var first = @atomicLoad(Node.OptionalIndex, freelist_head, .seq_cst);
            while (true) {
                freelistByIndex(index).* = first;
                first = @cmpxchgWeak(Node.OptionalIndex, freelist_head, first, index.toOptional(), .seq_cst, .seq_cst) orelse break;
            }
        } else {
            @atomicStore(bool, &global_progress.done, true, .seq_cst);
            global_progress.redraw_event.set();
            if (global_progress.update_thread) |thread| thread.join();
        }
    }

    fn storageByIndex(index: Node.Index) *Node.Storage {
        return &global_progress.node_storage[@intFromEnum(index)];
    }

    fn parentByIndex(index: Node.Index) *Node.Parent {
        return &global_progress.node_parents[@intFromEnum(index)];
    }

    fn freelistByIndex(index: Node.Index) *Node.OptionalIndex {
        return &global_progress.node_freelist[@intFromEnum(index)];
    }

    fn init(free_index: Index, parent: Parent, name: []const u8, estimated_total_items: usize) Node {
        assert(parent != .unused);

        const storage = storageByIndex(free_index);
        storage.* = .{
            .completed_count = 0,
            .estimated_total_count = std.math.lossyCast(u32, estimated_total_items),
            .name = [1]u8{0} ** max_name_len,
        };
        const name_len = @min(max_name_len, name.len);
        @memcpy(storage.name[0..name_len], name[0..name_len]);

        const parent_ptr = parentByIndex(free_index);
        assert(parent_ptr.* == .unused);
        @atomicStore(Node.Parent, parent_ptr, parent, .release);

        return .{ .index = free_index.toOptional() };
    }
};

var global_progress: Progress = .{
    .terminal = null,
    .is_windows_terminal = false,
    .supports_ansi_escape_codes = false,
    .update_thread = null,
    .redraw_event = .{},
    .refresh_rate_ns = undefined,
    .initial_delay_ns = undefined,
    .rows = 0,
    .cols = 0,
    .newline_count = 0,
    .draw_buffer = undefined,
    .done = false,

    // TODO: make these configurable and avoid including the globals in .data if unused
    .node_parents = &node_parents_buffer,
    .node_storage = &node_storage_buffer,
    .node_freelist = &node_freelist_buffer,
    .node_freelist_first = .none,
    .node_end_index = 0,
};

const default_node_storage_buffer_len = 100;
var node_parents_buffer: [default_node_storage_buffer_len]Node.Parent = undefined;
var node_storage_buffer: [default_node_storage_buffer_len]Node.Storage = undefined;
var node_freelist_buffer: [default_node_storage_buffer_len]Node.OptionalIndex = undefined;

/// Initializes a global Progress instance.
///
/// Asserts there is only one global Progress instance.
///
/// Call `Node.end` when done.
pub fn start(options: Options) Node {
    // Ensure there is only 1 global Progress object.
    assert(global_progress.node_end_index == 0);
    const stderr = std.io.getStdErr();
    if (stderr.supportsAnsiEscapeCodes()) {
        global_progress.terminal = stderr;
        global_progress.supports_ansi_escape_codes = true;
    } else if (builtin.os.tag == .windows and stderr.isTty()) {
        global_progress.is_windows_terminal = true;
        global_progress.terminal = stderr;
    } else if (builtin.os.tag != .windows) {
        // we are in a "dumb" terminal like in acme or writing to a file
        global_progress.terminal = stderr;
    }
    @memset(global_progress.node_parents, .unused);
    const root_node = Node.init(@enumFromInt(0), .none, options.root_name, options.estimated_total_items);
    global_progress.done = false;
    global_progress.node_end_index = 1;

    assert(options.draw_buffer.len >= 200);
    global_progress.draw_buffer = options.draw_buffer;
    global_progress.refresh_rate_ns = options.refresh_rate_ns;
    global_progress.initial_delay_ns = options.initial_delay_ns;

    var act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSigWinch },
        .mask = posix.empty_sigset,
        .flags = (posix.SA.SIGINFO | posix.SA.RESTART),
    };
    posix.sigaction(posix.SIG.WINCH, &act, null) catch {
        global_progress.terminal = null;
        return root_node;
    };

    if (global_progress.terminal != null) {
        if (std.Thread.spawn(.{}, updateThreadRun, .{})) |thread| {
            global_progress.update_thread = thread;
        } else |_| {
            global_progress.terminal = null;
        }
    }

    return root_node;
}

/// Returns whether a resize is needed to learn the terminal size.
fn wait(timeout_ns: u64) bool {
    const resize_flag = if (global_progress.redraw_event.timedWait(timeout_ns)) |_|
        true
    else |err| switch (err) {
        error.Timeout => false,
    };
    global_progress.redraw_event.reset();
    return resize_flag or (global_progress.cols == 0);
}

fn updateThreadRun() void {
    {
        const resize_flag = wait(global_progress.initial_delay_ns);
        maybeUpdateSize(resize_flag);

        const buffer = b: {
            if (@atomicLoad(bool, &global_progress.done, .seq_cst))
                return clearTerminal();

            break :b computeRedraw();
        };
        write(buffer);
    }

    while (true) {
        const resize_flag = wait(global_progress.refresh_rate_ns);
        maybeUpdateSize(resize_flag);

        const buffer = b: {
            if (@atomicLoad(bool, &global_progress.done, .seq_cst))
                return clearTerminal();

            break :b computeRedraw();
        };
        write(buffer);
    }
}

const start_sync = "\x1b[?2026h";
const up_one_line = "\x1bM";
const clear = "\x1b[J";
const save = "\x1b7";
const restore = "\x1b8";
const finish_sync = "\x1b[?2026l";

const tree_tee = "\x1B\x28\x30\x74\x71\x1B\x28\x42 "; // ├─
const tree_line = "\x1B\x28\x30\x78\x1B\x28\x42  "; // │
const tree_langle = "\x1B\x28\x30\x6d\x71\x1B\x28\x42 "; // └─

fn clearTerminal() void {
    write(clear);
}

const Children = struct {
    child: Node.OptionalIndex,
    sibling: Node.OptionalIndex,
};

fn computeRedraw() []u8 {
    // TODO make this configurable
    var serialized_node_parents_buffer: [default_node_storage_buffer_len]Node.Parent = undefined;
    var serialized_node_storage_buffer: [default_node_storage_buffer_len]Node.Storage = undefined;
    var serialized_node_map_buffer: [default_node_storage_buffer_len]Node.Index = undefined;
    var serialized_len: usize = 0;

    // Iterate all of the nodes and construct a serializable copy of the state that can be examined
    // without atomics.
    const end_index = @atomicLoad(u32, &global_progress.node_end_index, .monotonic);
    const node_parents = global_progress.node_parents[0..end_index];
    const node_storage = global_progress.node_storage[0..end_index];
    for (node_parents, node_storage, 0..) |*parent_ptr, *storage_ptr, i| {
        var begin_parent = @atomicLoad(Node.Parent, parent_ptr, .seq_cst);
        while (begin_parent != .unused) {
            const dest_storage = &serialized_node_storage_buffer[serialized_len];
            @memcpy(&dest_storage.name, &storage_ptr.name);
            dest_storage.completed_count = @atomicLoad(u32, &storage_ptr.completed_count, .monotonic);
            dest_storage.estimated_total_count = @atomicLoad(u32, &storage_ptr.estimated_total_count, .monotonic);

            const end_parent = @atomicLoad(Node.Parent, parent_ptr, .seq_cst);
            if (begin_parent == end_parent) {
                serialized_node_parents_buffer[serialized_len] = begin_parent;
                serialized_node_map_buffer[i] = @enumFromInt(serialized_len);
                serialized_len += 1;
                break;
            }

            begin_parent = end_parent;
        }
    }

    // Now we can analyze our copy of the graph without atomics, reconstructing
    // children lists which do not exist in the canonical data. These are
    // needed for tree traversal below.
    const serialized_node_parents = serialized_node_parents_buffer[0..serialized_len];
    const serialized_node_storage = serialized_node_storage_buffer[0..serialized_len];

    // Remap parents to point inside serialized arrays.
    for (serialized_node_parents) |*parent| {
        parent.* = switch (parent.*) {
            .unused => unreachable,
            .none => .none,
            _ => |p| serialized_node_map_buffer[@intFromEnum(p)].toParent(),
        };
    }

    var children_buffer: [default_node_storage_buffer_len]Children = undefined;
    const children = children_buffer[0..serialized_len];

    @memset(children, .{ .child = .none, .sibling = .none });

    for (serialized_node_parents, 0..) |parent, child_index_usize| {
        const child_index: Node.Index = @enumFromInt(child_index_usize);
        assert(parent != .unused);
        const parent_index = parent.unwrap() orelse continue;
        const children_node = &children[@intFromEnum(parent_index)];
        if (children_node.child.unwrap()) |existing_child_index| {
            const existing_child = &children[@intFromEnum(existing_child_index)];
            existing_child.sibling = child_index.toOptional();
            children[@intFromEnum(child_index)].sibling = existing_child.sibling;
        } else {
            children_node.child = child_index.toOptional();
        }
    }

    // The strategy is: keep the cursor at the end, and then with every redraw:
    // move cursor to beginning of line, move cursor up N lines, erase to end of screen, write

    var i: usize = 0;
    const buf = global_progress.draw_buffer;

    buf[i..][0..start_sync.len].* = start_sync.*;
    i += start_sync.len;

    const prev_nl_n = global_progress.newline_count;
    if (global_progress.newline_count > 0) {
        global_progress.newline_count = 0;
        buf[i] = '\r';
        i += 1;
        for (0..prev_nl_n) |_| {
            buf[i..][0..up_one_line.len].* = up_one_line.*;
            i += up_one_line.len;
        }
    }

    buf[i..][0..clear.len].* = clear.*;
    i += clear.len;

    const root_node_index: Node.Index = @enumFromInt(0);
    i = computeNode(buf, i, serialized_node_storage, serialized_node_parents, children, root_node_index);

    // Truncate trailing newline.
    //if (buf[i - 1] == '\n') i -= 1;

    buf[i..][0..finish_sync.len].* = finish_sync.*;
    i += finish_sync.len;

    return buf[0..i];
}

fn computePrefix(
    buf: []u8,
    start_i: usize,
    serialized_node_storage: []const Node.Storage,
    serialized_node_parents: []const Node.Parent,
    children: []const Children,
    node_index: Node.Index,
) usize {
    var i = start_i;
    const parent_index = serialized_node_parents[@intFromEnum(node_index)].unwrap() orelse return i;
    if (serialized_node_parents[@intFromEnum(parent_index)] == .none) return i;
    i = computePrefix(buf, i, serialized_node_storage, serialized_node_parents, children, parent_index);
    if (children[@intFromEnum(parent_index)].sibling == .none) {
        buf[i..][0..3].* = "   ".*;
        i += 3;
    } else {
        buf[i..][0..tree_line.len].* = tree_line.*;
        i += tree_line.len;
    }
    return i;
}

fn computeNode(
    buf: []u8,
    start_i: usize,
    serialized_node_storage: []const Node.Storage,
    serialized_node_parents: []const Node.Parent,
    children: []const Children,
    node_index: Node.Index,
) usize {
    var i = start_i;
    i = computePrefix(buf, i, serialized_node_storage, serialized_node_parents, children, node_index);

    const storage = &serialized_node_storage[@intFromEnum(node_index)];
    const estimated_total = storage.estimated_total_count;
    const completed_items = storage.completed_count;
    const name = if (std.mem.indexOfScalar(u8, &storage.name, 0)) |end| storage.name[0..end] else &storage.name;
    const parent = serialized_node_parents[@intFromEnum(node_index)];

    if (parent != .none) {
        if (children[@intFromEnum(node_index)].sibling == .none) {
            buf[i..][0..tree_langle.len].* = tree_langle.*;
            i += tree_langle.len;
        } else {
            buf[i..][0..tree_tee.len].* = tree_tee.*;
            i += tree_tee.len;
        }
    }

    if (name.len != 0 or estimated_total > 0) {
        if (estimated_total > 0) {
            i += (std.fmt.bufPrint(buf[i..], "[{d}/{d}] ", .{ completed_items, estimated_total }) catch &.{}).len;
        } else if (completed_items != 0) {
            i += (std.fmt.bufPrint(buf[i..], "[{d}] ", .{completed_items}) catch &.{}).len;
        }
        if (name.len != 0) {
            i += (std.fmt.bufPrint(buf[i..], "{s}", .{name}) catch &.{}).len;
        }
    }

    i = @min(global_progress.cols + start_i, i);
    buf[i] = '\n';
    i += 1;
    global_progress.newline_count += 1;

    if (children[@intFromEnum(node_index)].child.unwrap()) |child| {
        i = computeNode(buf, i, serialized_node_storage, serialized_node_parents, children, child);
    }

    {
        var opt_sibling = children[@intFromEnum(node_index)].sibling;
        while (opt_sibling.unwrap()) |sibling| {
            i = computeNode(buf, i, serialized_node_storage, serialized_node_parents, children, sibling);
        }
    }

    return i;
}

fn write(buf: []const u8) void {
    const tty = global_progress.terminal orelse return;
    tty.writeAll(buf) catch {
        global_progress.terminal = null;
    };
}

fn maybeUpdateSize(resize_flag: bool) void {
    if (!resize_flag) return;

    var winsize: posix.winsize = .{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const fd = (global_progress.terminal orelse return).handle;

    const err = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (posix.errno(err) == .SUCCESS) {
        global_progress.rows = winsize.ws_row;
        global_progress.cols = winsize.ws_col;
    } else {
        @panic("TODO: handle this failure");
    }
}

fn handleSigWinch(sig: i32, info: *const posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.C) void {
    _ = info;
    _ = ctx_ptr;
    assert(sig == posix.SIG.WINCH);
    global_progress.redraw_event.set();
}
