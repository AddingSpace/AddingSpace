## Compile dsl to rgir
import ir, sem, bitabs
import std/[macros, macrocache]

const mcRgirCode = CacheSeq"rgc.rgirCode" # generated rgirCode

type
  Modifier = enum
    Dyn
    Pub

  IrBuilder = object
    dest: Builder
    passType: string
    scopeDepth: int

proc parseSignature(b: var Builder, n: NimNode) =
  var modifiers: set[Modifier] = {}
  var node = n
  while node.kind == nnkCommand:
    case node[0].strVal
    of "dyn":
      if Pub in modifiers: raiseAssert "Invalid order, expected: dyn pub name"
      if Dyn in modifiers: raiseAssert "Duplicate `dyn`"
      modifiers.incl Dyn
    of "pub":
      if Pub in modifiers: raiseAssert "Duplicate `pub`"
      modifiers.incl Pub
    else:
      raiseAssert "Unknown modifier: " & node[0].strVal
    node = node[1]
  assert node.kind == nnkIdent, "Specify the name"

  b.addSymbolDef node.strVal

  if Dyn in modifiers: b.addIdent "dyn"
  else: b.addEmpty()

  if Pub in modifiers: b.addIdent "pub"
  else: b.addEmpty()

proc parseCommand(b: var IrBuilder, n: NimNode) =
  assert n.kind == nnkCommand
  case n[0].strVal
  of "input", "output":
    assert b.scopeDepth == 0
    b.dest.withTree n[0].strVal:
      b.dest.addIdent n[1].strVal
      var s = n[2]
      assert s.kind == nnkStmtList
      assert s.len == 1

      case s[0].kind
      of nnkBracketExpr:
        b.dest.addIdent s[0][0].strVal
        b.dest.addIdent s[0][1].strVal # TODO: in fact it can be some tree...
      of nnkIdent:
        b.dest.addIdent s[0].strVal
        b.dest.addEmpty()
      else: raiseAssert "Unsupported node kind in input/output command"
  of "shader":
    assert b.scopeDepth > 0
    b.dest.withTree "shader":
      b.dest.addIdent "fragment"
      b.dest.addIdent n[1].strVal
  of "use":
    assert b.scopeDepth == 0
    b.dest.withTree "use":
      b.dest.addIdent n[1].strVal
  else: raiseAssert "Invalid command"

proc parseStmt(b: var IrBuilder, n: NimNode)

proc parseCall(b: var IrBuilder, n: NimNode) =
  assert n.kind == nnkCall
  case n[0].strVal
  of "raster":
    inc b.scopeDepth
    b.passType = "render"
    for i in n[1]: parseStmt(b, i)
    dec b.scopeDepth
  else: discard

proc parseStmt(b: var IrBuilder, n: NimNode) =
  case n.kind
  of nnkCommand: parseCommand(b, n)
  of nnkCall: parseCall(b, n)
  else: discard

proc passOrModule*(signature: NimNode, code: NimNode, node: string) =
  var b = openBuilder()
  
  b.withTree node:
    b.parseSignature(signature)
    var stmts = IrBuilder(dest: openBuilder())

    stmts.dest.withTree "stmts":
      for i in code:
        parseStmt(stmts, i)

    if stmts.passType.len == 0: b.addEmpty()
    else: b.addIdent stmts.passType
    b.addBuilder(stmts.dest)

  # echo b.extract()
  # echo treeRepr(code)
  mcRgirCode.add newStrLitNode(b.extract())

macro pass*(signature: untyped, code: untyped) =
  passOrModule(signature, code, "pass")

macro module*(signature: untyped, code: untyped) =
  passOrModule(signature, code, "module")

macro initGraph*(name: untyped) =
  var lit = createLiterals()
  var buf = createTokenBufVm()
  var rgir = ""
  for i in mcRgirCode:
    echo "i: ", i
    rgir.add i.strVal
  
  # echo "RGIR DUMP: ", rgir
  buf.addParLe lit.tags.getOrIncl("stmts")
  parse(rgir, lit, buf)
  buf.addParRi() # end of stmts
  when defined(rgc.dumpParsedRgir):
    echo "RGIR:"
    echo beginRead(buf).toString(lit)

  var sem = SemContext[true](lit: lit)
  semcheck(sem, buf)


when isMainModule:
  pass pub mypass:
    input  src: Image[RGBA16F]
    output dst: Image[RGBA16F]

    raster:
      shader lightingShader
  
  module myModule:
    use mypass

  initGraph(myModule)
