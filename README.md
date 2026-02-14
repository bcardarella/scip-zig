# scip-zig

[SCIP](https://github.com/sourcegraph/scip) indexer for [Zig](https://ziglang.org). Experimental.

Requires Zig 0.15.

## Supported features

- [x] Globals
- [x] Multiple packages (`--pkg` flag, cross-package symbol resolution)
- [x] Imports (`@import` with symbol linking)
- [x] Namespaced declarations (structs, enums, unions, error sets)
- [x] Functions
  - [x] Parameters
  - [x] Return types
  - [x] Bodies
- [x] Locals
  - [x] With explicit typing
  - [x] With inferred typing
- [x] `comptime` expressions
- [x] Control flow
  - [x] `if`/`else` with payload captures
  - [x] `while` with payload captures
  - [x] `for` with multiple captures
  - [x] `switch`/`catch`/`defer`/`errdefer`
  - [x] Labeled blocks
- [x] Type expressions
  - [x] Pointer types (`*T`, `[*]T`, `[]T`)
  - [x] Optional types (`?T`)
  - [x] Error unions (`E!T`)
  - [x] Array types (`[N]T`, `[N:S]T`)
- [x] Error values (`error.Name`)
- [x] Enum literals (`.foo`)
- [x] Builtin calls (`@intFromEnum`, etc.)
- [x] Test declarations
- [x] Struct literal field references
- [x] Type definition relationships (through `?T`, `*T`, `[]T`, `E!T`)
- [x] Write access tracking (assignments, definitions)
- [x] Doc comment extraction
- [x] Signature documentation
- [x] Deterministic output ordering
- [x] Easy integration into `build.zig` / CI

## Installing

To install `scip-zig`, simply `git clone` this repository and run `zig build`; you'll find the indexer in `zig-out/bin`!

## Usage

```bash
# To index std
scip-zig --root-path /path/to/zig --pkg std /path/to/zig/lib/std/std.zig --root-pkg std
src code-intel upload -github-token=$(cat tok) -file=index.scip
```

For example, let's index this very repo:

```bash
zig-out/bin/scip-zig --root-path $(pwd) --pkg scip-zig $(pwd)/src/main.zig --root-pkg scip-zig
scip convert --from index.scip
src code-intel upload -github-token=$(cat tok) -file=index.scip
```

## build.zig Integration

Add scip-zig as a dependency to your project:

```bash
zig fetch --save git+https://github.com/niclas-overby/scip-zig
```

Then add an `index` step to your `build.zig`:

```zig
const scip_dep = b.dependency("scip-zig", .{});
const scip_zig = @import("scip-zig");
const index_run = scip_zig.addIndexStep(b, scip_dep, .{
    .root_source_file = b.path("src/main.zig"),
    .package_name = "my-project",
});
const index_step = b.step("index", "Generate SCIP index");
index_step.dependOn(&index_run.step);
```

If your project has additional packages (e.g. dependencies you want indexed), pass them via `extra_packages`:

```zig
const index_run = scip_zig.addIndexStep(b, scip_dep, .{
    .root_source_file = b.path("src/main.zig"),
    .package_name = "my-project",
    .extra_packages = &.{
        .{ .name = "my-lib", .root_source_file = b.dependency("my-lib", .{}).path("src/root.zig") },
    },
});
```

Then generate the index with:

```bash
zig build index
```

## CI Integration

Add SCIP indexing to your GitHub Actions workflow:

```yaml
- name: Generate SCIP index
  run: zig build index
- name: Upload to Sourcegraph
  run: src code-intel upload -file=index.scip
```
