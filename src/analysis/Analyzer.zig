const std = @import("std");
const zig = std.zig;
const Ast = zig.Ast;
const scip = @import("../scip.zig");
const utils = @import("utils.zig");
const offsets = @import("offsets.zig");
const DocumentStore = @import("DocumentStore.zig");

const logger = std.log.scoped(.analyzer);

const Analyzer = @This();

allocator: std.mem.Allocator,
handle: *DocumentStore.Handle,
scopes: std.ArrayListUnmanaged(Scope) = .{},

/// Occurrences recorded at occurrence site
recorded_occurrences: std.AutoHashMapUnmanaged(Ast.TokenIndex, void) = .{},
/// Tokens that are write targets (LHS of assignments)
write_tokens: std.AutoHashMapUnmanaged(Ast.TokenIndex, void) = .{},

symbols: std.ArrayListUnmanaged(scip.SymbolInformation) = .{},
occurrences: std.ArrayListUnmanaged(scip.Occurrence) = .{},

local_counter: usize = 0,

post_resolves: std.ArrayListUnmanaged(PostResolve) = .{},

/// Maps node indices to scope indices for O(1) lookup
scope_map: std.AutoHashMapUnmanaged(Ast.Node.Index, usize) = .{},

/// Tracks all allocated symbol strings for cleanup
allocated_symbols: std.ArrayListUnmanaged([]const u8) = .{},

const PostResolve = struct { scope_idx: usize, node_idx: Ast.Node.Index };

pub fn init(analyzer: *Analyzer) !void {
    logger.info("Initializing file {s}", .{analyzer.handle.path});
    try analyzer.newContainerScope(null, .root, "root");
}

pub fn deinit(analyzer: *Analyzer) void {
    for (analyzer.allocated_symbols.items) |sym| {
        analyzer.allocator.free(sym);
    }
    analyzer.allocated_symbols.deinit(analyzer.allocator);
    for (analyzer.scopes.items) |*scope| {
        scope.deinit(analyzer.allocator);
    }
    analyzer.scopes.deinit(analyzer.allocator);
    analyzer.recorded_occurrences.deinit(analyzer.allocator);
    analyzer.write_tokens.deinit(analyzer.allocator);
    for (analyzer.symbols.items) |*sym| {
        sym.documentation.deinit(analyzer.allocator);
        sym.relationships.deinit(analyzer.allocator);
    }
    analyzer.symbols.deinit(analyzer.allocator);
    for (analyzer.occurrences.items) |*occ| {
        occ.range.deinit(analyzer.allocator);
        occ.enclosing_range.deinit(analyzer.allocator);
    }
    analyzer.occurrences.deinit(analyzer.allocator);
    analyzer.post_resolves.deinit(analyzer.allocator);
    analyzer.scope_map.deinit(analyzer.allocator);
}

/// Track an allocated symbol string for cleanup in deinit.
fn trackSymbol(analyzer: *Analyzer, symbol: []const u8) ![]const u8 {
    try analyzer.allocated_symbols.append(analyzer.allocator, symbol);
    return symbol;
}

pub const SourceRange = std.zig.Token.Loc;

pub const Scope = struct {
    pub const Data = union(enum) {
        container: struct {
            descriptor: []const u8,
            node_idx: Ast.Node.Index,
            fields: std.StringHashMapUnmanaged(Field) = .{},
        }, // .tag is ContainerDecl or Root or ErrorSetDecl
        function: struct {
            descriptor: []const u8,
            node_idx: Ast.Node.Index,
        }, // .tag is FnProto
        block: Ast.Node.Index, // .tag is Block
        import: []const u8,
    };

    node_idx: zig.Ast.Node.Index,
    parent_scope_idx: ?usize,
    range: SourceRange,
    decls: std.StringHashMapUnmanaged(Declaration) = .{},
    data: Data,

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.decls.deinit(allocator);
        switch (self.data) {
            .container => |*c| c.fields.deinit(allocator),
            else => {},
        }
    }

    pub fn toNodeIndex(self: Scope) ?Ast.Node.Index {
        return switch (self.data) {
            .container => |c| c.node_idx,
            .function => |f| f.node_idx,
            .block => |idx| idx,
            else => null,
        };
    }
};

// pub const ResolveAndMarkResult = struct {
//     analyzer: *Analyzer,
//     scope_idx: usize,
//     declaration: ?Declaration = null,
// };

pub const TrueScopeIndexResult = struct {
    /// Analyzer where scope is located
    analyzer: *Analyzer,
    /// Scope
    scope_idx: usize,
};

pub fn resolveTrueScopeIndex(
    analyzer: *Analyzer,
    scope_idx: usize,
) !?TrueScopeIndexResult {
    const scope = analyzer.scopes.items[scope_idx];
    return switch (scope.data) {
        .import => |i| TrueScopeIndexResult{
            // NOTE: This really seems dangerous... but it works so like can't complain (yet)
            .analyzer = &((try analyzer.handle.document_store.resolveImportHandle(analyzer.handle, i)) orelse return null).analyzer,
            .scope_idx = 0,
        },
        else => TrueScopeIndexResult{ .analyzer = analyzer, .scope_idx = scope_idx },
    };
}

pub const DeclarationWithAnalyzer = struct {
    analyzer: *Analyzer,
    declaration: ?Declaration = null,
    scope_idx: usize,
};

pub fn getDeclFromScopeByName(
    analyzer: *Analyzer,
    scope_idx: usize,
    name: []const u8,
) !DeclarationWithAnalyzer {
    var ts = (try analyzer.resolveTrueScopeIndex(scope_idx)) orelse return DeclarationWithAnalyzer{ .analyzer = analyzer, .scope_idx = scope_idx };
    if (ts.analyzer.scopes.items.len == 0) return DeclarationWithAnalyzer{ .analyzer = ts.analyzer, .scope_idx = ts.scope_idx };
    return DeclarationWithAnalyzer{
        .analyzer = ts.analyzer,
        .declaration = ts.analyzer.scopes.items[ts.scope_idx].decls.get(name),
        .scope_idx = ts.scope_idx,
    };
}

pub fn formatSubSymbol(analyzer: *Analyzer, symbol: []const u8) []const u8 {
    _ = analyzer;
    return if (std.mem.startsWith(u8, symbol, "@\"")) symbol[2 .. symbol.len - 1] else symbol;
}

pub fn resolveAndMarkDeclarationIdentifier(
    analyzer: *Analyzer,
    foreign_analyzer: *Analyzer,
    scope_idx: usize,
    token_idx: Ast.TokenIndex,
) anyerror!DeclarationWithAnalyzer {
    const tree = analyzer.handle.tree;
    // const scope = analyzer.scopes.items[scope_idx];

    var dwa = try foreign_analyzer.getDeclFromScopeByName(scope_idx, tree.tokenSlice(token_idx));
    if (dwa.declaration == null)
        dwa =
            if (dwa.scope_idx >= foreign_analyzer.scopes.items.len)
            return DeclarationWithAnalyzer{ .analyzer = foreign_analyzer, .scope_idx = scope_idx }
        else r: {
            const maybe_rtsi = try foreign_analyzer.resolveTrueScopeIndex(scope_idx);
            if (maybe_rtsi) |rtsi| {
                if (rtsi.scope_idx < rtsi.analyzer.scopes.items.len) {
                    if (rtsi.analyzer.scopes.items[rtsi.scope_idx].parent_scope_idx) |psi| {
                        break :r try analyzer.resolveAndMarkDeclarationIdentifier(rtsi.analyzer, psi, token_idx);
                    }
                }
            }

            return DeclarationWithAnalyzer{ .analyzer = foreign_analyzer, .scope_idx = if (maybe_rtsi) |m| m.scope_idx else 0 };
        };

    if (dwa.declaration) |decl| {
        if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, token_idx, {})) == null) {
            const ref_syntax_kind: scip.SyntaxKind = switch (decl.data) {
                .function => .identifier_function,
                .variable => |v| blk: {
                    // Check if the variable is a container type, import, constant, or local
                    if (v.ast.init_node.unwrap()) |init_node| {
                        if (utils.isContainer(dwa.analyzer.handle.tree, init_node))
                            break :blk .identifier_type;
                        if (utils.isBuiltinCall(dwa.analyzer.handle.tree, init_node) and
                            std.mem.eql(u8, dwa.analyzer.handle.tree.tokenSlice(dwa.analyzer.handle.tree.nodeMainToken(init_node)), "@import"))
                            break :blk .identifier_namespace;
                    }
                    // Check mut_token to distinguish const vs var
                    if (dwa.analyzer.handle.tree.tokenSlice(v.ast.mut_token)[0] == 'c')
                        break :blk .identifier_constant;
                    // Check if the declaration is in a block scope (local) or container (mutable global)
                    if (dwa.scope_idx < dwa.analyzer.scopes.items.len) {
                        const decl_scope = dwa.analyzer.scopes.items[dwa.scope_idx];
                        break :blk switch (decl_scope.data) {
                            .block => .identifier_local,
                            .container => .identifier_mutable_global,
                            else => .identifier,
                        };
                    }
                    break :blk .identifier;
                },
                .param => .identifier_parameter,
                .none => .identifier,
            };

            const role: i32 = if (analyzer.write_tokens.contains(token_idx))
                @intFromEnum(scip.SymbolRole.write_access)
            else
                @intFromEnum(scip.SymbolRole.read_access);

            try analyzer.occurrences.append(analyzer.allocator, .{
                .range = try analyzer.rangeArray(token_idx),
                .symbol = decl.symbol,
                .symbol_roles = role,
                .override_documentation = .{},
                .syntax_kind = ref_syntax_kind,
                .diagnostics = .{},
            });
        }
    }

    return dwa;
}

pub fn resolveAndMarkDeclarationComplex(
    analyzer: *Analyzer,
    foreign_analyzer: *Analyzer,
    scope_idx: usize,
    node_idx: Ast.Node.Index,
) anyerror!DeclarationWithAnalyzer {
    const tree = analyzer.handle.tree;

    if (@intFromEnum(node_idx) >= tree.nodes.len) std.log.err("BRUH {d}", .{@intFromEnum(node_idx)});
    return switch (tree.nodeTag(node_idx)) {
        .identifier => analyzer.resolveAndMarkDeclarationIdentifier(foreign_analyzer, scope_idx, tree.nodeMainToken(node_idx)),
        .field_access => {
            const curr_name_idx: Ast.TokenIndex = utils.nodeDataRhsRaw(tree, node_idx);
            const prev_node_idx = utils.nodeDataLhs(tree, node_idx);

            // const scope_decl = () orelse return .{ .analyzer = analyzer };
            var result = try analyzer.resolveAndMarkDeclarationComplex(foreign_analyzer, scope_idx, prev_node_idx);
            if (result.declaration) |decl|
                switch (result.analyzer.handle.tree.nodeTag(decl.node_idx)) {
                    .global_var_decl,
                    .local_var_decl,
                    .aligned_var_decl,
                    .simple_var_decl,
                    => {
                        const var_decl = utils.varDecl(result.analyzer.handle.tree, decl.node_idx).?;

                        if (var_decl.ast.init_node.unwrap()) |init_node| {
                            switch (result.analyzer.handle.tree.nodeTag(init_node)) {
                                .identifier, .field_access => {
                                    result = try result.analyzer.resolveAndMarkDeclarationComplex(result.analyzer, result.scope_idx, init_node);
                                },
                                // Follow @import() to resolve imported scopes
                                .builtin_call,
                                .builtin_call_comma,
                                .builtin_call_two,
                                .builtin_call_two_comma,
                                => {
                                    if (result.analyzer.scope_map.get(init_node)) |idx| {
                                        const maybe_decl = try analyzer.resolveAndMarkDeclarationIdentifier(result.analyzer, idx, curr_name_idx);
                                        if (maybe_decl.declaration != null) return maybe_decl;
                                    }
                                },
                                // Follow function call return types: e.g. Type.init()
                                .call,
                                .call_comma,
                                .call_one,
                                .call_one_comma,
                                => {
                                    var buf: [1]Ast.Node.Index = undefined;
                                    if (utils.callFull(result.analyzer.handle.tree, init_node, &buf)) |call| {
                                        result = try result.analyzer.resolveAndMarkDeclarationComplex(result.analyzer, result.scope_idx, call.ast.fn_expr);
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                };
            if (result.declaration) |scope_decl| {
                if (scope_decl.data == .variable) {
                    if (scope_decl.data.variable.ast.init_node.unwrap()) |init_node| {
                        if (result.analyzer.scope_map.get(init_node)) |idx| {
                            const maybe_decl = try analyzer.resolveAndMarkDeclarationIdentifier(result.analyzer, idx, curr_name_idx);
                            if (maybe_decl.declaration == null) logger.warn("Lookup failure while searching for {s} from {s}", .{ tree.getNodeSource(node_idx), analyzer.handle.path });
                            return maybe_decl;
                        }
                    }
                }
            }

            return DeclarationWithAnalyzer{ .analyzer = analyzer, .scope_idx = scope_idx };
        },
        else => {
            return DeclarationWithAnalyzer{ .analyzer = analyzer, .scope_idx = scope_idx };
        },
    };
}

pub const Declaration = struct {
    node_idx: Ast.Node.Index,
    symbol: []const u8 = "",
    data: union(enum) {
        none,
        function: Ast.full.FnProto,
        variable: Ast.full.VarDecl,
        param: Ast.full.FnProto.Param,
    },
};

pub const Field = struct {
    node_idx: Ast.Node.Index,
    data: Ast.full.ContainerField,
};

pub fn getDescriptor(analyzer: *Analyzer, maybe_scope_idx: ?usize) ?[]const u8 {
    if (maybe_scope_idx) |scope_idx| {
        if (scope_idx >= analyzer.scopes.items.len) return null;
        const scope = analyzer.scopes.items[scope_idx];
        return switch (scope.data) {
            .container => |container| container.descriptor,
            .function => |function| function.descriptor,
            else => null,
        };
    } else return null;
}

pub fn rangeArray(analyzer: *Analyzer, token: zig.Ast.TokenIndex) !std.ArrayListUnmanaged(i32) {
    const range_orig = offsets.tokenToRangeIndexed(analyzer.handle.tree, token, analyzer.handle.line_index);
    return rangeToArray(analyzer, range_orig);
}

pub fn nodeRangeArray(analyzer: *Analyzer, node_idx: zig.Ast.Node.Index) !std.ArrayListUnmanaged(i32) {
    const range_orig = offsets.nodeToRangeIndexed(analyzer.handle.tree, node_idx, analyzer.handle.line_index);
    return rangeToArray(analyzer, range_orig);
}

fn rangeToArray(analyzer: *Analyzer, range_orig: offsets.Range) !std.ArrayListUnmanaged(i32) {
    const start_line: i32 = @intCast(range_orig.start.line);
    const end_line: i32 = @intCast(range_orig.end.line);
    const single_line = start_line == end_line;
    const cap: usize = if (single_line) 3 else 4;
    var list = std.ArrayListUnmanaged(i32){};
    try list.ensureTotalCapacity(analyzer.allocator, cap);
    list.appendAssumeCapacity(start_line);
    list.appendAssumeCapacity(@intCast(range_orig.start.character));
    if (!single_line) list.appendAssumeCapacity(end_line);
    list.appendAssumeCapacity(@intCast(range_orig.end.character));
    return list;
}

/// Walks up the scope chain to find the nearest enclosing container or function descriptor.
fn getEnclosingSymbol(analyzer: *Analyzer, scope_idx: usize) []const u8 {
    var idx: ?usize = analyzer.scopes.items[scope_idx].parent_scope_idx;
    while (idx) |i| {
        const scope = analyzer.scopes.items[i];
        switch (scope.data) {
            .container => |c| return c.descriptor,
            .function => |f| return f.descriptor,
            else => {},
        }
        idx = scope.parent_scope_idx;
    }
    return "";
}

/// Extracts a signature text from source for a declaration node.
fn getSignatureText(analyzer: *Analyzer, node_idx: zig.Ast.Node.Index) ?[]const u8 {
    const tree = analyzer.handle.tree;
    const tag = tree.nodeTag(node_idx);
    switch (tag) {
        .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi, .fn_decl => {
            var buf: [1]Ast.Node.Index = undefined;
            const func = utils.fnProto(tree, node_idx, &buf) orelse return null;
            // From `fn` keyword through return type (excluding body)
            const fn_token = tree.nodeMainToken(node_idx);
            const start = tree.tokens.items(.start)[fn_token];
            // End at the return type node's last token
            if (func.ast.return_type.unwrap()) |ret_node| {
                const end_token = tree.lastToken(ret_node);
                const end_loc = utils.tokenLocation(tree, end_token);
                if (end_loc.end > start) {
                    return tree.source[start..end_loc.end];
                }
            }
            // Fallback: use name token through params
            if (func.name_token) |name_tok| {
                const name_start = tree.tokens.items(.start)[name_tok];
                _ = name_start;
                // Just use the fn keyword + name
                const name_loc = utils.tokenLocation(tree, fn_token);
                return tree.source[start..name_loc.end];
            }
            return null;
        },
        .global_var_decl, .local_var_decl, .aligned_var_decl, .simple_var_decl => {
            const var_decl = utils.varDecl(tree, node_idx) orelse return null;
            const mut_token = var_decl.ast.mut_token;
            const start = tree.tokens.items(.start)[mut_token];
            // If there's a type annotation, include through type node
            if (var_decl.ast.type_node.unwrap()) |type_node| {
                const end_token = tree.lastToken(type_node);
                const end_loc = utils.tokenLocation(tree, end_token);
                if (end_loc.end > start) {
                    return tree.source[start..end_loc.end];
                }
            }
            // Otherwise just const/var + name
            const name_token = mut_token + 1;
            const end_loc = utils.tokenLocation(tree, name_token);
            if (end_loc.end > start) {
                return tree.source[start..end_loc.end];
            }
            return null;
        },
        else => return null,
    }
}

pub fn addSymbol(
    analyzer: *Analyzer,
    scope_idx: usize,
    node_idx: zig.Ast.Node.Index,
    symbol_name: []const u8,
    syntax_kind: scip.SyntaxKind,
    symbol_kind: scip.SymbolInformation.SymbolKind,
) !void {
    const tree = analyzer.handle.tree;
    const name_token = utils.getDeclNameToken(tree, node_idx) orelse {
        logger.warn("Cannot find decl name token for symbol {s}", .{symbol_name});
        return;
    };

    if (try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, name_token, {})) |_| {
        logger.warn("Encountered reoccuring entry symbol {s} @ token {d}", .{ symbol_name, name_token });
        return;
    }

    const comments = try utils.getDocComments(analyzer.allocator, tree, node_idx);
    const sig_text = analyzer.getSignatureText(node_idx);
    try analyzer.symbols.append(analyzer.allocator, .{
        .symbol = symbol_name,
        .documentation = comments orelse .{},
        .relationships = .{},
        .kind = symbol_kind,
        .display_name = utils.getDeclName(tree, node_idx) orelse "",
        .signature_documentation = if (sig_text) |text| .{ .language = "zig", .text = text } else null,
        .enclosing_symbol = analyzer.getEnclosingSymbol(scope_idx),
    });

    // Definition of a variable or parameter is semantically a write
    const symbol_roles: i32 = if (symbol_kind == .variable or symbol_kind == .parameter or symbol_kind == .constant)
        @intFromEnum(scip.SymbolRole.definition) | @intFromEnum(scip.SymbolRole.write_access)
    else
        @intFromEnum(scip.SymbolRole.definition);

    try analyzer.occurrences.append(analyzer.allocator, .{
        .range = try analyzer.rangeArray(name_token),
        .symbol = symbol_name,
        .symbol_roles = symbol_roles,
        .override_documentation = .{},
        .syntax_kind = syntax_kind,
        .diagnostics = .{},
        .enclosing_range = try analyzer.nodeRangeArray(node_idx),
    });
}

pub fn generateSymbol(
    analyzer: *Analyzer,
    scope_idx: usize,
    declaration: Declaration,
    name: []const u8,
    is_type: bool,
) ![]const u8 {
    const scope = &analyzer.scopes.items[scope_idx];

    return switch (scope.data) {
        .block => switch (declaration.data) {
            .variable => v: {
                analyzer.local_counter += 1;
                break :v try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "local {d}", .{analyzer.local_counter}));
            },
            else => return error.UnexpectedBlockDeclaration,
        },
        .container => switch (declaration.data) {
            .function => try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ scope.data.container.descriptor, "`", analyzer.formatSubSymbol(name), "`", "()." })),
            else => try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ scope.data.container.descriptor, "`", analyzer.formatSubSymbol(name), "`", if (is_type) "#" else "." })),
        },
        else => return error.UnexpectedScopeType,
    };
}

pub fn addDeclaration(
    analyzer: *Analyzer,
    scope_idx: usize,
    declaration: Declaration,
    /// If name is not specified, default will method will be used
    provided_name: ?[]const u8,
) !void {
    const name = provided_name orelse utils.getDeclName(analyzer.handle.tree, declaration.node_idx) orelse {
        logger.warn("Cannot find decl name for declaration at node {d}", .{@intFromEnum(declaration.node_idx)});
        return;
    };
    const scope = &analyzer.scopes.items[scope_idx];

    // Determine syntax_kind and symbol_kind based on declaration type and scope
    const VarInitInfo = struct {
        is_container: bool = false,
        is_import: bool = false,
        container_kind: scip.SymbolInformation.SymbolKind = .unspecified_kind,
    };
    const var_init_info: VarInitInfo = if (declaration.data == .variable) blk: {
        const init_node = declaration.data.variable.ast.init_node.unwrap();
        if (init_node) |inode| {
            const init_tag = analyzer.handle.tree.nodeTag(inode);
            const is_container = switch (init_tag) {
                .container_decl,
                .container_decl_trailing,
                .container_decl_arg,
                .container_decl_arg_trailing,
                .container_decl_two,
                .container_decl_two_trailing,
                .tagged_union,
                .tagged_union_trailing,
                .tagged_union_two,
                .tagged_union_two_trailing,
                .tagged_union_enum_tag,
                .tagged_union_enum_tag_trailing,
                .error_set_decl,
                => true,
                else => false,
            };
            const is_import = utils.isBuiltinCall(analyzer.handle.tree, inode) and std.mem.eql(u8, analyzer.handle.tree.tokenSlice(analyzer.handle.tree.nodeMainToken(inode)), "@import");
            // Determine container symbol kind
            const container_kind: scip.SymbolInformation.SymbolKind = if (is_container) switch (init_tag) {
                .tagged_union,
                .tagged_union_trailing,
                .tagged_union_two,
                .tagged_union_two_trailing,
                .tagged_union_enum_tag,
                .tagged_union_enum_tag_trailing,
                => .@"union",
                .error_set_decl => .@"enum",
                else => ck: {
                    // Check the container main token for struct/enum/union/opaque
                    const container_token = analyzer.handle.tree.tokenSlice(analyzer.handle.tree.nodeMainToken(inode));
                    if (std.mem.eql(u8, container_token, "enum")) break :ck .@"enum";
                    if (std.mem.eql(u8, container_token, "union")) break :ck .@"union";
                    break :ck .@"struct";
                },
            } else .unspecified_kind;
            break :blk VarInitInfo{ .is_container = is_container, .is_import = is_import, .container_kind = container_kind };
        }
        break :blk VarInitInfo{};
    } else VarInitInfo{};

    const syntax_kind: scip.SyntaxKind = switch (declaration.data) {
        .function => .identifier_function_definition,
        .variable => if (var_init_info.is_container)
            .identifier_type
        else if (var_init_info.is_import)
            .identifier_namespace
        else switch (scope.data) {
            .block => .identifier_local,
            .container => if (analyzer.handle.tree.tokenSlice(declaration.data.variable.ast.mut_token)[0] == 'c')
                .identifier_constant
            else
                .identifier_mutable_global,
            else => .identifier,
        },
        .param => .identifier_parameter,
        .none => .identifier,
    };

    const symbol_kind: scip.SymbolInformation.SymbolKind = switch (declaration.data) {
        .function => .function,
        .variable => if (var_init_info.is_container)
            var_init_info.container_kind
        else if (var_init_info.is_import)
            .namespace
        else switch (scope.data) {
            .block => .variable,
            .container => if (analyzer.handle.tree.tokenSlice(declaration.data.variable.ast.mut_token)[0] == 'c')
                .constant
            else
                .variable,
            else => .variable,
        },
        .param => .parameter,
        .none => .unspecified_kind,
    };

    if (try scope.decls.fetchPut(
        analyzer.allocator,
        name,
        declaration,
    )) |_| {
        logger.warn("Duplicate declaration '{s}' in scope, skipping", .{name});
        return;
    } else {
        try analyzer.addSymbol(scope_idx, declaration.node_idx, declaration.symbol, syntax_kind, symbol_kind);
    }
}

pub fn newContainerScope(
    analyzer: *Analyzer,
    maybe_parent_scope_idx: ?usize,
    node_idx: Ast.Node.Index,
    scope_name: ?[]const u8,
) !void {
    const tree = analyzer.handle.tree;

    for (analyzer.handle.import_nodes.items) |node_i| {
        var buffer: [2]Ast.Node.Index = undefined;
        const params = utils.builtinCallParams(tree, node_i, &buffer) orelse continue;

        if (params.len == 0) continue;
        const import_param = params[0];
        if (tree.nodeTag(import_param) != .string_literal) continue;

        const import_str = tree.tokenSlice(tree.nodeMainToken(import_param));
        _ = analyzer.handle.document_store.resolveImportHandle(analyzer.handle, import_str[1 .. import_str.len - 1]) catch |err| {
            if (err == error.ImportCycle) {
                logger.warn("Import cycle detected for {s} in {s}", .{ import_str, analyzer.handle.path });
                continue;
            }
            return err;
        };
    }

    const scope = try analyzer.scopes.addOne(analyzer.allocator);
    scope.* = .{
        .node_idx = node_idx,
        .parent_scope_idx = maybe_parent_scope_idx,
        .range = nodeSourceRange(tree, node_idx),
        .data = .{
            .container = .{
                .descriptor = if (node_idx == .root)
                    try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "file . {s} unversioned {f}", .{ analyzer.handle.package, analyzer.handle.formatter() }))
                else
                    (if (analyzer.getDescriptor(maybe_parent_scope_idx)) |desc|
                        try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ desc, "`", analyzer.formatSubSymbol(scope_name orelse {
                            logger.warn("Missing container scope name at node {d}", .{@intFromEnum(node_idx)});
                            return;
                        }), "`", "#" }))
                    else
                        try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "file . {s} unversioned ", .{analyzer.handle.package}))),
                .node_idx = node_idx,
            },
        },
    };

    const scope_idx = analyzer.scopes.items.len - 1;
    try analyzer.scope_map.put(analyzer.allocator, node_idx, scope_idx);

    // Handle error_set_decl members via token iteration
    if (tree.nodeTag(node_idx) == .error_set_decl) {
        const data = utils.rawPair(tree, node_idx);
        const lbrace: Ast.TokenIndex = data[0];
        const rbrace: Ast.TokenIndex = data[1];
        const token_tags = tree.tokens.items(.tag);
        const descriptor = analyzer.scopes.items[scope_idx].data.container.descriptor;

        var tok = lbrace + 1;
        while (tok < rbrace) : (tok += 1) {
            if (token_tags[tok] == .identifier) {
                const err_name = tree.tokenSlice(tok);
                const err_symbol = try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ descriptor, analyzer.formatSubSymbol(err_name), "." }));

                if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, tok, {})) == null) {
                    // Collect doc comments before this error member
                    const err_docs: std.ArrayListUnmanaged([]const u8) = if (tok > 0) blk: {
                        var doc_end = tok - 1;
                        // Skip commas
                        if (token_tags[doc_end] == .comma and doc_end > 0) doc_end -= 1;
                        // Check if there are doc comments
                        if (token_tags[doc_end] == .doc_comment) {
                            var doc_start = doc_end;
                            while (doc_start > 0 and token_tags[doc_start - 1] == .doc_comment) doc_start -= 1;
                            var lines = std.ArrayListUnmanaged([]const u8){};
                            var di = doc_start;
                            while (di <= doc_end) : (di += 1) {
                                try lines.append(analyzer.allocator, std.mem.trim(u8, tree.tokenSlice(di)[3..], &std.ascii.whitespace));
                            }
                            break :blk lines;
                        }
                        break :blk .{};
                    } else .{};
                    try analyzer.symbols.append(analyzer.allocator, .{
                        .symbol = err_symbol,
                        .documentation = err_docs,
                        .relationships = .{},
                        .kind = .enum_member,
                        .display_name = err_name,
                        .enclosing_symbol = analyzer.getEnclosingSymbol(scope_idx),
                    });
                    try analyzer.occurrences.append(analyzer.allocator, .{
                        .range = try analyzer.rangeArray(tok),
                        .symbol = err_symbol,
                        .symbol_roles = 0x1,
                        .override_documentation = .{},
                        .syntax_kind = .identifier_constant,
                        .diagnostics = .{},
                        .enclosing_range = try analyzer.nodeRangeArray(node_idx),
                    });
                }
            }
        }
        return;
    }

    var buffer: [2]Ast.Node.Index = undefined;
    const members = utils.declMembers(tree, node_idx, &buffer);

    for (members) |member| {
        const name = utils.getDeclName(tree, member) orelse continue;

        const maybe_container_field: ?zig.Ast.full.ContainerField = switch (tree.nodeTag(member)) {
            .container_field => tree.containerField(member),
            .container_field_align => tree.containerFieldAlign(member),
            .container_field_init => tree.containerFieldInit(member),
            else => null,
        };

        if (maybe_container_field) |container_field| {
            const field = Field{
                .node_idx = member,
                .data = container_field,
            };

            if (try analyzer.scopes.items[scope_idx].data.container.fields.fetchPut(
                analyzer.allocator,
                name,
                field,
            )) |curr| {
                std.log.info("Duplicate field, handling regardless: {any}", .{curr});
            } else {
                try analyzer.addSymbol(scope_idx, member, try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ analyzer.scopes.items[scope_idx].data.container.descriptor, analyzer.formatSubSymbol(name), "." })), .identifier, .field);
            }
        } else {
            try analyzer.scopeIntermediate(scope_idx, member, name);
        }
    }
}

pub fn postResolves(analyzer: *Analyzer) !void {
    for (analyzer.post_resolves.items) |pr| {
        _ = try analyzer.resolveAndMarkDeclarationComplex(analyzer, pr.scope_idx, pr.node_idx);
    }

    const tree = analyzer.handle.tree;

    // Pass 1: Resolve is_type_definition relationships for variables with explicit type annotations
    for (analyzer.scopes.items, 0..) |scope, si| {
        var decl_it = scope.decls.iterator();
        while (decl_it.next()) |entry| {
            const decl = entry.value_ptr.*;
            if (decl.data != .variable) continue;
            const type_node = decl.data.variable.ast.type_node.unwrap() orelse continue;
            const inner = extractInnerTypeIdentifier(tree, type_node) orelse continue;
            const type_token = tree.nodeMainToken(inner);
            const type_name = tree.tokenSlice(type_token);
            const type_dwa = try analyzer.getDeclFromScopeByName(si, type_name);
            if (type_dwa.declaration) |type_decl| {
                if (type_decl.symbol.len > 0) {
                    try analyzer.addTypeRelationship(decl.symbol, type_decl.symbol);
                }
            }
        }
    }

    // Pass 2: Inferred typing — resolve init_node when type_node is absent
    for (analyzer.scopes.items, 0..) |scope, si| {
        var decl_it = scope.decls.iterator();
        while (decl_it.next()) |entry| {
            const decl = entry.value_ptr.*;
            if (decl.data != .variable) continue;
            if (decl.data.variable.ast.type_node.unwrap() != null) continue; // already handled in pass 1
            const init_node = decl.data.variable.ast.init_node.unwrap() orelse continue;

            // Unwrap try/orelse/comptime/nosuspend to get the actual expression
            const expr = unwrapTryOrelse(tree, init_node);

            switch (tree.nodeTag(expr)) {
                // Case 3: type alias or imported type (identifier/field_access)
                .identifier, .field_access => {
                    const resolved = try analyzer.resolveAndMarkDeclarationComplex(analyzer, si, expr);
                    if (resolved.declaration) |res_decl| {
                        if (res_decl.data == .variable) {
                            if (res_decl.data.variable.ast.init_node.unwrap()) |res_init| {
                                if (utils.isContainer(resolved.analyzer.handle.tree, res_init)) {
                                    if (resolved.analyzer.scope_map.get(res_init)) |container_scope_idx| {
                                        const container_scope = resolved.analyzer.scopes.items[container_scope_idx];
                                        if (container_scope.data == .container) {
                                            const desc = container_scope.data.container.descriptor;
                                            if (desc.len > 0) try analyzer.addTypeRelationship(decl.symbol, desc);
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                // Case 4: function call return type
                .call, .call_comma, .call_one, .call_one_comma => {
                    var buf: [1]Ast.Node.Index = undefined;
                    if (utils.callFull(tree, expr, &buf)) |call| {
                        const fn_dwa = try analyzer.resolveAndMarkDeclarationComplex(analyzer, si, call.ast.fn_expr);
                        if (fn_dwa.declaration) |fn_decl| {
                            if (fn_decl.data == .function) {
                                if (fn_decl.data.function.ast.return_type.unwrap()) |ret_node| {
                                    const inner = extractInnerTypeIdentifier(fn_dwa.analyzer.handle.tree, ret_node) orelse continue;
                                    const ret_token = fn_dwa.analyzer.handle.tree.nodeMainToken(inner);
                                    const ret_name = fn_dwa.analyzer.handle.tree.tokenSlice(ret_token);
                                    // Look up the return type name in the function's scope
                                    const ret_dwa = try fn_dwa.analyzer.getDeclFromScopeByName(fn_dwa.scope_idx, ret_name);
                                    if (ret_dwa.declaration) |ret_decl| {
                                        if (ret_decl.symbol.len > 0) try analyzer.addTypeRelationship(decl.symbol, ret_decl.symbol);
                                    }
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }
}

/// Adds an is_type_definition relationship from a declaration symbol to a type symbol.
fn addTypeRelationship(
    analyzer: *Analyzer,
    decl_symbol: []const u8,
    type_symbol: []const u8,
) !void {
    for (analyzer.symbols.items) |*sym_info| {
        if (std.mem.eql(u8, sym_info.symbol, decl_symbol)) {
            try sym_info.relationships.append(analyzer.allocator, .{
                .symbol = type_symbol,
                .is_reference = false,
                .is_implementation = false,
                .is_type_definition = true,
            });
            break;
        }
    }
}

/// Unwraps `try`, `orelse`, `comptime`, `nosuspend`, and `grouped_expression`
/// wrappers to find the underlying expression node.
fn unwrapTryOrelse(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    var current = node;
    while (true) {
        switch (tree.nodeTag(current)) {
            .@"try", .grouped_expression, .@"nosuspend", .@"comptime" => {
                const inner = utils.nodeDataLhs(tree, current);
                if (!utils.nodePresent(inner)) return current;
                current = inner;
            },
            .@"orelse" => {
                const inner = utils.nodeDataLhs(tree, current);
                if (!utils.nodePresent(inner)) return current;
                current = inner;
            },
            else => return current,
        }
    }
}

/// Recursively unwraps type expression wrappers (optional, pointer, error union,
/// array) to find the inner identifier node for is_type_definition resolution.
fn extractInnerTypeIdentifier(tree: Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    return switch (tree.nodeTag(node)) {
        .identifier => node,
        .optional_type => {
            // ?T — child is lhs
            const child = utils.nodeDataLhs(tree, node);
            if (!utils.nodePresent(child)) return null;
            return extractInnerTypeIdentifier(tree, child);
        },
        .ptr_type, .ptr_type_aligned, .ptr_type_sentinel, .ptr_type_bit_range => {
            // *T, [*]T, []T — use fullPtrType to get child_type
            if (utils.ptrType(tree, node)) |pt| {
                return extractInnerTypeIdentifier(tree, pt.ast.child_type);
            }
            return null;
        },
        .error_union => {
            // E!T — rhs is the payload type
            const rhs = utils.nodeDataRhs(tree, node);
            if (!utils.nodePresent(rhs)) return null;
            return extractInnerTypeIdentifier(tree, rhs);
        },
        .array_type => {
            // [N]T — rhs is elem_type
            const rhs = utils.nodeDataRhs(tree, node);
            if (!utils.nodePresent(rhs)) return null;
            return extractInnerTypeIdentifier(tree, rhs);
        },
        .array_type_sentinel => {
            // [N:S]T — use arrayTypeSentinel to get elem_type
            const ats = tree.arrayTypeSentinel(node);
            return extractInnerTypeIdentifier(tree, ats.ast.elem_type);
        },
        else => null,
    };
}

pub fn scopeIntermediate(
    analyzer: *Analyzer,
    scope_idx: usize,
    node_idx: Ast.Node.Index,
    scope_name: ?[]const u8,
) anyerror!void {
    const tree = analyzer.handle.tree;

    if (analyzer.scopes.items.len != 1 and analyzer.scopes.items[analyzer.scopes.items.len - 1].node_idx == .root) return error.AnalysisInconsistency;

    switch (tree.nodeTag(node_idx)) {
        // .identifier => {
        // _ = try analyzer.resolveAndMarkDeclarationIdentifier(analyzer, scope_idx, main_tokens[node_idx]);
        // },
        .identifier, .field_access => {
            try analyzer.post_resolves.append(analyzer.allocator, .{ .scope_idx = scope_idx, .node_idx = node_idx });
            // _ = try analyzer.resolveAndMarkDeclarationComplex(analyzer, scope_idx, node_idx);
        },
        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .root,
        .error_set_decl,
        => {
            try analyzer.newContainerScope(scope_idx, node_idx, scope_name);
        },
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        => {
            const var_decl = utils.varDecl(tree, node_idx).?;

            var decl = Declaration{
                .node_idx = node_idx,
                .data = .{ .variable = var_decl },
            };

            const is_type = if (var_decl.ast.init_node.unwrap()) |init_node| utils.isContainer(tree, init_node) else false;
            decl.symbol = try analyzer.generateSymbol(scope_idx, decl, utils.getDeclName(tree, node_idx).?, is_type);

            try analyzer.addDeclaration(scope_idx, decl, null);

            if (var_decl.ast.type_node.unwrap()) |type_node| {
                try analyzer.scopeIntermediate(scope_idx, type_node, scope_name);
            }

            if (var_decl.ast.init_node.unwrap()) |init_node| {
                try analyzer.scopeIntermediate(scope_idx, init_node, scope_name);
            }
        },
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_decl,
        => |fn_tag| {
            var buf: [1]Ast.Node.Index = undefined;
            const func = utils.fnProto(tree, node_idx, &buf) orelse {
                logger.warn("Cannot create fnProto for node {d}", .{@intFromEnum(node_idx)});
                return;
            };

            var decl = Declaration{
                .node_idx = node_idx,
                .data = .{ .function = func },
            };
            decl.symbol = try analyzer.generateSymbol(scope_idx, decl, utils.getDeclName(analyzer.handle.tree, node_idx) orelse return, false);

            try analyzer.addDeclaration(scope_idx, decl, null);

            const func_scope_name = if (node_idx == .root)
                try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "file . {s} unversioned {f}", .{ analyzer.handle.package, analyzer.handle.formatter() }))
            else
                (if (analyzer.getDescriptor(scope_idx)) |desc|
                    try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ desc, analyzer.formatSubSymbol(scope_name orelse {
                        logger.warn("Missing function scope name at node {d}", .{@intFromEnum(node_idx)});
                        return;
                    }), "()." }))
                else
                    blk: {
                        analyzer.local_counter += 1;
                        break :blk try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "local {d}", .{analyzer.local_counter}));
                    });

            const scope = try analyzer.scopes.addOne(analyzer.allocator);
            scope.* = .{
                .node_idx = node_idx,
                .parent_scope_idx = scope_idx,
                .range = nodeSourceRange(tree, node_idx),
                .data = .{
                    .function = .{
                        .descriptor = func_scope_name,
                        .node_idx = node_idx,
                    },
                },
            };

            const func_scope_idx = analyzer.scopes.items.len - 1;
            try analyzer.scope_map.put(analyzer.allocator, node_idx, func_scope_idx);

            var it = func.iterate(&tree);
            while (it.next()) |param| {
                // Add parameter declarations
                if (param.name_token) |name_token| {
                    const param_name = tree.tokenSlice(name_token);
                    var param_decl = Declaration{
                        .node_idx = node_idx,
                        .data = .{ .param = param },
                    };
                    // Generate parameter symbol: enclosing function descriptor + (param_name)
                    param_decl.symbol = try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ func_scope_name, "(", analyzer.formatSubSymbol(param_name), ")" }));
                    // Add to the function scope
                    const fscope = &analyzer.scopes.items[func_scope_idx];
                    if ((try fscope.decls.fetchPut(analyzer.allocator, param_name, param_decl)) == null) {
                        // Record occurrence for the parameter definition
                        if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, name_token, {})) == null) {
                            try analyzer.symbols.append(analyzer.allocator, .{
                                .symbol = param_decl.symbol,
                                .documentation = .{},
                                .relationships = .{},
                                .kind = .parameter,
                                .display_name = param_name,
                            });
                            try analyzer.occurrences.append(analyzer.allocator, .{
                                .range = try analyzer.rangeArray(name_token),
                                .symbol = param_decl.symbol,
                                .symbol_roles = @intFromEnum(scip.SymbolRole.definition) | @intFromEnum(scip.SymbolRole.write_access),
                                .override_documentation = .{},
                                .syntax_kind = .identifier_parameter,
                                .diagnostics = .{},
                                .enclosing_range = try analyzer.nodeRangeArray(node_idx),
                            });
                        }
                    }
                }
                // Visit parameter types to pick up any error sets and enum
                //   completions
                if (param.type_expr) |type_expr|
                    try analyzer.scopeIntermediate(func_scope_idx, type_expr, scope_name);
            }

            // Visit the return type
            if (func.ast.return_type.unwrap()) |return_type_node| {
                try analyzer.scopeIntermediate(func_scope_idx, return_type_node, scope_name);
            }

            // Visit the function body
            if (fn_tag == .fn_decl) {
                const body_node = utils.nodeDataRhs(tree, node_idx);
                if (utils.nodePresent(body_node))
                    try analyzer.scopeIntermediate(func_scope_idx, body_node, scope_name);
            }
        },
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => {
            // If this is a labeled block (e.g., `blk: { ... }`), register the label
            // as a declaration in the parent scope
            const first_token = tree.firstToken(node_idx);
            if (tree.tokens.items(.tag)[first_token] == .identifier) {
                const label_name = tree.tokenSlice(first_token);
                analyzer.local_counter += 1;
                const label_symbol = try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "local {d}", .{analyzer.local_counter}));
                const label_decl = Declaration{
                    .node_idx = node_idx,
                    .symbol = label_symbol,
                    .data = .none,
                };
                const parent = &analyzer.scopes.items[scope_idx];
                if ((try parent.decls.fetchPut(analyzer.allocator, label_name, label_decl)) == null) {
                    if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, first_token, {})) == null) {
                        try analyzer.symbols.append(analyzer.allocator, .{
                            .symbol = label_symbol,
                            .documentation = .{},
                            .relationships = .{},
                            .kind = .variable,
                            .display_name = label_name,
                        });
                        try analyzer.occurrences.append(analyzer.allocator, .{
                            .range = try analyzer.rangeArray(first_token),
                            .symbol = label_symbol,
                            .symbol_roles = 0x1,
                            .override_documentation = .{},
                            .syntax_kind = .identifier_local,
                            .diagnostics = .{},
                        });
                    }
                }
            }

            const scope = try analyzer.scopes.addOne(analyzer.allocator);
            scope.* = .{
                .node_idx = node_idx,
                .parent_scope_idx = scope_idx,
                .range = nodeSourceRange(tree, node_idx),
                .data = .{
                    .block = node_idx,
                },
            };

            const block_scope_idx = analyzer.scopes.items.len - 1;
            try analyzer.scope_map.put(analyzer.allocator, node_idx, block_scope_idx);

            var buffer: [2]Ast.Node.Index = undefined;
            const statements = utils.blockStatements(tree, node_idx, &buffer) orelse return;

            for (statements) |idx| {
                try analyzer.scopeIntermediate(block_scope_idx, idx, null);
            }

            return;
        },
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const call = utils.callFull(tree, node_idx, &buf) orelse return;

            try analyzer.scopeIntermediate(scope_idx, call.ast.fn_expr, scope_name);
            for (call.ast.params) |param|
                try analyzer.scopeIntermediate(scope_idx, param, scope_name);
        },
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        .assign_shl_sat,
        .assign,
        => {
            const bin_lhs = utils.nodeDataLhs(tree, node_idx);
            if (utils.nodePresent(bin_lhs)) {
                // Mark the write target token
                analyzer.markWriteTarget(tree, bin_lhs);
                try analyzer.scopeIntermediate(scope_idx, bin_lhs, scope_name);
            }
            const bin_rhs = utils.nodeDataRhs(tree, node_idx);
            if (utils.nodePresent(bin_rhs))
                try analyzer.scopeIntermediate(scope_idx, bin_rhs, scope_name);
        },
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .merge_error_sets,
        .mul,
        .div,
        .mod,
        .array_mult,
        .mul_wrap,
        .mul_sat,
        .add,
        .sub,
        .array_cat,
        .add_wrap,
        .sub_wrap,
        .add_sat,
        .sub_sat,
        .shl,
        .shl_sat,
        .shr,
        .bit_and,
        .bit_xor,
        .bit_or,
        .@"orelse",
        .bool_and,
        .bool_or,
        .array_type,
        .array_access,
        .error_union,
        => {
            const bin_lhs = utils.nodeDataLhs(tree, node_idx);
            if (utils.nodePresent(bin_lhs))
                try analyzer.scopeIntermediate(scope_idx, bin_lhs, scope_name);
            const bin_rhs = utils.nodeDataRhs(tree, node_idx);
            if (utils.nodePresent(bin_rhs))
                try analyzer.scopeIntermediate(scope_idx, bin_rhs, scope_name);
        },
        .@"return",
        .@"resume",
        .@"suspend",
        .deref,
        .@"try",
        .optional_type,
        .@"comptime",
        .@"nosuspend",
        .bool_not,
        .negation,
        .bit_not,
        .negation_wrap,
        .address_of,
        .grouped_expression,
        .unwrap_optional,
        => {
            const unary_operand = utils.nodeDataLhs(tree, node_idx);
            if (utils.nodePresent(unary_operand))
                try analyzer.scopeIntermediate(scope_idx, unary_operand, scope_name);
        },
        .@"if",
        .if_simple,
        => {
            const if_node = utils.ifFull(tree, node_idx).?;

            try analyzer.scopeIntermediate(scope_idx, if_node.ast.cond_expr, scope_name);

            if (if_node.payload_token) |payload_token| {
                const ident_token = resolvePayloadIdentToken(tree, payload_token);
                const then_scope = try analyzer.addPayloadScope(scope_idx, if_node.ast.then_expr, ident_token);
                try analyzer.processPayloadBody(then_scope, if_node.ast.then_expr, scope_name);
            } else {
                try analyzer.scopeIntermediate(scope_idx, if_node.ast.then_expr, scope_name);
            }

            if (if_node.ast.else_expr.unwrap()) |else_expr| {
                if (if_node.error_token) |error_token| {
                    const else_scope = try analyzer.addPayloadScope(scope_idx, else_expr, error_token);
                    try analyzer.processPayloadBody(else_scope, else_expr, scope_name);
                } else {
                    try analyzer.scopeIntermediate(scope_idx, else_expr, scope_name);
                }
            }
        },
        .@"while",
        .while_simple,
        .while_cont,
        => {
            const while_node = utils.whileAst(tree, node_idx).?;

            try analyzer.scopeIntermediate(scope_idx, while_node.ast.cond_expr, scope_name);

            if (while_node.payload_token) |payload_token| {
                const ident_token = resolvePayloadIdentToken(tree, payload_token);
                const then_scope = try analyzer.addPayloadScope(scope_idx, while_node.ast.then_expr, ident_token);
                if (while_node.ast.cont_expr.unwrap()) |cont_expr|
                    try analyzer.scopeIntermediate(then_scope, cont_expr, scope_name);
                try analyzer.processPayloadBody(then_scope, while_node.ast.then_expr, scope_name);
            } else {
                if (while_node.ast.cont_expr.unwrap()) |cont_expr|
                    try analyzer.scopeIntermediate(scope_idx, cont_expr, scope_name);
                try analyzer.scopeIntermediate(scope_idx, while_node.ast.then_expr, scope_name);
            }

            if (while_node.ast.else_expr.unwrap()) |else_expr| {
                if (while_node.error_token) |error_token| {
                    const else_scope = try analyzer.addPayloadScope(scope_idx, else_expr, error_token);
                    try analyzer.processPayloadBody(else_scope, else_expr, scope_name);
                } else {
                    try analyzer.scopeIntermediate(scope_idx, else_expr, scope_name);
                }
            }
        },
        .@"for",
        .for_simple,
        => {
            const for_node = utils.forAst(tree, node_idx).?;

            for (for_node.ast.inputs) |input|
                try analyzer.scopeIntermediate(scope_idx, input, scope_name);

            // Create scope for the then_expr with all capture variables
            // First capture is at payload_token, then add the first one
            const first_ident = resolvePayloadIdentToken(tree, for_node.payload_token);
            const then_scope = try analyzer.addPayloadScope(scope_idx, for_node.ast.then_expr, first_ident);

            // Walk remaining captures: tokens separated by commas
            var tok = first_ident + 1; // move past first identifier
            const token_tags = tree.tokens.items(.tag);
            var captures_added: usize = 1;
            while (captures_added < for_node.ast.inputs.len) : (captures_added += 1) {
                // Expect comma then optional * then identifier
                if (token_tags[tok] == .comma) {
                    tok += 1;
                    const ident = resolvePayloadIdentToken(tree, tok);
                    // Add this capture to the then_scope
                    const cap_name = tree.tokenSlice(ident);
                    if (!std.mem.eql(u8, cap_name, "_")) {
                        analyzer.local_counter += 1;
                        const cap_symbol = try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "local {d}", .{analyzer.local_counter}));
                        const cap_decl = Declaration{
                            .node_idx = for_node.ast.then_expr,
                            .symbol = cap_symbol,
                            .data = .none,
                        };
                        if ((try analyzer.scopes.items[then_scope].decls.fetchPut(analyzer.allocator, cap_name, cap_decl)) == null) {
                            if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, ident, {})) == null) {
                                try analyzer.symbols.append(analyzer.allocator, .{
                                    .symbol = cap_symbol,
                                    .documentation = .{},
                                    .relationships = .{},
                                    .kind = .variable,
                                    .display_name = cap_name,
                                });
                                try analyzer.occurrences.append(analyzer.allocator, .{
                                    .range = try analyzer.rangeArray(ident),
                                    .symbol = cap_symbol,
                                    .symbol_roles = @intFromEnum(scip.SymbolRole.definition) | @intFromEnum(scip.SymbolRole.write_access),
                                    .override_documentation = .{},
                                    .syntax_kind = .identifier_local,
                                    .diagnostics = .{},
                                });
                            }
                        }
                    }
                    tok = ident + 1;
                } else {
                    break;
                }
            }

            try analyzer.processPayloadBody(then_scope, for_node.ast.then_expr, scope_name);
            if (for_node.ast.else_expr.unwrap()) |else_expr|
                try analyzer.scopeIntermediate(scope_idx, else_expr, scope_name);
        },
        .test_decl => {
            // test_decl data: opt_token_and_node
            //   [0] = optional name token (string literal or identifier)
            //   [1] = body block node
            const body_node = utils.nodeDataRhs(tree, node_idx);

            // Generate a symbol for the test
            const test_name = utils.getDeclName(tree, node_idx) orelse "unnamed";
            const scope = &analyzer.scopes.items[scope_idx];
            const container_desc = switch (scope.data) {
                .container => |c| c.descriptor,
                else => "",
            };
            const test_symbol = try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ container_desc, "`", test_name, "`:", }));

            // Record the test keyword token as a definition with Test role
            const test_token = tree.nodeMainToken(node_idx);
            if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, test_token, {})) == null) {
                try analyzer.symbols.append(analyzer.allocator, .{
                    .symbol = test_symbol,
                    .documentation = .{},
                    .relationships = .{},
                    .kind = .function,
                    .display_name = test_name,
                });
                try analyzer.occurrences.append(analyzer.allocator, .{
                    .range = try analyzer.rangeArray(test_token),
                    .symbol = test_symbol,
                    .symbol_roles = @intFromEnum(scip.SymbolRole.definition) | @intFromEnum(scip.SymbolRole.@"test"),
                    .override_documentation = .{},
                    .syntax_kind = .identifier_function_definition,
                    .diagnostics = .{},
                });
            }

            // Create a block scope for the test body and process it
            if (utils.nodePresent(body_node))
                try analyzer.scopeIntermediate(scope_idx, body_node, test_name);
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const params = utils.builtinCallParams(tree, node_idx, &buffer).?;
            const call_name = tree.tokenSlice(tree.nodeMainToken(node_idx));

            for (params) |p|
                try analyzer.scopeIntermediate(scope_idx, p, scope_name);

            if (std.mem.eql(u8, call_name, "@import")) {
                const import_param = params[0];
                const import_str = tree.tokenSlice(tree.nodeMainToken(import_param));

                try analyzer.scopes.append(analyzer.allocator, .{
                    .node_idx = node_idx,
                    .parent_scope_idx = scope_idx,
                    .range = nodeSourceRange(tree, node_idx),
                    .data = .{
                        .import = import_str[1 .. import_str.len - 1],
                    },
                });
                try analyzer.scope_map.put(analyzer.allocator, node_idx, analyzer.scopes.items.len - 1);

                // Record @import occurrence with Import role
                if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, tree.nodeMainToken(node_idx), {})) == null) {
                    // Resolve the import target to get its root descriptor
                    const import_symbol: []const u8 = blk: {
                        const ih = analyzer.handle.document_store.resolveImportHandle(analyzer.handle, import_str[1 .. import_str.len - 1]) catch break :blk "";
                        if (ih) |h| {
                            break :blk h.analyzer.getDescriptor(0) orelse "";
                        }
                        break :blk "";
                    };
                    try analyzer.occurrences.append(analyzer.allocator, .{
                        .range = try analyzer.rangeArray(tree.nodeMainToken(node_idx)),
                        .symbol = import_symbol,
                        .symbol_roles = @intFromEnum(scip.SymbolRole.import),
                        .override_documentation = .{},
                        .syntax_kind = .identifier_builtin,
                        .diagnostics = .{},
                    });
                }
            } else {
                // Record non-import builtin name (e.g., @intFromEnum) as syntax occurrence
                const builtin_token = tree.nodeMainToken(node_idx);
                if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, builtin_token, {})) == null) {
                    try analyzer.occurrences.append(analyzer.allocator, .{
                        .range = try analyzer.rangeArray(builtin_token),
                        .symbol = "",
                        .symbol_roles = 0,
                        .override_documentation = .{},
                        .syntax_kind = .identifier_builtin,
                        .diagnostics = .{},
                    });
                }
            }
        },
        .@"switch",
        .switch_comma,
        => {
            const switch_full = utils.switchFull(tree, node_idx) orelse return;

            // Visit the condition expression
            try analyzer.scopeIntermediate(scope_idx, switch_full.ast.condition, scope_name);

            // Visit each switch case
            for (switch_full.ast.cases) |case_node| {
                const case = utils.switchCaseFull(tree, case_node) orelse continue;

                // Visit case values (match expressions)
                for (case.ast.values) |val|
                    try analyzer.scopeIntermediate(scope_idx, val, scope_name);

                // Handle capture payload
                if (case.payload_token) |payload_token| {
                    const ident_token = resolvePayloadIdentToken(tree, payload_token);
                    const case_scope = try analyzer.addPayloadScope(scope_idx, case.ast.target_expr, ident_token);
                    try analyzer.processPayloadBody(case_scope, case.ast.target_expr, scope_name);
                } else {
                    try analyzer.scopeIntermediate(scope_idx, case.ast.target_expr, scope_name);
                }
            }
        },
        .switch_range => {
            // switch range: lhs...rhs — visit both bounds
            const range_lhs = utils.nodeDataLhs(tree, node_idx);
            if (utils.nodePresent(range_lhs))
                try analyzer.scopeIntermediate(scope_idx, range_lhs, scope_name);
            const range_rhs = utils.nodeDataRhs(tree, node_idx);
            if (utils.nodePresent(range_rhs))
                try analyzer.scopeIntermediate(scope_idx, range_rhs, scope_name);
        },
        .@"catch" => {
            // catch: lhs catch [|err|] rhs
            const catch_lhs = utils.nodeDataLhs(tree, node_idx);
            if (utils.nodePresent(catch_lhs))
                try analyzer.scopeIntermediate(scope_idx, catch_lhs, scope_name);

            const catch_rhs = utils.nodeDataRhs(tree, node_idx);
            if (!utils.nodePresent(catch_rhs)) return;

            // Check for error payload: token after 'catch' keyword
            const main_token = tree.nodeMainToken(node_idx);
            const next_tag = tree.tokens.items(.tag)[main_token + 1];
            if (next_tag == .pipe) {
                // Has error payload: catch |err| body
                const ident_token = main_token + 2; // skip 'catch' and '|'
                const err_scope = try analyzer.addPayloadScope(scope_idx, catch_rhs, ident_token);
                try analyzer.processPayloadBody(err_scope, catch_rhs, scope_name);
            } else {
                try analyzer.scopeIntermediate(scope_idx, catch_rhs, scope_name);
            }
        },
        .@"defer" => {
            // defer data variant is .node — expression is at lhs position
            const defer_expr = utils.nodeDataLhs(tree, node_idx);
            if (utils.nodePresent(defer_expr))
                try analyzer.scopeIntermediate(scope_idx, defer_expr, scope_name);
        },
        .@"errdefer" => {
            // errdefer data variant is .opt_token_and_node — expression is at rhs position
            const defer_expr = utils.nodeDataRhs(tree, node_idx);
            if (utils.nodePresent(defer_expr))
                try analyzer.scopeIntermediate(scope_idx, defer_expr, scope_name);
        },
        .struct_init,
        .struct_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            if (utils.structInitFull(tree, node_idx, &buf)) |si| {
                // Visit the type expression if present
                if (si.ast.type_expr.unwrap()) |type_expr|
                    try analyzer.scopeIntermediate(scope_idx, type_expr, scope_name);

                // Visit each field initializer value
                for (si.ast.fields) |field_node|
                    try analyzer.scopeIntermediate(scope_idx, field_node, scope_name);

                // Try to resolve struct literal field names as references
                // Resolve type_expr to a container scope with field declarations
                if (si.ast.type_expr.unwrap()) |type_expr| {
                    const resolved = try analyzer.resolveAndMarkDeclarationComplex(analyzer, scope_idx, type_expr);
                    if (resolved.declaration) |decl| {
                        if (decl.data == .variable) {
                            if (decl.data.variable.ast.init_node.unwrap()) |init_node| {
                                if (resolved.analyzer.scope_map.get(init_node)) |container_scope_idx| {
                                    const container_scope = resolved.analyzer.scopes.items[container_scope_idx];
                                    if (container_scope.data == .container) {
                                        // Match field names from struct init to field declarations
                                        for (si.ast.fields) |field_node| {
                                            // Field name token is at firstToken(field_node) - 2: `.name = value`
                                            const first_tok = tree.firstToken(field_node);
                                            if (first_tok >= 2) {
                                                const field_name_tok = first_tok - 2;
                                                if (tree.tokens.items(.tag)[field_name_tok] == .identifier) {
                                                    const field_name = tree.tokenSlice(field_name_tok);
                                                    if (container_scope.data.container.fields.get(field_name)) |field| {
                                                        _ = field;
                                                        const field_symbol = try analyzer.trackSymbol(try std.mem.concat(analyzer.allocator, u8, &.{ container_scope.data.container.descriptor, resolved.analyzer.formatSubSymbol(field_name), "." }));
                                                        if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, field_name_tok, {})) == null) {
                                                            try analyzer.occurrences.append(analyzer.allocator, .{
                                                                .range = try analyzer.rangeArray(field_name_tok),
                                                                .symbol = field_symbol,
                                                                .symbol_roles = @intFromEnum(scip.SymbolRole.write_access),
                                                                .override_documentation = .{},
                                                                .syntax_kind = .identifier,
                                                                .diagnostics = .{},
                                                            });
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
        .slice,
        .slice_open,
        .slice_sentinel,
        => {
            if (utils.sliceFull(tree, node_idx)) |sl| {
                try analyzer.scopeIntermediate(scope_idx, sl.ast.sliced, scope_name);
                try analyzer.scopeIntermediate(scope_idx, sl.ast.start, scope_name);
                if (sl.ast.end.unwrap()) |end|
                    try analyzer.scopeIntermediate(scope_idx, end, scope_name);
                if (sl.ast.sentinel.unwrap()) |sentinel|
                    try analyzer.scopeIntermediate(scope_idx, sentinel, scope_name);
            }
        },
        .array_init,
        .array_init_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        => {
            var ai_buf: [2]Ast.Node.Index = undefined;
            if (tree.fullArrayInit(&ai_buf, node_idx)) |ai| {
                if (ai.ast.type_expr.unwrap()) |type_expr|
                    try analyzer.scopeIntermediate(scope_idx, type_expr, scope_name);
                for (ai.ast.elements) |elem|
                    try analyzer.scopeIntermediate(scope_idx, elem, scope_name);
            }
        },
        .ptr_type,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type_bit_range,
        => {
            if (utils.ptrType(tree, node_idx)) |pt| {
                try analyzer.scopeIntermediate(scope_idx, pt.ast.child_type, scope_name);
                if (pt.ast.sentinel.unwrap()) |sentinel|
                    try analyzer.scopeIntermediate(scope_idx, sentinel, scope_name);
                if (pt.ast.align_node.unwrap()) |align_node|
                    try analyzer.scopeIntermediate(scope_idx, align_node, scope_name);
            }
        },
        .array_type_sentinel => {
            const ats = tree.arrayTypeSentinel(node_idx);
            try analyzer.scopeIntermediate(scope_idx, ats.ast.elem_type, scope_name);
            if (ats.ast.sentinel.unwrap()) |sentinel|
                try analyzer.scopeIntermediate(scope_idx, sentinel, scope_name);
            if (utils.nodePresent(ats.ast.elem_count))
                try analyzer.scopeIntermediate(scope_idx, ats.ast.elem_count, scope_name);
        },
        .error_value => {
            // error.Name — token sequence: `error`, `.`, `Name`
            const name_token = tree.nodeMainToken(node_idx) + 2;
            if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, name_token, {})) == null) {
                try analyzer.occurrences.append(analyzer.allocator, .{
                    .range = try analyzer.rangeArray(name_token),
                    .symbol = "",
                    .symbol_roles = 0,
                    .override_documentation = .{},
                    .syntax_kind = .identifier_constant,
                    .diagnostics = .{},
                });
            }
        },
        .enum_literal => {
            // .foo — the main_token points to the identifier after the dot
            const name_token = tree.nodeMainToken(node_idx);
            if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, name_token, {})) == null) {
                try analyzer.occurrences.append(analyzer.allocator, .{
                    .range = try analyzer.rangeArray(name_token),
                    .symbol = "",
                    .symbol_roles = 0,
                    .override_documentation = .{},
                    .syntax_kind = .identifier_constant,
                    .diagnostics = .{},
                });
            }
        },
        .@"asm",
        .asm_simple,
        => {},
        else => {},
    }
}

/// Creates a new block scope and registers a payload capture identifier as a local declaration.
/// Returns the new scope index. If name_token is null, just creates an empty scope.
fn addPayloadScope(
    analyzer: *Analyzer,
    parent_scope_idx: usize,
    body_node: Ast.Node.Index,
    name_token: ?Ast.TokenIndex,
) !usize {
    const tree = analyzer.handle.tree;

    const scope = try analyzer.scopes.addOne(analyzer.allocator);
    scope.* = .{
        .node_idx = body_node,
        .parent_scope_idx = parent_scope_idx,
        .range = nodeSourceRange(tree, body_node),
        .data = .{ .block = body_node },
    };
    const new_scope_idx = analyzer.scopes.items.len - 1;
    try analyzer.scope_map.put(analyzer.allocator, body_node, new_scope_idx);

    if (name_token) |tok| {
        const name = tree.tokenSlice(tok);
        if (!std.mem.eql(u8, name, "_")) {
            analyzer.local_counter += 1;
            const symbol = try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "local {d}", .{analyzer.local_counter}));

            const decl = Declaration{
                .node_idx = body_node,
                .symbol = symbol,
                .data = .none,
            };

            if ((try analyzer.scopes.items[new_scope_idx].decls.fetchPut(analyzer.allocator, name, decl)) == null) {
                if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, tok, {})) == null) {
                    try analyzer.symbols.append(analyzer.allocator, .{
                        .symbol = symbol,
                        .documentation = .{},
                        .relationships = .{},
                        .kind = .variable,
                        .display_name = name,
                    });
                    try analyzer.occurrences.append(analyzer.allocator, .{
                        .range = try analyzer.rangeArray(tok),
                        .symbol = symbol,
                        .symbol_roles = @intFromEnum(scip.SymbolRole.definition) | @intFromEnum(scip.SymbolRole.write_access),
                        .override_documentation = .{},
                        .syntax_kind = .identifier_local,
                        .diagnostics = .{},
                        .enclosing_range = try analyzer.nodeRangeArray(body_node),
                    });
                }
            }
        }
    }

    return new_scope_idx;
}

/// Resolves the actual identifier token from a payload_token, skipping `*` if present.
fn resolvePayloadIdentToken(tree: Ast, payload_token: Ast.TokenIndex) Ast.TokenIndex {
    if (tree.tokens.items(.tag)[payload_token] == .asterisk) {
        return payload_token + 1;
    }
    return payload_token;
}

/// Processes a payload body node within an existing payload scope.
/// If the body is a block, processes its statements directly in the payload scope
/// (avoiding a redundant nested block scope). Otherwise delegates to scopeIntermediate.
fn processPayloadBody(
    analyzer: *Analyzer,
    payload_scope_idx: usize,
    body_node: Ast.Node.Index,
    scope_name: ?[]const u8,
) !void {
    const tree = analyzer.handle.tree;
    switch (tree.nodeTag(body_node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            // Handle labeled blocks: register label in the payload scope
            const first_token = tree.firstToken(body_node);
            if (tree.tokens.items(.tag)[first_token] == .identifier) {
                const label_name = tree.tokenSlice(first_token);
                analyzer.local_counter += 1;
                const label_symbol = try analyzer.trackSymbol(try std.fmt.allocPrint(analyzer.allocator, "local {d}", .{analyzer.local_counter}));
                const label_decl = Declaration{
                    .node_idx = body_node,
                    .symbol = label_symbol,
                    .data = .none,
                };
                const scope = &analyzer.scopes.items[payload_scope_idx];
                if ((try scope.decls.fetchPut(analyzer.allocator, label_name, label_decl)) == null) {
                    if ((try analyzer.recorded_occurrences.fetchPut(analyzer.allocator, first_token, {})) == null) {
                        try analyzer.symbols.append(analyzer.allocator, .{
                            .symbol = label_symbol,
                            .documentation = .{},
                            .relationships = .{},
                            .kind = .variable,
                            .display_name = label_name,
                        });
                        try analyzer.occurrences.append(analyzer.allocator, .{
                            .range = try analyzer.rangeArray(first_token),
                            .symbol = label_symbol,
                            .symbol_roles = 0x1,
                            .override_documentation = .{},
                            .syntax_kind = .identifier_local,
                            .diagnostics = .{},
                        });
                    }
                }
            }

            // Process block statements directly in the payload scope
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = utils.blockStatements(tree, body_node, &buffer) orelse return;
            for (statements) |idx| {
                try analyzer.scopeIntermediate(payload_scope_idx, idx, null);
            }
        },
        else => {
            try analyzer.scopeIntermediate(payload_scope_idx, body_node, scope_name);
        },
    }
}

fn markWriteTarget(analyzer: *Analyzer, tree: Ast, node_idx: Ast.Node.Index) void {
    switch (tree.nodeTag(node_idx)) {
        .identifier => {
            analyzer.write_tokens.put(analyzer.allocator, tree.nodeMainToken(node_idx), {}) catch {};
        },
        .field_access => {
            // The field name token (rhs) is the write target
            const field_token: Ast.TokenIndex = utils.nodeDataRhsRaw(tree, node_idx);
            analyzer.write_tokens.put(analyzer.allocator, field_token, {}) catch {};
        },
        else => {},
    }
}

fn nodeSourceRange(tree: Ast, node: Ast.Node.Index) SourceRange {
    const loc_start = utils.tokenLocation(tree, tree.firstToken(node));
    const loc_end = utils.tokenLocation(tree, tree.lastToken(node));

    return SourceRange{
        .start = loc_start.start,
        .end = loc_end.end,
    };
}

// --- Tests ---

/// Creates a minimal Handle and Analyzer for test purposes.
/// Uses an arena allocator so everything is freed together.
fn testAnalyzer(arena: std.mem.Allocator, source: [:0]const u8) !struct { handle: *DocumentStore.Handle, analyzer: *Analyzer } {
    const tree = try std.zig.Ast.parse(arena, source, .zig);

    const store = try arena.create(DocumentStore);
    store.* = .{ .allocator = arena, .root_path = "" };

    var handle = try arena.create(DocumentStore.Handle);
    handle.* = .{
        .document_store = store,
        .package = "test",
        .path = "test.zig",
        .text = source,
        .tree = tree,
        .analyzer = undefined,
    };
    handle.analyzer = .{ .allocator = arena, .handle = handle };
    try handle.analyzer.init();

    return .{ .handle = handle, .analyzer = &handle.analyzer };
}

fn findScopeDecl(analyzer: *Analyzer, name: []const u8) ?Declaration {
    for (analyzer.scopes.items) |scope| {
        if (scope.decls.get(name)) |decl| return decl;
    }
    return null;
}

fn findOccurrenceBySymbol(analyzer: *Analyzer, symbol_prefix: []const u8) ?scip.Occurrence {
    for (analyzer.occurrences.items) |occ| {
        if (std.mem.startsWith(u8, occ.symbol, symbol_prefix)) return occ;
    }
    return null;
}

test "scope_map is populated for container and block scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try testAnalyzer(arena.allocator(),
        \\const std = @import("std");
        \\fn foo() void {
        \\    var x: u32 = 1;
        \\    _ = x;
        \\}
    );

    // scope_map should have entries
    try std.testing.expect(result.analyzer.scope_map.count() > 0);
    // Root scope should exist (scope 0)
    try std.testing.expect(result.analyzer.scopes.items.len >= 2);
}

test "if payload creates scope with capture variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try testAnalyzer(arena.allocator(),
        \\fn foo(opt: ?u32) void {
        \\    if (opt) |val| {
        \\        _ = val;
        \\    }
        \\}
    );

    // "val" should be declared in some scope
    const decl = findScopeDecl(result.analyzer, "val");
    try std.testing.expect(decl != null);
    try std.testing.expect(std.mem.startsWith(u8, decl.?.symbol, "local "));
}

test "if-else with error payload creates scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try testAnalyzer(arena.allocator(),
        \\fn foo(e: anyerror!u32) void {
        \\    if (e) |val| {
        \\        _ = val;
        \\    } else |err| {
        \\        _ = err;
        \\    }
        \\}
    );

    const val_decl = findScopeDecl(result.analyzer, "val");
    try std.testing.expect(val_decl != null);

    const err_decl = findScopeDecl(result.analyzer, "err");
    try std.testing.expect(err_decl != null);
}

test "while payload creates scope with capture variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try testAnalyzer(arena.allocator(),
        \\fn foo(iter: anytype) void {
        \\    while (iter.next()) |item| {
        \\        _ = item;
        \\    }
        \\}
    );

    const decl = findScopeDecl(result.analyzer, "item");
    try std.testing.expect(decl != null);
    try std.testing.expect(std.mem.startsWith(u8, decl.?.symbol, "local "));
}

test "for loop creates scope with capture variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try testAnalyzer(arena.allocator(),
        \\fn foo(items: []const u32) void {
        \\    for (items) |item| {
        \\        _ = item;
        \\    }
        \\}
    );

    const decl = findScopeDecl(result.analyzer, "item");
    try std.testing.expect(decl != null);
    try std.testing.expect(std.mem.startsWith(u8, decl.?.symbol, "local "));
}

test "for loop with multiple captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try testAnalyzer(arena.allocator(),
        \\fn foo(a: []const u8, b: []const u8) void {
        \\    for (a, b) |x, y| {
        \\        _ = x;
        \\        _ = y;
        \\    }
        \\}
    );

    const x_decl = findScopeDecl(result.analyzer, "x");
    try std.testing.expect(x_decl != null);

    const y_decl = findScopeDecl(result.analyzer, "y");
    try std.testing.expect(y_decl != null);
}

test "labeled block registers label in scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try testAnalyzer(arena.allocator(),
        \\fn foo() u32 {
        \\    const x = blk: {
        \\        break :blk 42;
        \\    };
        \\    return x;
        \\}
    );

    const decl = findScopeDecl(result.analyzer, "blk");
    try std.testing.expect(decl != null);
}

test "payload captures generate definition occurrences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try testAnalyzer(arena.allocator(),
        \\fn foo(opt: ?u32) void {
        \\    if (opt) |val| {
        \\        _ = val;
        \\    }
        \\}
    );

    // Find the symbol for "val"
    const decl = findScopeDecl(result.analyzer, "val");
    try std.testing.expect(decl != null);

    // There should be an occurrence with definition role for this symbol
    const occ = findOccurrenceBySymbol(result.analyzer, decl.?.symbol);
    try std.testing.expect(occ != null);
    try std.testing.expect(occ.?.symbol_roles & 0x1 != 0); // definition bit
}
