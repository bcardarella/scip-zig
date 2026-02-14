const std = @import("std");
const Analyzer = @import("Analyzer.zig");
const offsets = @import("offsets.zig");

const logger = std.log.scoped(.store);

const DocumentStore = @This();

allocator: std.mem.Allocator,
root_path: []const u8,
/// Root -> Package
packages: std.StringHashMapUnmanaged(Package) = .{},

pub const Package = struct {
    root: []const u8,
    /// Relative path of the root file (used for package import resolution)
    root_relative: []const u8 = "",
    /// Relative path -> Handle
    handles: std.StringHashMapUnmanaged(*Handle) = .{},
    /// Paths currently being loaded (for import cycle detection)
    loading: std.StringHashMapUnmanaged(void) = .{},
};

pub const Handle = struct {
    document_store: *DocumentStore,
    package: []const u8,
    /// Relative to package root
    path: []const u8,
    text: [:0]const u8,
    tree: std.zig.Ast,
    analyzer: Analyzer,
    /// Pre-scanned @import builtin call nodes for O(1) lookup
    import_nodes: std.ArrayListUnmanaged(std.zig.Ast.Node.Index) = .{},
    /// Pre-built line offset table for O(log n) position lookups
    line_index: offsets.LineIndex = .{ .line_offsets = &.{0} },

    pub const PathFormatter = struct {
        handle: Handle,

        pub fn format(
            self: PathFormatter,
            writer: anytype,
        ) !void {
            var splitit = std.mem.splitScalar(u8, self.handle.path, std.fs.path.sep);
            while (splitit.next()) |segment| {
                if (std.mem.indexOfAny(u8, segment, ".") != null)
                    try writer.print("`{s}`", .{segment})
                else
                    try writer.writeAll(segment);

                try writer.writeByte('/');
            }
        }
    };

    pub fn formatter(handle: Handle) PathFormatter {
        return .{ .handle = handle };
    }
};

pub fn deinit(store: *DocumentStore) void {
    var pkg_it = store.packages.iterator();
    while (pkg_it.next()) |pkg_entry| {
        var handle_it = pkg_entry.value_ptr.handles.iterator();
        while (handle_it.next()) |h| {
            const handle = h.value_ptr.*;
            handle.analyzer.deinit();
            handle.import_nodes.deinit(store.allocator);
            store.allocator.free(handle.line_index.line_offsets);
            handle.tree.deinit(store.allocator);
            store.allocator.free(handle.text);
            store.allocator.free(handle.path);
            store.allocator.destroy(handle);
        }
        pkg_entry.value_ptr.handles.deinit(store.allocator);
        pkg_entry.value_ptr.loading.deinit(store.allocator);
        store.allocator.free(pkg_entry.value_ptr.root);
        store.allocator.free(pkg_entry.value_ptr.root_relative);
        store.allocator.free(pkg_entry.key_ptr.*);
    }
    store.packages.deinit(store.allocator);
}

pub fn createPackage(store: *DocumentStore, package: []const u8, root: []const u8) !void {
    if (store.packages.contains(package)) return;

    const root_relative = try std.fs.path.relative(store.allocator, store.root_path, root);
    try store.packages.put(store.allocator, try store.allocator.dupe(u8, package), .{
        .root = try store.allocator.dupe(u8, root),
        .root_relative = root_relative,
    });

    _ = try store.loadFile(package, root_relative);
}

pub fn loadFile(store: *DocumentStore, package: []const u8, path: []const u8) !*Handle {
    std.log.info("Loading {s}", .{path});
    std.debug.assert(!std.fs.path.isAbsolute(path)); // use relative path

    const package_entry = store.packages.getEntry(package).?;

    // Import cycle detection
    if (package_entry.value_ptr.loading.contains(path)) return error.ImportCycle;
    try package_entry.value_ptr.loading.put(store.allocator, path, {});
    defer _ = package_entry.value_ptr.loading.remove(path);

    const path_duped = try store.allocator.dupe(u8, path);

    const concat_path = try std.fs.path.join(store.allocator, &.{ store.root_path, path });
    defer store.allocator.free(concat_path);

    var file = try std.fs.openFileAbsolute(concat_path, .{});
    defer file.close();

    const text = try file.readToEndAllocOptions(
        store.allocator,
        std.math.maxInt(usize),
        null,
        .of(u8),
        0,
    );
    errdefer store.allocator.free(text);

    var tree = try std.zig.Ast.parse(store.allocator, text, .zig);
    errdefer tree.deinit(store.allocator);

    var handle = try store.allocator.create(Handle);
    errdefer store.allocator.destroy(handle);

    // Build line index for O(log n) position lookups
    const line_index = try offsets.LineIndex.build(store.allocator, text);

    // Pre-scan for @import nodes
    var import_nodes = std.ArrayListUnmanaged(std.zig.Ast.Node.Index){};
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                const node_i: std.zig.Ast.Node.Index = @enumFromInt(i);
                if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node_i)), "@import")) {
                    try import_nodes.append(store.allocator, node_i);
                }
            },
            else => {},
        }
    }

    handle.* = .{
        .document_store = store,
        .package = package_entry.key_ptr.*,
        .path = path_duped,
        .text = text,
        .tree = tree,
        .analyzer = .{ .allocator = store.allocator, .handle = handle },
        .import_nodes = import_nodes,
        .line_index = line_index,
    };

    try store.packages.getEntry(package).?.value_ptr.handles.put(store.allocator, path_duped, handle);

    try handle.analyzer.init();

    return handle;
}

pub fn getOrLoadFile(store: *DocumentStore, package: []const u8, path: []const u8) anyerror!*Handle {
    return store.packages.get(package).?.handles.get(path) orelse store.loadFile(package, path);
}

pub fn resolveImportHandle(store: *DocumentStore, handle: *Handle, import: []const u8) anyerror!?*Handle {
    if (std.mem.endsWith(u8, import, ".zig")) {
        const root_dir = std.fs.path.dirname(store.packages.get(handle.package).?.root) orelse return error.InvalidPackageRoot;
        var rel = try std.fs.path.resolve(store.allocator, &[_][]const u8{ root_dir, handle.path, "..", import });
        defer store.allocator.free(rel);

        return try store.getOrLoadFile(handle.package, rel[root_dir.len + 1 ..]);
    } else {
        const pkg = store.packages.get(import) orelse return null;
        return pkg.handles.get(pkg.root_relative);
    }
}
