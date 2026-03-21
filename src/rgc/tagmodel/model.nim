import ".." / ir
import model_tags, tags

export model_tags, tags

proc toTagEnum(raw: TagId): TagEnum {.inline.} =
  if raw.int > 0 and raw.int <= high(TagEnum).int:
    result = cast[TagEnum](raw)
  else:
    result = InvalidTagId

template tagEnum*(c: Cursor): TagEnum = toTagEnum(tag(c))

template tagEnum*(c: PackedToken): TagEnum = toTagEnum(tag(c))

proc stmtKind*(c: PackedToken): RgcStmt {.inline.} =
  let e = tagEnum(c)
  if c.kind == ParLe and rawTagIsRgcStmt(e):
    result = cast[RgcStmt](e)
  else:
    result = NoStmt

proc stmtKind*(c: Cursor): RgcStmt {.inline.} =
  result = stmtKind(c.load())

proc typeKind*(c: PackedToken): RgcType {.inline.} =
  let e = tagEnum(c)
  if c.kind == ParLe and rawTagIsRgcType(e):
    result = cast[RgcType](e)
  else:
    result = NoType

proc typeKind*(c: Cursor): RgcType {.inline.} =
  result = typeKind(c.load())
