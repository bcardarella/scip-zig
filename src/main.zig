const std = @import("std");
const scip = @import("scip.zig");
const protobruh = @import("protobruh.zig");
const StoreToScip = @import("StoreToScip.zig");
const DocumentStore = @import("analysis/DocumentStore.zig");
const utils = @import("analysis/utils.zig");

const ArgState = enum {
    none,
    add_package_name,
    add_package_path,
    root_name,
    root_path,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var doc_store = DocumentStore{
        .allocator = allocator,
        .root_path = "",
    };
    defer doc_store.deinit();

    var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;

    var root_path: []const u8 = try std.posix.getcwd(&cwd_buf);
    var root_name: ?[]const u8 = null;
    var package_name: ?[]const u8 = null;
    var root_path_set: bool = false;

    var arg_state: ArgState = .none;
    var arg_iterator = try std.process.ArgIterator.initWithAllocator(allocator);
    defer arg_iterator.deinit();

    // Save arguments during first pass for tool_info
    var saved_args = std.ArrayListUnmanaged([]const u8){};
    defer saved_args.deinit(allocator);

    doc_store.root_path = root_path;

    while (arg_iterator.next()) |arg| {
        try saved_args.append(allocator, arg);
        switch (arg_state) {
            .none => {
                if (std.mem.eql(u8, arg, "--pkg")) arg_state = .add_package_name;
                if (std.mem.eql(u8, arg, "--root-pkg")) arg_state = .root_name;
                if (std.mem.eql(u8, arg, "--root-path")) arg_state = .root_path;
            },
            .add_package_name => {
                package_name = arg;
                arg_state = .add_package_path;
            },
            .add_package_path => {
                try doc_store.createPackage(package_name.?, arg);
                arg_state = .none;
            },
            .root_name => {
                if (root_name != null) std.log.err("Multiple roots detected; this invocation may not behave as expected!", .{});
                root_name = arg;
                arg_state = .none;
            },
            .root_path => {
                if (root_path_set) std.log.err("Multiple root paths detected; this invocation may not behave as expected!", .{});
                root_path_set = true;
                root_path = arg;
                doc_store.root_path = root_path;
                arg_state = .none;
            },
        }
    }

    // Validate that arg parsing completed cleanly
    switch (arg_state) {
        .none => {},
        .add_package_name => {
            std.log.err("--pkg requires <name> <path> arguments", .{});
            return;
        },
        .add_package_path => {
            std.log.err("--pkg requires a path after the package name", .{});
            return;
        },
        .root_name => {
            std.log.err("--root-pkg requires a package name argument", .{});
            return;
        },
        .root_path => {
            std.log.err("--root-path requires a path argument", .{});
            return;
        },
    }

    if (root_name == null) {
        std.log.err("Please specify a root package name with --root-pkg!", .{});
        return;
    }

    // Run postResolves on all packages
    var pkg_it = doc_store.packages.iterator();
    while (pkg_it.next()) |pkg_entry| {
        var handle_it = pkg_entry.value_ptr.handles.iterator();
        while (handle_it.next()) |h| {
            try h.value_ptr.*.analyzer.postResolves();
        }
    }

    var index = try std.fs.cwd().createFile("index.scip", .{});
    defer index.close();

    var documents = try StoreToScip.storeToScip(allocator, &doc_store, root_name.?);
    defer {
        for (documents.items) |*doc| {
            allocator.free(doc.relative_path);
        }
        documents.deinit(allocator);
    }
    var external_symbols = try StoreToScip.collectExternalSymbols(allocator, documents, root_name.?, &doc_store);
    defer external_symbols.deinit(allocator);

    var write_buf: [4096]u8 = undefined;
    var file_writer = index.writer(&write_buf);

    const project_root = try utils.fromPath(allocator, root_path);
    defer allocator.free(project_root);
    std.log.info("Using project root {s}", .{project_root});

    try protobruh.encode(scip.Index{
        .metadata = .{
            // unspecified_protocol_version (0) is the only defined value per the SCIP proto spec
            .version = .unspecified_protocol_version,
            .tool_info = .{
                .name = "scip-zig",
                .version = "unversioned",
                .arguments = saved_args,
            },
            .project_root = project_root,
            .text_document_encoding = .utf8,
        },
        .documents = documents,
        .external_symbols = external_symbols,
    }, &file_writer.interface);

    try file_writer.interface.flush();
}

test {
    _ = @import("protobruh.zig");
    _ = @import("StoreToScip.zig");
    _ = @import("analysis/Analyzer.zig");
}
