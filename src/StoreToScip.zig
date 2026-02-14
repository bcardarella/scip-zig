const std = @import("std");
const scip = @import("scip.zig");
const DocumentStore = @import("analysis/DocumentStore.zig");

pub fn storeToScip(allocator: std.mem.Allocator, store: *DocumentStore, pkg: []const u8) !std.ArrayListUnmanaged(scip.Document) {
    var documents = std.ArrayListUnmanaged(scip.Document){};

    var docit = store.packages.get(pkg).?.handles.iterator();
    while (docit.next()) |entry| {
        const handle = entry.value_ptr.*;
        const document = try documents.addOne(allocator);

        document.* = .{
            .language = "zig",
            .relative_path = try std.mem.replaceOwned(u8, allocator, entry.key_ptr.*, "\\", "/"),
            .occurrences = handle.analyzer.occurrences,
            .symbols = handle.analyzer.symbols,
            .position_encoding = .utf8_code_unit_offset_from_line_start,
        };
    }

    // Sort occurrences and symbols within each document for deterministic output
    for (documents.items) |*doc| {
        std.mem.sort(scip.Occurrence, doc.occurrences.items, {}, struct {
            fn lessThan(_: void, a: scip.Occurrence, b: scip.Occurrence) bool {
                const a_items = a.range.items;
                const b_items = b.range.items;
                const min_len = @min(a_items.len, b_items.len);
                for (a_items[0..min_len], b_items[0..min_len]) |ai, bi| {
                    if (ai != bi) return ai < bi;
                }
                return a_items.len < b_items.len;
            }
        }.lessThan);

        std.mem.sort(scip.SymbolInformation, doc.symbols.items, {}, struct {
            fn lessThan(_: void, a: scip.SymbolInformation, b: scip.SymbolInformation) bool {
                return std.mem.order(u8, a.symbol, b.symbol) == .lt;
            }
        }.lessThan);
    }

    // Sort documents by relative_path for deterministic output
    std.mem.sort(scip.Document, documents.items, {}, struct {
        fn lessThan(_: void, a: scip.Document, b: scip.Document) bool {
            return std.mem.order(u8, a.relative_path, b.relative_path) == .lt;
        }
    }.lessThan);

    return documents;
}

/// Collect symbols referenced from occurrences that are not defined in the
/// current package. Returns a deduplicated list of external SymbolInformation.
/// When `store` is provided, enriches external symbols with kind, documentation,
/// and display_name from source packages when available.
pub fn collectExternalSymbols(
    allocator: std.mem.Allocator,
    documents: std.ArrayListUnmanaged(scip.Document),
    pkg: []const u8,
    store: ?*DocumentStore,
) !std.ArrayListUnmanaged(scip.SymbolInformation) {
    const pkg_prefix = try std.fmt.allocPrint(allocator, "file . {s} ", .{pkg});
    defer allocator.free(pkg_prefix);

    // Build a symbol -> SymbolInformation lookup from all packages
    var symbol_lookup = std.StringHashMapUnmanaged(scip.SymbolInformation){};
    defer symbol_lookup.deinit(allocator);
    if (store) |s| {
        var pkg_it = s.packages.iterator();
        while (pkg_it.next()) |pkg_entry| {
            var handle_it = pkg_entry.value_ptr.handles.iterator();
            while (handle_it.next()) |handle_entry| {
                const handle = handle_entry.value_ptr.*;
                for (handle.analyzer.symbols.items) |sym_info| {
                    if (sym_info.symbol.len == 0) continue;
                    if (!symbol_lookup.contains(sym_info.symbol)) {
                        try symbol_lookup.put(allocator, sym_info.symbol, sym_info);
                    }
                }
            }
        }
    }

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);
    var external_symbols = std.ArrayListUnmanaged(scip.SymbolInformation){};

    for (documents.items) |doc| {
        for (doc.occurrences.items) |occ| {
            const sym = occ.symbol;
            if (sym.len == 0) continue;
            // Skip local symbols and symbols belonging to the current package
            if (std.mem.startsWith(u8, sym, "local ")) continue;
            if (std.mem.startsWith(u8, sym, pkg_prefix)) continue;

            const gop = try seen.getOrPut(allocator, sym);
            if (!gop.found_existing) {
                if (symbol_lookup.get(sym)) |src_info| {
                    try external_symbols.append(allocator, .{
                        .symbol = sym,
                        .documentation = src_info.documentation,
                        .relationships = .{},
                        .kind = src_info.kind,
                        .display_name = src_info.display_name,
                    });
                } else {
                    try external_symbols.append(allocator, .{
                        .symbol = sym,
                        .documentation = .{},
                        .relationships = .{},
                    });
                }
            }
        }
    }

    return external_symbols;
}

test "collectExternalSymbols filters and deduplicates" {
    // Use arena since collectExternalSymbols internally allocates pkg_prefix and seen hashmap
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a fake document with mixed occurrence symbols
    var occs = std.ArrayListUnmanaged(scip.Occurrence){};
    // Local symbol — should be excluded
    try occs.append(allocator, .{
        .range = .{},
        .symbol = "local 1",
        .symbol_roles = 0,
        .override_documentation = .{},
        .syntax_kind = .identifier,
        .diagnostics = .{},
    });
    // Same-package symbol — should be excluded
    try occs.append(allocator, .{
        .range = .{},
        .symbol = "file . mypkg `main.zig`/myFunc().",
        .symbol_roles = 0,
        .override_documentation = .{},
        .syntax_kind = .identifier,
        .diagnostics = .{},
    });
    // External symbol — should be included
    try occs.append(allocator, .{
        .range = .{},
        .symbol = "file . std `mem.zig`/eql().",
        .symbol_roles = 0,
        .override_documentation = .{},
        .syntax_kind = .identifier,
        .diagnostics = .{},
    });
    // Same external symbol again — should be deduplicated
    try occs.append(allocator, .{
        .range = .{},
        .symbol = "file . std `mem.zig`/eql().",
        .symbol_roles = 0,
        .override_documentation = .{},
        .syntax_kind = .identifier,
        .diagnostics = .{},
    });
    // Another external symbol
    try occs.append(allocator, .{
        .range = .{},
        .symbol = "file . other `lib.zig`/Thing#",
        .symbol_roles = 0,
        .override_documentation = .{},
        .syntax_kind = .identifier,
        .diagnostics = .{},
    });
    // Empty symbol — should be excluded
    try occs.append(allocator, .{
        .range = .{},
        .symbol = "",
        .symbol_roles = 0,
        .override_documentation = .{},
        .syntax_kind = .identifier,
        .diagnostics = .{},
    });

    var docs = std.ArrayListUnmanaged(scip.Document){};
    try docs.append(allocator, .{
        .language = "zig",
        .relative_path = "main.zig",
        .occurrences = occs,
        .symbols = .{},
    });

    const result = try collectExternalSymbols(allocator, docs, "mypkg", null);

    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("file . std `mem.zig`/eql().", result.items[0].symbol);
    try std.testing.expectEqualStrings("file . other `lib.zig`/Thing#", result.items[1].symbol);
}
