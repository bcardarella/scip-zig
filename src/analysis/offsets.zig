const std = @import("std");
const utils = @import("utils.zig");
const Ast = std.zig.Ast;

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Loc = std.zig.Token.Loc;

pub fn tokenToIndex(tree: Ast, token_index: Ast.TokenIndex) usize {
    return tree.tokens.items(.start)[token_index];
}

pub fn tokenToLoc(tree: Ast, token_index: Ast.TokenIndex) Loc {
    const start = tree.tokens.items(.start)[token_index];
    const tag = tree.tokens.items(.tag)[token_index];

    // Many tokens can be determined entirely by their tag.
    if (tag.lexeme()) |lexeme| {
        return .{
            .start = start,
            .end = start + lexeme.len,
        };
    }

    // For some tokens, re-tokenization is needed to find the end.
    var tokenizer: std.zig.Tokenizer = .{
        .buffer = tree.source,
        .index = start,
    };

    // Maybe combine multi-line tokens?
    const token = tokenizer.next();
    // A failure would indicate a corrupted tree.source
    std.debug.assert(token.tag == tag);
    return token.loc;
}

pub fn nodeToLoc(tree: Ast, node: Ast.Node.Index) Loc {
    return .{ .start = tokenToIndex(tree, tree.firstToken(node)), .end = tokenToLoc(tree, utils.lastToken(tree, node)).end };
}

/// Pre-built line offset table for O(log n) index-to-position lookups.
pub const LineIndex = struct {
    /// Byte offset of the start of each line. line_offsets[0] == 0 always.
    line_offsets: []const u32,

    /// Build a LineIndex from source text in O(n).
    pub fn build(allocator: std.mem.Allocator, text: []const u8) !LineIndex {
        var offsets_list = std.ArrayListUnmanaged(u32){};
        try offsets_list.append(allocator, 0);
        for (text, 0..) |c, i| {
            if (c == '\n') {
                try offsets_list.append(allocator, @intCast(i + 1));
            }
        }
        return .{ .line_offsets = try offsets_list.toOwnedSlice(allocator) };
    }

    /// Convert a byte index to a Position via O(log n) binary search.
    pub fn indexToPosition(self: LineIndex, index: usize) Position {
        // Binary search for the line containing this index
        var lo: usize = 0;
        var hi: usize = self.line_offsets.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_offsets[mid] <= index) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // lo is now the first line whose offset is > index, so the line is lo - 1
        const line = lo - 1;
        const character = index - self.line_offsets[line];
        return .{
            .line = @intCast(line),
            .character = @intCast(character),
        };
    }
};

/// Convert a token to a Range using a pre-built LineIndex (O(log n) per endpoint).
pub fn tokenToRangeIndexed(tree: Ast, token_index: Ast.TokenIndex, line_index: LineIndex) Range {
    const loc = tokenToLoc(tree, token_index);
    return .{
        .start = line_index.indexToPosition(loc.start),
        .end = line_index.indexToPosition(loc.end),
    };
}

/// Convert a node to a Range using a pre-built LineIndex (O(log n) per endpoint).
pub fn nodeToRangeIndexed(tree: Ast, node: Ast.Node.Index, line_index: LineIndex) Range {
    const loc = nodeToLoc(tree, node);
    return .{
        .start = line_index.indexToPosition(loc.start),
        .end = line_index.indexToPosition(loc.end),
    };
}
