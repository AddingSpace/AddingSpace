| Tag | Enums | Description |
|-----|-------|-------------|
| `(pass D . . . S)` | RgcStmt | pass declaration |
| `(module D . . S)` | RgcStmt | module declaration |
| `(stmts S*)` | RgcStmt | statement list |
| `(input D T)` | RgcStmt | pass input declaration |
| `(output D T)` | RgcStmt | pass output declaration |
| `(use Y .Y)` | RgcStmt | module usage declaration |
| `(connect X X)` | RgcStmt | resource connection |
| `(raster S*)` | RgcStmt | raster pass body |
| `(compute S*)` | RgcStmt | compute pass body |
| `(copy S*)` | RgcStmt | copy pass body |
| `(shader I Y)` | RgcStmt | shader binding |
| `(image T)` | RgcType | image resource, T is generic param, actually mostly hides imageViews, maybe it also need separated type |
| `(buffer T)` | RgcType | buffer resource of T |
