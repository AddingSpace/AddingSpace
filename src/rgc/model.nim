import ir

type
  TagEnum* = enum
    NoStmtTagId
    PassTagId

type
  RgcStmt* = enum
    NoStmt
    PassS = (ord(PassTagId), "pass")

template tagEnum*(c: Cursor): TagEnum = cast[TagEnum](tag(c))

template tagEnum*(c: PackedToken): TagEnum = cast[TagEnum](tag(c))

proc rawTagIsRgcStmt*(raw: TagEnum): bool {.inline.} =
  raw in {PassTagId}

proc stmtKind*(c: PackedToken): RgcStmt {.inline.} =
  if c.kind == ParLe and rawTagIsRgcStmt(tagEnum(c)):
    result = cast[RgcStmt](tagEnum(c))
  else:
    result = NoStmt

proc stmtKind*(c: Cursor): RgcStmt {.inline.} =
  result = stmtKind(c.load())

# proc stmtKind*()