## This file represent RGIR - format that basicly nimony's NIF,
## generated from nimony/src/lib code with claude opus 4.6 and gpt 5.4
## This code remains largely identical to the actual nimony source
## (primarily a copy-paste with redundant functions stripped out), which should minimize errors.
## Portions derived from nimony, Copyright (c) 2024 Andreas Rumpf, MIT License.
## Nevertheless, as this is LLM-generated code, the possibility of
## inaccuracies should still be considered.

import std/[assertions, hashes]
import bitabs, lineinfos

type
  TokenKind* = enum
    EofToken, DotToken, Ident, Symbol, SymbolDef,
    StringLit, IntLit, ParLe, ParRi

  StrId* = distinct uint32
  SymId* = distinct uint32
  IntId* = distinct uint32
  TagId* = distinct uint32

proc `==`*(a, b: StrId): bool {.borrow.}
proc `==`*(a, b: SymId): bool {.borrow.}
proc `==`*(a, b: IntId): bool {.borrow.}
proc `==`*(a, b: TagId): bool {.borrow.}

proc hash*(x: StrId): Hash {.borrow.}
proc hash*(x: SymId): Hash {.borrow.}
proc hash*(x: IntId): Hash {.borrow.}
proc hash*(x: TagId): Hash {.borrow.}

type
  Literals* = object
    man*: LineInfoManager
    files*: BiTable[FileId, string]
    tags*: BiTable[TagId, string]
    syms*: BiTable[SymId, string]
    strings*: BiTable[StrId, string]
    integers*: BiTable[IntId, int64]

proc createLiterals*(): Literals = Literals()

proc registerTag*(lit: var Literals; tag: string): TagId =
  lit.tags.getOrIncl(tag)

type
  PackedToken* = object
    x: uint32
    info*: PackedLineInfo

const
  TokenKindBits = 4'u32
  TokenKindMask = (1'u32 shl TokenKindBits) - 1'u32

template kind*(n: PackedToken): TokenKind = cast[TokenKind](n.x and TokenKindMask)
template uoperand*(n: PackedToken): uint32 = (n.x shr TokenKindBits)

template toX(k: TokenKind; operand: uint32): uint32 =
  uint32(k) or (operand shl TokenKindBits)

proc parLeToken*(t: TagId; info = NoLineInfo): PackedToken {.inline.} =
  PackedToken(x: toX(ParLe, uint32(t)), info: info)

proc parRiToken*(info = NoLineInfo): PackedToken {.inline.} =
  PackedToken(x: toX(ParRi, 0'u32), info: info)

proc dotToken*(info = NoLineInfo): PackedToken {.inline.} =
  PackedToken(x: toX(DotToken, 0'u32), info: info)

proc identToken*(s: StrId; info = NoLineInfo): PackedToken {.inline.} =
  PackedToken(x: toX(Ident, uint32(s)), info: info)

proc strToken*(s: StrId; info = NoLineInfo): PackedToken {.inline.} =
  PackedToken(x: toX(StringLit, uint32(s)), info: info)

proc symToken*(s: SymId; info = NoLineInfo): PackedToken {.inline.} =
  PackedToken(x: toX(Symbol, uint32(s)), info: info)

proc symdefToken*(s: SymId; info = NoLineInfo): PackedToken {.inline.} =
  PackedToken(x: toX(SymbolDef, uint32(s)), info: info)

proc intToken*(id: IntId; info = NoLineInfo): PackedToken {.inline.} =
  PackedToken(x: toX(IntLit, uint32(id)), info: info)

proc litId*(n: PackedToken): StrId {.inline.} =
  StrId(n.uoperand)

proc symId*(n: PackedToken): SymId {.inline.} =
  SymId(n.uoperand)

proc intId*(n: PackedToken): IntId {.inline.} =
  IntId(n.uoperand)

proc tagId*(n: PackedToken): TagId {.inline.} =
  TagId(n.uoperand)

proc tag*(n: PackedToken): TagId {.inline.} =
  if n.kind == ParLe: n.tagId
  else: TagId(0)

type
  VmTokenStorage = seq[PackedToken]
  Storage = ptr UncheckedArray[PackedToken]

type
  Cursor*[Vm: static bool] = object
    when Vm:
      data: VmTokenStorage
      pos: int
    else:
      p: ptr PackedToken
    rem: int

  RtCursor* = Cursor[false]
  VmCursor* = Cursor[true]

proc fromBuffer*(x: openArray[PackedToken]): RtCursor {.inline.} =
  RtCursor(p: (if x.len > 0: addr(x[0]) else: nil), rem: x.len)

proc fromBufferVm*(x: openArray[PackedToken]): VmCursor {.inline.} =
  result = VmCursor(data: newSeqOfCap[PackedToken](max(x.len, 0)), rem: x.len)
  for item in x:
    result.data.add item

proc load*(c: Cursor): PackedToken {.inline.} =
  assert c.rem > 0
  when c.Vm:
    c.data[c.pos]
  else:
    assert c.p != nil
    c.p[]

proc kind*(c: Cursor): TokenKind {.inline.} = c.load.kind
proc info*(c: Cursor): PackedLineInfo {.inline.} = c.load.info
proc litId*(c: Cursor): StrId {.inline.} = c.load.litId
proc symId*(c: Cursor): SymId {.inline.} = c.load.symId
proc intId*(c: Cursor): IntId {.inline.} = c.load.intId
proc tagId*(c: Cursor): TagId {.inline.} = c.load.tagId
proc tag*(c: Cursor): TagId {.inline.} = c.load.tag
proc uoperand*(c: Cursor): uint32 {.inline.} = c.load.uoperand

proc cursorIsNil*(c: Cursor): bool {.inline.} =
  when c.Vm:
    c.data.len == 0 and c.pos == 0 and c.rem == 0
  else:
    c.p == nil

proc inc*(c: var Cursor) {.inline.} =
  assert c.rem > 0
  when c.Vm:
    inc c.pos
  else:
    c.p = cast[ptr PackedToken](cast[uint](c.p) + sizeof(PackedToken).uint)
  dec c.rem

proc `+!`*(c: Cursor; diff: int): Cursor {.inline.} =
  assert diff <= c.rem
  when c.Vm:
    result = Cursor(data: c.data, pos: c.pos + diff, rem: c.rem - diff)
  else:
    result = Cursor(
      p: cast[ptr PackedToken](cast[uint](c.p) + diff.uint * sizeof(PackedToken).uint),
      rem: c.rem - diff)

proc skip*(c: var Cursor) =
  if c.kind == ParLe:
    var nested = 0
    while true:
      inc c
      if c.kind == ParRi:
        if nested == 0: break
        dec nested
      elif c.kind == ParLe: inc nested
  inc c

proc skipToEnd*(c: var Cursor) =
  var nested = 0
  while true:
    if c.kind == ParRi:
      if nested == 0: inc c; break
      dec nested
    elif c.kind == ParLe: inc nested
    inc c

proc skipUntilEnd*(c: var Cursor) =
  var nested = 0
  while true:
    if c.kind == ParRi:
      if nested == 0: break
      dec nested
    elif c.kind == ParLe: inc nested
    inc c

proc span*(c: Cursor): int =
  result = 0
  var c = c
  if c.kind == ParLe:
    var nested = 0
    while true:
      inc c
      inc result
      if c.kind == ParRi:
        if nested == 0: break
        dec nested
      elif c.kind == ParLe: inc nested
  if c.rem > 0:
    inc c
    inc result

proc firstSon*(n: Cursor): Cursor {.inline.} =
  result = n
  inc result

proc isLastSon*(n: Cursor): bool =
  var n = n
  skip n
  n.kind == ParRi

type
  TokenBuf*[Vm: static bool] = object
    when Vm:
      data: VmTokenStorage
    else:
      data: Storage
    len, cap, readers: int
  
  RtTokenBuf* = TokenBuf[false]
  VmTokenBuf* = TokenBuf[true]

proc `=copy`[Vm: static bool](dest: var TokenBuf[Vm]; src: TokenBuf[Vm]) {.error.}
proc `=destroy`[Vm: static bool](dest: TokenBuf[Vm]) {.inline.} =
  when dest.Vm:
    discard
  else:
    if dest.data != nil: dealloc(dest.data)

proc createTokenBuf*(cap = 100): RtTokenBuf =
  RtTokenBuf(data: cast[Storage](alloc(sizeof(PackedToken) * cap)), len: 0, cap: cap)

proc createTokenBufVm*(cap = 100): VmTokenBuf =
  VmTokenBuf(data: newSeqOfCap[PackedToken](max(cap, 0)), len: 0, cap: cap)

proc isMutable(b: TokenBuf): bool {.inline.} = b.cap >= 0

proc freeze*(b: var TokenBuf) {.inline.} =
  if isMutable(b): b.cap = -(b.cap + 1)

proc thaw*(b: var TokenBuf) =
  if not isMutable(b): b.cap = -(b.cap + 1)

proc len*(b: TokenBuf): int {.inline.} = b.len

proc `[]`*(b: TokenBuf; i: int): PackedToken {.inline.} =
  assert i >= 0 and i < b.len
  b.data[i]

proc `[]`*(b: var TokenBuf; i: int): var PackedToken {.inline.} =
  assert i >= 0 and i < b.len
  result = b.data[i]

proc `[]=`*(b: var TokenBuf; i: int; val: PackedToken) {.inline.} =
  assert i >= 0 and i < b.len
  b.data[i] = val

proc add*(b: var TokenBuf; item: PackedToken) {.inline.} =
  assert isMutable(b), "attempt to mutate frozen TokenBuf"
  when b.Vm:
    if b.len >= b.cap:
      b.cap = max(b.cap div 2 + b.cap, 8)
    b.data.add item
  else:
    if b.len >= b.cap:
      b.cap = max(b.cap div 2 + b.cap, 8)
      b.data = cast[Storage](realloc(b.data, sizeof(PackedToken) * b.cap))
    b.data[b.len] = item
  inc b.len

proc shrink*(b: var TokenBuf; newLen: int) =
  assert isMutable(b), "attempt to mutate frozen TokenBuf"
  assert newLen >= 0 and newLen <= b.len
  when b.Vm:
    b.data.setLen(newLen)
  b.len = newLen

iterator items*(b: TokenBuf): PackedToken =
  for i in 0 ..< b.len:
    yield b.data[i]

proc add*(dest: var TokenBuf; src: TokenBuf) =
  for t in items(src): dest.add t

proc addParLe*(dest: var TokenBuf; tag: TagId; info = NoLineInfo) =
  dest.add parLeToken(tag, info)

proc addParRi*(dest: var TokenBuf) =
  dest.add parRiToken()

proc addDotToken*(dest: var TokenBuf) =
  dest.add dotToken()

proc addStrLit*(dest: var TokenBuf; lit: var Literals; s: string; info = NoLineInfo) =
  dest.add strToken(lit.strings.getOrIncl(s), info)

proc addIntLit*(dest: var TokenBuf; lit: var Literals; i: int64; info = NoLineInfo) =
  dest.add intToken(lit.integers.getOrIncl(i), info)

proc addIdent*(dest: var TokenBuf; lit: var Literals; s: string; info = NoLineInfo) =
  dest.add identToken(lit.strings.getOrIncl(s), info)

proc addSymUse*(dest: var TokenBuf; s: SymId; info = NoLineInfo) =
  dest.add symToken(s, info)

proc addSymDef*(dest: var TokenBuf; s: SymId; info = NoLineInfo) =
  dest.add symdefToken(s, info)

template buildTree*(dest: var TokenBuf; tag: TagId; info: PackedLineInfo; body: untyped) =
  dest.add parLeToken(tag, info)
  body
  dest.add parRiToken()

template buildTree*(dest: var TokenBuf; tag: TagId; body: untyped) =
  dest.add parLeToken(tag)
  body
  dest.add parRiToken()

proc beginRead*(b: var RtTokenBuf): RtCursor =
  if b.readers == 0: freeze(b)
  inc b.readers
  RtCursor(p: (if b.len > 0: addr(b.data[0]) else: nil), rem: b.len)

proc beginRead*(b: var VmTokenBuf): VmCursor =
  if b.readers == 0: freeze(b)
  inc b.readers
  VmCursor(data: b.data, rem: b.len)

proc endRead*(b: var TokenBuf) =
  assert b.readers > 0, "unpaired endRead"
  dec b.readers
  if b.readers == 0: thaw(b)

proc cursorAt*(b: var RtTokenBuf; i: int): RtCursor {.inline.} =
  assert i >= 0 and i < b.len
  if b.readers == 0: freeze(b)
  inc b.readers
  RtCursor(p: (if i < b.len: addr b.data[i] else: nil), rem: b.len - i)

proc cursorAt*(b: var VmTokenBuf; i: int): VmCursor {.inline.} =
  assert i >= 0 and i < b.len
  if b.readers == 0: freeze(b)
  inc b.readers
  VmCursor(data: b.data, pos: i, rem: b.len - i)

proc add*(dest: var TokenBuf; c: Cursor) =
  dest.add c.load

proc addSubtree*(dest: var TokenBuf; c: Cursor) =
  assert c.kind != ParRi, "cursor at end?"
  if c.kind != ParLe:
    dest.add c.load
  else:
    var c = c
    var nested = 0
    while true:
      let item = c.load
      dest.add item
      if item.kind == ParRi:
        dec nested
        if nested == 0: break
      elif item.kind == ParLe: inc nested
      inc c

proc takeToken*(buf: var TokenBuf; n: var Cursor) {.inline.} =
  buf.add n
  inc n

proc takeTree*(dest: var TokenBuf; n: var Cursor) =
  if n.kind != ParLe:
    dest.add n
    inc n
  else:
    var nested = 0
    while true:
      dest.add n
      case n.kind
      of ParLe: inc nested
      of ParRi:
        dec nested
        if nested == 0:
          inc n
          break
      of EofToken:
        raiseAssert "expected ')', but EOF reached"
      else: discard
      inc n

const
  ControlChars* = {'(', ')', '[', ']', '{', '}', '~', '#', '\'', '"', '\\', ':'}

type
  Builder* = object
    buf: string
    nesting: int

proc openBuilder*(sizeHint = 256): Builder =
  Builder(buf: newStringOfCap(sizeHint))

proc extract*(b: sink Builder): string =
  assert b.nesting == 0, "unpaired parens: " & $b.nesting
  move b.buf

proc addBuilder*(b: var Builder; other: sink Builder) =
  let fragment = extract(other)
  if fragment.len == 0:
    return
  if b.nesting == 0:
    b.buf.add fragment
    return

  b.buf.add '\n'
  for i in 1..b.nesting:
    b.buf.add ' '
  for c in fragment:
    b.buf.add c
    if c == '\n':
      for i in 1..b.nesting:
        b.buf.add ' '

proc addSep(b: var Builder) =
  if b.buf.len > 0 and b.buf[^1] notin {'\n', ' '} and b.nesting != 0:
    b.buf.add ' '

proc escape(b: var Builder; c: char) =
  const HexChars = "0123456789ABCDEF"
  b.buf.add '\\'
  b.buf.add HexChars[int(c) shr 4 and 0xF]
  b.buf.add HexChars[int(c) and 0xF]

template needsEscape(c: char): bool = c < ' ' or c in ControlChars

proc addEscapedWord(b: var Builder; s: string; allowDot = false) =
  for i, c in s:
    if i == 0 and c in {'.', '0'..'9', '+', '-', '~'}:
      b.escape c
    elif c == '.' and allowDot:
      b.buf.add c
    elif c == ' ' or c.needsEscape:
      b.escape c
    else:
      b.buf.add c

proc addIdent*(b: var Builder; s: string) =
  addSep b
  b.addEscapedWord s

proc addSymbol*(b: var Builder; s: string) =
  addSep b
  b.addEscapedWord s, allowDot = true

proc addSymbolDef*(b: var Builder; s: string) =
  addSep b
  b.buf.add ':'
  b.addEscapedWord s, allowDot = true

proc addStrLit*(b: var Builder; s: string) =
  addSep b
  b.buf.add '"'
  for c in s:
    if c.needsEscape: b.escape c
    else: b.buf.add c
  b.buf.add '"'

proc addIntLit*(b: var Builder; i: int64) =
  addSep b
  if i >= 0: b.buf.add '+'
  b.buf.add $i

proc addEmpty*(b: var Builder; count = 1) =
  addSep b
  for i in 1..count: b.buf.add '.'

proc addKeyw*(b: var Builder; keyw: string) =
  addSep b
  b.buf.add '('
  b.buf.add keyw
  b.buf.add ')'

proc addTree*(b: var Builder; kind: string) =
  if b.nesting > 0:
    b.buf.add '\n'
    for i in 1..b.nesting: b.buf.add ' '
  b.buf.add '('
  b.buf.add kind
  inc b.nesting

proc endTree*(b: var Builder) =
  dec b.nesting
  var i = b.buf.len - 1
  while i >= 0 and b.buf[i] in {' ', '\n'}: dec i
  b.buf.setLen i + 1
  b.buf.add ')'

template withTree*(b: var Builder; kind: string; body: untyped) =
  addTree b, kind
  body
  endTree b

proc addLineInfo*(b: var Builder; col, line: int32; file = "") =
  addSep b
  b.buf.add $col
  if line != 0 or file.len > 0:
    b.buf.add ','
    b.buf.add $line
  if file.len > 0:
    b.buf.add ','
    for c in file:
      if c.needsEscape: b.escape c
      else: b.buf.add c

const
  ControlCharsOrWhite = ControlChars + {' ', '\n', '\t', '\r'}

type
  TextParser = object
    input: string
    pos: int

proc atEnd(p: TextParser): bool {.inline.} = p.pos >= p.input.len
proc peek(p: TextParser): char {.inline.} = p.input[p.pos]

proc skipWhitespace(p: var TextParser) =
  while not p.atEnd and p.peek in {' ', '\n', '\t', '\r'}:
    inc p.pos

proc readHexChar(p: var TextParser): char =
  var output = 0
  for shift in [4, 0]:
    if p.atEnd: break
    let c = p.peek; inc p.pos
    case c
    of '0'..'9': output = output or ((ord(c) - ord('0')) shl shift)
    of 'A'..'F': output = output or ((ord(c) - ord('A') + 10) shl shift)
    else: discard
  char(output)

proc readWord(p: var TextParser): string =
  result = ""
  while not p.atEnd and p.peek notin ControlCharsOrWhite:
    if p.peek == '\\':
      inc p.pos
      result.add p.readHexChar()
    else:
      result.add p.peek; inc p.pos

proc readString(p: var TextParser): string =
  result = ""
  inc p.pos # skip "
  while not p.atEnd and p.peek != '"':
    if p.peek == '\\':
      inc p.pos
      result.add p.readHexChar()
    else:
      result.add p.peek; inc p.pos
  if not p.atEnd: inc p.pos # skip "

proc readInt(p: var TextParser): int32 =
  result = 0
  var neg = false
  if not p.atEnd and p.peek == '~':
    neg = true; inc p.pos
  while not p.atEnd and p.peek in {'0'..'9'}:
    result = result * 10 + int32(ord(p.peek) - ord('0'))
    inc p.pos
  if neg: result = -result

proc handleLineInfo(p: var TextParser; lit: var Literals): PackedLineInfo =
  let col = p.readInt()
  var line: int32 = 0
  var filename = ""
  if not p.atEnd and p.peek == ',':
    inc p.pos
    line = p.readInt()
    if not p.atEnd and p.peek == ',':
      inc p.pos
      while not p.atEnd and p.peek notin ControlCharsOrWhite:
        if p.peek == '\\':
          inc p.pos; filename.add p.readHexChar()
        else:
          filename.add p.peek; inc p.pos
  if filename.len > 0:
    lit.man.pack(lit.files.getOrIncl(filename), line, col)
  elif line != 0 or col != 0:
    lit.man.pack(NoFile, line, col)
  else:
    NoLineInfo

proc parse*(input: string; lit: var Literals; dest: var TokenBuf) =
  var p = TextParser(input: input, pos: 0)
  while true:
    p.skipWhitespace()
    if p.atEnd: break

    var info = NoLineInfo
    if p.peek in {'0'..'9', '~', ','}:
      info = p.handleLineInfo(lit)
      p.skipWhitespace()
      if p.atEnd: break

    case p.peek
    of '(':
      inc p.pos
      dest.add parLeToken(lit.tags.getOrIncl(p.readWord()), info)
    of ')':
      inc p.pos
      dest.add parRiToken(info)
    of '.':
      inc p.pos
      dest.add dotToken(info)
    of '"':
      dest.add strToken(lit.strings.getOrIncl(p.readString()), info)
    of ':':
      inc p.pos
      dest.add symdefToken(lit.syms.getOrIncl(p.readWord()), info)
    of '+', '-':
      let startPos = p.pos
      inc p.pos
      if not p.atEnd and p.peek in {'0'..'9'}:
        p.pos = startPos
        let neg = p.peek == '-'
        inc p.pos
        var num: int64 = 0
        while not p.atEnd and p.peek in {'0'..'9'}:
          num = num * 10 + int64(ord(p.peek) - ord('0'))
          inc p.pos
        if neg: num = -num
        dest.add intToken(lit.integers.getOrIncl(num), info)
      else:
        p.pos = startPos
        dest.add identToken(lit.strings.getOrIncl(p.readWord()), info)
    else:
      let word = p.readWord()
      if word.len == 0: continue
      if '.' in word:
        dest.add symToken(lit.syms.getOrIncl(word), info)
      else:
        dest.add identToken(lit.strings.getOrIncl(word), info)

proc addSep(result: var string) =
  if result.len > 0 and result[^1] notin {'\n', ' ', '('}:
    result.add ' '

proc emitLineInfo(result: var string; lit: Literals; info: PackedLineInfo) =
  if not info.isValid: return
  let raw = lit.man.unpack(info)
  result.addSep()
  result.add $raw.col
  if raw.line != 0 or raw.file.isValid:
    result.add ','
    result.add $raw.line
  if raw.file.isValid:
    result.add ','
    result.add lit.files[raw.file]

proc toString*(tree: openArray[PackedToken]; lit: Literals;
               showLineInfo = false): string =
  result = ""
  var nesting = 0
  for n in 0 ..< tree.len:
    let k = tree[n].kind
    if showLineInfo and tree[n].info.isValid and k != ParRi:
      emitLineInfo(result, lit, tree[n].info)
    case k
    of DotToken:
      result.addSep()
      result.add '.'
    of Ident:
      result.addSep()
      result.add lit.strings[tree[n].litId]
    of Symbol:
      result.addSep()
      result.add lit.syms[tree[n].symId]
    of SymbolDef:
      result.addSep()
      result.add ':'
      result.add lit.syms[tree[n].symId]
    of StringLit:
      result.addSep()
      result.add '"'
      result.add lit.strings[tree[n].litId]
      result.add '"'
    of IntLit:
      result.addSep()
      let val = lit.integers[tree[n].intId]
      if val >= 0: result.add '+'
      result.add $val
    of ParLe:
      if nesting > 0:
        result.add '\n'
        for i in 1..nesting: result.add ' '
      result.add '('
      result.add lit.tags[tree[n].tagId]
      inc nesting
    of ParRi:
      dec nesting
      result.add ')'
    of EofToken: discard

proc toString*(b: TokenBuf; lit: Literals; showLineInfo = false): string =
  if b.len == 0:
    return ""
  when b.Vm:
    toString(b.data.toOpenArray(0, b.len - 1), lit, showLineInfo)
  else:
    toString(toOpenArray(b.data, 0, b.len - 1), lit, showLineInfo)

proc toString*(c: Cursor; lit: Literals; showLineInfo = false): string =
  let count = span(c)
  if count == 0:
    return ""
  when c.Vm:
    toString(c.data.toOpenArray(c.pos, c.pos + count - 1), lit, showLineInfo)
  else:
    toString(toOpenArray(cast[ptr UncheckedArray[PackedToken]](c.p), 0, count - 1),
             lit, showLineInfo)

proc `$`*(c: Cursor): string =
  let t = c.load
  case t.kind
  of ParLe: "(" & $t.uoperand
  of ParRi: ")"
  of DotToken: "."
  of Ident: "id:" & $t.uoperand
  of Symbol: "sym:" & $t.uoperand
  of SymbolDef: "def:" & $t.uoperand
  of StringLit: "str:" & $t.uoperand
  of IntLit: "int:" & $t.uoperand
  of EofToken: "<eof>"

when isMainModule:
  var b = openBuilder()
  b.addLineInfo(0, 1, "main_render.rgc")
  b.withTree "pass":
    b.addSymbolDef "lighting.1"
    b.addLineInfo(2, 2, "main_render.rgc")
    b.withTree "out":
      b.addSymbolDef "hdr.2"
      b.withTree "Image":
        b.addIdent "RGBA16F"
    b.addLineInfo(4, 4, "main_render.rgc")
    b.withTree "raster":
      b.withTree "shader":
        b.addIdent "lightingShader"
  let text = b.extract()
  echo text
  echo ""

  var lit = createLiterals()
  var buf = createTokenBuf()
  parse(text, lit, buf)
  echo buf.toString(lit)
  echo ""
  echo buf.toString(lit, showLineInfo = true)

  # Round-trip
  var lit2 = createLiterals()
  var buf2 = createTokenBuf()
  parse(buf.toString(lit, showLineInfo = true), lit2, buf2)
  echo ""
  echo buf2.toString(lit2)
