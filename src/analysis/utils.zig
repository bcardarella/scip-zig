//! Collection of functions from std.zig.ast that we need
//! and may hit undefined in the standard library implementation
//! when there are parser errors.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const full = Ast.full;
const builtin = @import("builtin");

/// Delegate to stdlib's lastToken
pub fn lastToken(tree: Ast, node: Ast.Node.Index) Ast.TokenIndex {
    return tree.lastToken(node);
}

pub fn containerField(tree: Ast, node: Ast.Node.Index) ?Ast.full.ContainerField {
    return switch (tree.nodeTag(node)) {
        .container_field => tree.containerField(node),
        .container_field_init => tree.containerFieldInit(node),
        .container_field_align => tree.containerFieldAlign(node),
        else => null,
    };
}

pub fn ptrType(tree: Ast, node: Ast.Node.Index) ?Ast.full.PtrType {
    return tree.fullPtrType(node);
}

pub fn whileAst(tree: Ast, node: Ast.Node.Index) ?Ast.full.While {
    return tree.fullWhile(node);
}

pub fn ifFull(tree: Ast, node: Ast.Node.Index) ?Ast.full.If {
    return tree.fullIf(node);
}

pub fn forAst(tree: Ast, node: Ast.Node.Index) ?Ast.full.For {
    return tree.fullFor(node);
}

pub fn isContainer(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
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
        => true,
        else => false,
    };
}

/// Returns the member indices of a given declaration container.
/// Asserts given `tag` is a container node
pub fn declMembers(tree: Ast, node_idx: Ast.Node.Index, buffer: *[2]Ast.Node.Index) []const Ast.Node.Index {
    std.debug.assert(isContainer(tree, node_idx));
    return switch (tree.nodeTag(node_idx)) {
        .container_decl, .container_decl_trailing => tree.containerDecl(node_idx).ast.members,
        .container_decl_arg, .container_decl_arg_trailing => tree.containerDeclArg(node_idx).ast.members,
        .container_decl_two, .container_decl_two_trailing => tree.containerDeclTwo(buffer, node_idx).ast.members,
        .tagged_union, .tagged_union_trailing => tree.taggedUnion(node_idx).ast.members,
        .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => tree.taggedUnionEnumTag(node_idx).ast.members,
        .tagged_union_two, .tagged_union_two_trailing => tree.taggedUnionTwo(buffer, node_idx).ast.members,
        .root => tree.rootDecls(),
        .error_set_decl => &[_]Ast.Node.Index{},
        else => unreachable,
    };
}

/// Returns an `ast.full.VarDecl` for a given node index.
/// Returns null if the tag doesn't match
pub fn varDecl(tree: Ast, node_idx: Ast.Node.Index) ?Ast.full.VarDecl {
    return switch (tree.nodeTag(node_idx)) {
        .global_var_decl => tree.globalVarDecl(node_idx),
        .local_var_decl => tree.localVarDecl(node_idx),
        .aligned_var_decl => tree.alignedVarDecl(node_idx),
        .simple_var_decl => tree.simpleVarDecl(node_idx),
        else => null,
    };
}

pub fn isPtrType(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .ptr_type,
        .ptr_type_aligned,
        .ptr_type_bit_range,
        .ptr_type_sentinel,
        => true,
        else => false,
    };
}

pub fn isBuiltinCall(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => true,
        else => false,
    };
}

pub fn fnProto(tree: Ast, node: Ast.Node.Index, buf: *[1]Ast.Node.Index) ?Ast.full.FnProto {
    return switch (tree.nodeTag(node)) {
        .fn_proto => tree.fnProto(node),
        .fn_proto_multi => tree.fnProtoMulti(node),
        .fn_proto_one => tree.fnProtoOne(buf, node),
        .fn_proto_simple => tree.fnProtoSimple(buf, node),
        .fn_decl => fnProto(tree, nodeDataLhs(tree, node), buf),
        else => null,
    };
}

pub fn callFull(tree: Ast, node: Ast.Node.Index, buf: *[1]Ast.Node.Index) ?Ast.full.Call {
    return switch (tree.nodeTag(node)) {
        .call,
        .call_comma,
        => tree.callFull(node),
        .call_one,
        .call_one_comma,
        => tree.callOne(buf, node),
        else => null,
    };
}

pub fn switchFull(tree: Ast, node: Ast.Node.Index) ?Ast.full.Switch {
    return tree.fullSwitch(node);
}

pub fn switchCaseFull(tree: Ast, node: Ast.Node.Index) ?Ast.full.SwitchCase {
    return tree.fullSwitchCase(node);
}

pub fn structInitFull(tree: Ast, node: Ast.Node.Index, buf: *[2]Ast.Node.Index) ?Ast.full.StructInit {
    return tree.fullStructInit(buf, node);
}

pub fn sliceFull(tree: Ast, node: Ast.Node.Index) ?Ast.full.Slice {
    return tree.fullSlice(node);
}

/// returns a list of parameters
pub fn builtinCallParams(tree: Ast, node: Ast.Node.Index, buf: *[2]Ast.Node.Index) ?[]const Node.Index {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {
            const d = tree.nodeData(node).opt_node_and_opt_node;
            if (d[0].unwrap()) |lhs| {
                buf[0] = lhs;
                if (d[1].unwrap()) |rhs| {
                    buf[1] = rhs;
                    return buf[0..2];
                } else {
                    return buf[0..1];
                }
            } else {
                return buf[0..0];
            }
        },
        .builtin_call,
        .builtin_call_comma,
        => {
            const range = tree.nodeData(node).extra_range;
            return tree.extraDataSlice(range, Node.Index);
        },
        else => return null,
    };
}

/// returns a list of statements
pub fn blockStatements(tree: Ast, node: Ast.Node.Index, buf: *[2]Ast.Node.Index) ?[]const Node.Index {
    return switch (tree.nodeTag(node)) {
        .block_two, .block_two_semicolon => {
            const d = tree.nodeData(node).opt_node_and_opt_node;
            const lhs = d[0].unwrap();
            const rhs = d[1].unwrap();
            if (lhs) |l| {
                buf[0] = l;
                if (rhs) |r| {
                    buf[1] = r;
                    return buf[0..2];
                } else {
                    return buf[0..1];
                }
            } else {
                return buf[0..0];
            }
        },
        .block,
        .block_semicolon,
        => {
            const range = tree.nodeData(node).extra_range;
            return tree.extraDataSlice(range, Node.Index);
        },
        else => return null,
    };
}

pub fn tokenLocation(tree: Ast, token_index: Ast.TokenIndex) std.zig.Token.Loc {
    const start = tree.tokens.items(.start)[token_index];
    const tag = tree.tokens.items(.tag)[token_index];

    var tokenizer: std.zig.Tokenizer = .{
        .buffer = tree.source,
        .index = start,
    };

    const token = tokenizer.next();
    if (token.tag != tag) return .{ .start = 0, .end = 0 };
    return .{ .start = token.loc.start, .end = token.loc.end };
}

pub fn getDeclNameToken(tree: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    const tag = tree.nodeTag(node);
    const main_token = tree.nodeMainToken(node);
    return switch (tag) {
        // regular declaration names. + 1 to mut token because name comes after 'const'/'var'
        .local_var_decl => tree.localVarDecl(node).ast.mut_token + 1,
        .global_var_decl => tree.globalVarDecl(node).ast.mut_token + 1,
        .simple_var_decl => tree.simpleVarDecl(node).ast.mut_token + 1,
        .aligned_var_decl => tree.alignedVarDecl(node).ast.mut_token + 1,
        // function declaration names
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => blk: {
            var params: [1]Ast.Node.Index = undefined;
            break :blk fnProto(tree, node, &params).?.name_token;
        },

        // containers
        .container_field => if (tree.containerField(node).ast.tuple_like) null else tree.containerField(node).ast.main_token,
        .container_field_init => if (tree.containerFieldInit(node).ast.tuple_like) null else tree.containerFieldInit(node).ast.main_token,
        .container_field_align => if (tree.containerFieldAlign(node).ast.tuple_like) null else tree.containerFieldAlign(node).ast.main_token,

        .identifier => main_token,
        .error_value => main_token + 2, // 'error'.<main_token +2>

        // lhs of main token is name token, so use `node` - 1
        .test_decl => if (tree.tokens.items(.tag)[main_token + 1] == .string_literal)
            return main_token + 1
        else
            null,
        else => null,
    };
}

pub fn getDeclName(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    const name = tree.tokenSlice(getDeclNameToken(tree, node) orelse return null);
    return switch (tree.nodeTag(node)) {
        .test_decl => name[1 .. name.len - 1],
        else => name,
    };
}

/// Gets a declaration's doc comments. Caller owns returned memory.
pub fn getDocComments(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) !?std.ArrayListUnmanaged([]const u8) {
    const base = tree.nodeMainToken(node);
    const base_kind = tree.nodeTag(node);
    const tokens = tree.tokens.items(.tag);

    switch (base_kind) {
        .root => return try collectDocComments(allocator, tree, 0, true),
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        .container_field_init,
        => {
            if (getDocCommentTokenIndex(tokens, base)) |doc_comment_index|
                return try collectDocComments(allocator, tree, doc_comment_index, false);
        },
        else => {},
    }
    return null;
}

/// Get the first doc comment of a declaration.
fn getDocCommentTokenIndex(tokens: []std.zig.Token.Tag, base_token: Ast.TokenIndex) ?Ast.TokenIndex {
    var idx = base_token;
    if (idx == 0) return null;
    idx -= 1;
    if (tokens[idx] == .keyword_threadlocal and idx > 0) idx -= 1;
    if (tokens[idx] == .string_literal and idx > 1 and tokens[idx - 1] == .keyword_extern) idx -= 1;
    if (tokens[idx] == .keyword_extern and idx > 0) idx -= 1;
    if (tokens[idx] == .keyword_export and idx > 0) idx -= 1;
    if (tokens[idx] == .keyword_inline and idx > 0) idx -= 1;
    if (tokens[idx] == .keyword_pub and idx > 0) idx -= 1;

    // Find first doc comment token
    if (!(tokens[idx] == .doc_comment))
        return null;
    return while (tokens[idx] == .doc_comment) {
        if (idx == 0) break 0;
        idx -= 1;
    } else idx + 1;
}

fn collectDocComments(allocator: std.mem.Allocator, tree: Ast, doc_comments: Ast.TokenIndex, container_doc: bool) !std.ArrayListUnmanaged([]const u8) {
    var lines = std.ArrayListUnmanaged([]const u8){};
    const tokens = tree.tokens.items(.tag);

    var curr_line_tok = doc_comments;
    while (true) : (curr_line_tok += 1) {
        const comm = tokens[curr_line_tok];
        if ((container_doc and comm == .container_doc_comment) or (!container_doc and comm == .doc_comment)) {
            try lines.append(allocator, std.mem.trim(u8, tree.tokenSlice(curr_line_tok)[3..], &std.ascii.whitespace));
        } else break;
    }

    return lines;
}

// http://tools.ietf.org/html/rfc3986#section-2.2
const reserved_chars = &[_]u8{
    '!', '#', '$', '%', '&', '\'',
    '(', ')', '*', '+', ',', ':',
    ';', '=', '?', '@', '[', ']',
};

const reserved_escapes = blk: {
    var escapes: [reserved_chars.len][3]u8 = [_][3]u8{[_]u8{undefined} ** 3} ** reserved_chars.len;

    for (reserved_chars, 0..) |c, i| {
        escapes[i][0] = '%';
        _ = std.fmt.bufPrint(escapes[i][1..], "{X}", .{c}) catch unreachable;
    }
    break :blk escapes;
};

/// Returns a URI from a path, caller owns the memory allocated with `allocator`
pub fn fromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return "";
    const prefix = if (builtin.os.tag == .windows) "file:///" else "file://";

    var buf = std.ArrayListUnmanaged(u8){};
    try buf.appendSlice(allocator, prefix);

    for (path) |char| {
        if (char == std.fs.path.sep) {
            try buf.append(allocator, '/');
        } else if (std.mem.indexOfScalar(u8, reserved_chars, char)) |reserved| {
            try buf.appendSlice(allocator, &reserved_escapes[reserved]);
        } else {
            try buf.append(allocator, char);
        }
    }

    // On windows, we need to lowercase the drive name.
    if (builtin.os.tag == .windows) {
        if (buf.items.len > prefix.len + 1 and
            std.ascii.isAlphabetic(buf.items[prefix.len]) and
            std.mem.startsWith(u8, buf.items[prefix.len + 1 ..], "%3A"))
        {
            buf.items[prefix.len] = std.ascii.toLower(buf.items[prefix.len]);
        }
    }

    return buf.toOwnedSlice(allocator);
}

// --- Compatibility helpers for Node data access ---

/// Get lhs as Node.Index (raw bitcast from data union)
pub fn nodeDataLhs(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    return @enumFromInt(rawPair(tree, node)[0]);
}

/// Get rhs as Node.Index (raw bitcast from data union)
pub fn nodeDataRhs(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    return @enumFromInt(rawPair(tree, node)[1]);
}

/// Get rhs as raw u32
pub fn nodeDataRhsRaw(tree: Ast, node: Ast.Node.Index) u32 {
    return rawPair(tree, node)[1];
}

pub fn rawPair(tree: Ast, node: Ast.Node.Index) [2]u32 {
    const data_ptr: *const Node.Data = &tree.nodes.items(.data)[@intFromEnum(node)];
    return @as(*const [2]u32, @ptrCast(data_ptr)).*;
}

/// Check if a raw Node.Index obtained from rawPair is "present" (not a sentinel).
/// In Zig 0.15, OptionalIndex.none = maxInt(u32). Node index 0 (.root) is valid.
pub fn nodePresent(node: Ast.Node.Index) bool {
    return @intFromEnum(node) != std.math.maxInt(u32);
}
