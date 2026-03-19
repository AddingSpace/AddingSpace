import ir

type
  TagEnum* = enum
    NoStmtTagId
    PassTagId
    ModuleTagId
    StmtsTagId

type
  RgcStmt* = enum
    NoStmt
    PassS = (ord(PassTagId), "pass")
    ModuleS = (ord(ModuleTagId), "module")
    StmtsS = (ord(StmtsTagId), "stmts")

template tagEnum*(c: Cursor): TagEnum = cast[TagEnum](tag(c))

template tagEnum*(c: PackedToken): TagEnum = cast[TagEnum](tag(c))

proc rawTagIsRgcStmt*(raw: TagEnum): bool {.inline.} =
  raw in {PassTagId, ModuleTagId, StmtsTagId}

proc stmtKind*(c: PackedToken): RgcStmt {.inline.} =
  echo "tag: ", tagEnum(c)
  if c.kind == ParLe and rawTagIsRgcStmt(tagEnum(c)):
    result = cast[RgcStmt](tagEnum(c))
  else:
    result = NoStmt

proc stmtKind*(c: Cursor): RgcStmt {.inline.} =
  result = stmtKind(c.load())

# proc stmtKind*()