const std = @import("std");
const builtin = @import("builtin");
pub const c = @import("c.zig");

const log = std.log.scoped(.uriparser);

// Use Zig ArenaAllocator to allocate memory for uriparser.
fn _malloc(mmc: [*c]c.UriMemoryManager, size: usize) callconv(.C) ?*anyopaque {
    const mm: *c.UriMemoryManager = @ptrCast(@alignCast(mmc));
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(mm.userData));
    const alloc = arena.allocator();
    const mem = alloc.alloc(u8, size) catch |err| {
        log.err("unable to alloc {}", .{err});
        return null;
    };
    return mem.ptr;
}

// This is a NOOP since we are using an ArenaAllocator
fn _free(_: [*c]c.UriMemoryManager, _: ?*anyopaque) callconv(.C) void {}

fn textRangeToString(range: *c.UriTextRangeA) ?[]const u8 {
    if (range.first == null or range.afterLast == null) return null;
    const f = @intFromPtr(range.first);
    const l = @intFromPtr(range.afterLast);
    if (l < f) return null;
    const length = l - f;
    if (length == 0) return null;
    return range.first[0..length];
}

const Error = error{
    SyntaxError,
    NullParameter,
    OutOfMemory,
    OutputTooLarge,
    NotImplemented,
    RangeInvalid,
    MemoryManagerIncomplete,
    BaseNotAbsolute,
    SourceNotAbsolute,
    MemoryManagerFaulty,
};

fn wrap(errno: c_int) Error!void {
    return switch (errno) {
        c.URI_SUCCESS => void{},
        c.URI_ERROR_SYNTAX => error.SyntaxError,
        c.URI_ERROR_NULL => error.NullParameter,
        c.URI_ERROR_MALLOC => error.OutOfMemory,
        c.URI_ERROR_OUTPUT_TOO_LARGE => error.OutputTooLarge,
        c.URI_ERROR_NOT_IMPLEMENTED => error.NotImplemented,
        c.URI_ERROR_RANGE_INVALID => error.RangeInvalid,
        c.URI_ERROR_MEMORY_MANAGER_INCOMPLETE => error.MemoryManagerIncomplete,
        c.URI_ERROR_ADDBASE_REL_BASE => error.BaseNotAbsolute,
        c.URI_ERROR_REMOVEBASE_REL_BASE => error.BaseNotAbsolute,
        c.URI_ERROR_REMOVEBASE_REL_SOURCE => error.SourceNotAbsolute,
        c.URI_ERROR_MEMORY_MANAGER_FAULTY => error.MemoryManagerFaulty,
        else => unreachable,
    };
}

fn logError(info: []const u8, errno: Error, pos: ?usize) void {
    switch (errno) {
        error.SyntaxError => {
            if (pos) |p|
                log.err("{s} syntax error: (at pos {})", .{ info, p })
            else
                log.err("{s}: syntax error", .{info});
        },
        error.NullParameter => {
            log.err("{s}: null parameter", .{info});
        },
        error.OutOfMemory => {
            log.err("{s}: requested memory could not be allocated", .{info});
        },
        error.OutputTooLarge => {
            log.err("{s}: some output is too large for the receiving buffer", .{info});
        },
        error.NotImplemented => {
            log.err("{s}: the called function is not implemented yet", .{info});
        },
        error.RangeInvalid => {
            log.err("{s}: the parameters passed included invalid ranges", .{info});
        },
        error.MemoryManagerIncomplete => {
            log.err("{s}: the URI memory manager does not implement all needed functions", .{info});
        },
        error.BaseNotAbsolute => {
            log.err("{s}: given base is not absolute", .{info});
        },
        error.SourceNotAbsolute => {
            log.err("{s}: given base is not absolute", .{info});
        },
        error.MemoryManagerFaulty => {
            log.err("{s}: the memory manager did not pass the test suite", .{info});
        },
        else => unreachable,
    }
}

const QueryKV = struct {
    key: []const u8,
    value: ?[]const u8,
};

const Uri = struct {
    arena: std.heap.ArenaAllocator,
    mm: c.UriMemoryManager,
    backend: c.UriMemoryManager,
    uri: c.UriUriA,

    fn new(allocator: std.mem.Allocator) !*Uri {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const alloc = arena.allocator();

        var uri = try alloc.create(Uri);

        uri.*.arena = arena;
        uri.*.backend = .{
            .malloc = _malloc,
            .calloc = null,
            .realloc = null,
            .reallocarray = null,
            .free = _free,
            .userData = &uri.arena,
        };

        try wrap(c.uriCompleteMemoryManager(&uri.mm, &uri.backend));

        @memset(@as([*]u8, @ptrCast(&uri.uri))[0..@sizeOf(c.UriUriA)], 0);

        return uri;
    }

    pub fn parse(allocator: std.mem.Allocator, text: [:0]const u8, options: struct {
        log_errors: bool = false,
    }) !*Uri {
        var uri = try Uri.new(allocator);
        errdefer uri.deinit();

        var err_ptr: [*c]const u8 = undefined;
        wrap(c.uriParseSingleUriExMmA(&uri.uri, text, &text[text.len], &err_ptr, &uri.mm)) catch |err| {
            if (options.log_errors)
                switch (err) {
                    error.SyntaxError => {
                        const err_pos: ?usize = err_pos: {
                            if (err_ptr == null) break :err_pos null;

                            const err_pos = @intFromPtr(err_ptr) - @intFromPtr(text.ptr);
                            if (err_pos > text.len) break :err_pos null;

                            var location = try allocator.alloc(u8, text.len);
                            defer allocator.free(location);
                            @memset(location, '~');
                            location[err_pos] = '^';

                            log.err("error parsing: {s}", .{text});
                            log.err("at location  : {s}", .{location});

                            break :err_pos err_pos;
                        };
                        logError("parsing uri", err, err_pos);
                    },
                    else => {
                        logError("parsing uri", err, null);
                    },
                };
            return err;
        };

        return uri;
    }

    pub fn deinit(self: *Uri) void {
        wrap(c.uriFreeUriMembersMmA(&self.uri, &self.mm)) catch {};
        self.arena.deinit();
    }

    pub fn scheme(self: *Uri) ?[]const u8 {
        return textRangeToString(&self.uri.scheme);
    }

    pub fn hostv4(self: *Uri) ?std.net.Ip4Address {
        if (self.uri.hostData.ip4 == null) return null;
        return std.net.Ip6Address.init(
            self.uri.hostData.ip4,
            self.port() orelse 0,
            0,
            0,
        );
    }

    pub fn hostv6(self: *Uri) ?std.net.Ip6Address {
        if (self.uri.hostData.ip6 == null) return null;
        return std.net.Ip6Address.init(
            self.uri.hostData.ip6,
            self.port() orelse 0,
            0,
            0,
        );
    }

    pub fn host(self: *Uri) ?[]const u8 {
        return textRangeToString(&self.uri.hostText);
    }

    pub fn port(self: *Uri) !?u16 {
        if (textRangeToString(&self.uri.portText)) |text|
            return try std.fmt.parseUnsigned(u16, text, 10);
        return null;
    }

    pub fn path(self: *Uri) ![]const []const u8 {
        var list = std.ArrayList([]const u8).init(self.arena.allocator());
        errdefer list.deinit();

        var ptr: ?*c.UriPathSegmentA = self.uri.pathHead;
        while (ptr) |node| {
            if (textRangeToString(&node.text)) |text|
                try list.append(text)
            else
                try list.append("");
            ptr = node.next;
        }

        return try list.toOwnedSlice();
    }

    pub fn query(self: *Uri) ![]QueryKV {
        const alloc = self.arena.allocator();

        var query_list: ?c.UriQueryListA = undefined;
        var count: c_int = undefined;
        try wrap(c.uriDissectQueryMallocExMmA(
            &query_list,
            &count,
            self.uri.query.first,
            self.uri.query.afterLast,
            true,
            c.URI_BR_DONT_TOUCH,
            &self.mm,
        ));
        defer c.uriFreeQueryListA(query_list);

        var list = std.ArrayList(QueryKV).init(self.arena);
        errdefer list.deinit();

        var ptr = query_list;
        while (ptr) |node| {
            list.append(
                .{
                    .key = try alloc.dupe(std.mem.span(node.key)),
                    .value = if (node.value != null) try alloc.dupe(std.mem.span(node.value)) else null,
                },
            );
            ptr = node.next;
        }
    }

    pub fn toString(self: *Uri, alloc: std.mem.Allocator) ![:0]const u8 {
        var required: c_int = undefined;

        try wrap(c.uriToStringCharsRequiredA(&self.uri, &required));

        std.debug.assert(required >= 0);

        const str = try alloc.alloc(u8, @intCast(required + 1));
        defer alloc.free(str);

        var written: c_int = undefined;

        try wrap(c.uriToStringA(str.ptr, &self.uri, required + 1, &written));

        std.debug.assert(written > 0);

        return try alloc.dupeZ(u8, str[0..@intCast(written - 1)]);
    }

    pub fn resolve(self: *Uri, ref: *Uri) !*Uri {
        var dest = try Uri.new(self.arena.child_allocator);
        errdefer dest.deinit();

        try wrap(c.uriAddBaseUriExMmA(&dest.uri, &ref.uri, &self.uri, 0, &self.mm));

        return dest;
    }

    // pub fn normalize(self: *Uri) !*Uri {
    //     c.uriDissectQueryMallocA(, , , )
    // }
};

test "basic parse" {
    const expected = "https://www.example.com";
    var uri = try Uri.parse(std.testing.allocator, expected, .{});
    defer uri.deinit();
    const actual = try uri.toString(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSentinel(u8, 0, expected, actual);
}

test "parse error" {
    try std.testing.expectError(error.SyntaxError, Uri.parse(std.testing.allocator, "http://www yahoo.com", .{}));
}

test "resolve" {
    const base = try Uri.parse(std.testing.allocator, "file:///one/two/three", .{});
    defer base.deinit();
    const relative = try Uri.parse(std.testing.allocator, "../TWO", .{});
    defer relative.deinit();

    const resolved = try base.resolve(relative);
    defer resolved.deinit();

    const actual = try resolved.toString(std.testing.allocator);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualSentinel(u8, 0, "file:///one/TWO", actual);
}

test "path" {
    const uri = try Uri.parse(std.testing.allocator, "file:///one/two/three", .{});
    defer uri.deinit();
    const path = try uri.path();
    try std.testing.expectEqualStrings("one", path[0]);
    try std.testing.expectEqualStrings("two", path[1]);
    try std.testing.expectEqualStrings("three", path[2]);
}

pub fn toFileUri(alloc: std.mem.Allocator, path: [:0]const u8) ![:0]const u8 {
    // create a temporary buffer that is larger than any possible result
    const uri = try alloc.allocSentinel(u8, 8 + 3 * path.len + 1, 0);
    defer alloc.free(uri);

    try wrap(switch (builtin.os.tag) {
        .windows => c.uriWindowsFilenameToUriStringA(path, uri.ptr),
        else => c.uriUnixFilenameToUriStringA(path, uri.ptr),
    });

    // return a buffer that is just large enough for the final URI
    return try alloc.dupeZ(u8, std.mem.span(uri.ptr));
}

pub fn composeQuery(allocator: std.mem.Allocator, terms: []QueryKV) ![:0]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var head: ?*c.UriQueryListA = null;
    var tail: ?*c.UriQueryListA = null;

    for (terms) |term| {
        const node = try alloc.create(c.UriQueryListA);
        node.*.key = try alloc.dupeZ(u8, term.key);
        node.*.value = if (term.value) |value| try alloc.dupeZ(u8, value) else null;
        node.*.next = null;
        if (head == null) head = node;
        if (tail == null) tail = node else tail.?.*.next = node;
    }

    var required: c_int = undefined;

    try wrap(c.uriComposeQueryCharsRequiredA(head, &required));

    std.debug.assert(required >= 0);

    if (required == 0) return try alloc.dupeZ(u8, "");

    const text = try alloc.alloc(u8, @intCast(required + 1));
    defer alloc.free(text);

    var written: c_int = undefined;
    try wrap(c.uriComposeQueryA(text.ptr, head, required + 1, &written));

    return try alloc.dupeZ(u8, text[0..@intCast(written - 1)]);
}

test "decls" {
    std.testing.refAllDecls(@This());
}
