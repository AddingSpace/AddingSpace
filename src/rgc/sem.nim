import ir, bitabs, lineinfos, types
import tagmodel/model
import std/[tables, deques, strutils]

type
  NodeKind = enum
    Module
    Pass
    Resource
  
  Node = object
    kind: NodeKind
    s: SymId
  
  Phase = enum
    SymbolResolution
    GraphGeneration

  SemContext*[Vm: static bool] = object
    when Vm:
      dest*: VmTokenBuf
      types: VmKnownTypes
    else:
      dest*: RtTokenBuf
      types: RtKnownTypes

    lit*: Literals

    graph*: Table[Node, seq[Node]]
    # node(module) Main
    #   <- node(pass) Render1
    # 
    # node(pass) Render1:
    #   <- node(resource) Image1
    #
    # node(resource) Image1:
    #   <- node(pass) Render2
    #
    # node(pass) Render2:
    #   -> node(resource) Image1

    # I.e we need to invert arrows (only one direction allowed):
    # node(pass) Render2:
    #   <- node(resource) Image1
    # to
    # node(resource) Image1:
    #   <- node(pass) Render2
    currentNode: Node
    exported*: Table[SymId, FileId] # exported node to it's file
    currentPhase*: Phase
    toplevelScope: seq[(string, SymId)]
    nodes: Table[SymId, Node]

proc passNode(s: SymId): Node = Node(kind: Pass, s: s)
proc moduleNode(s: SymId): Node = Node(kind: Module, s: s)
proc resourceNode(s: SymId): Node = Node(kind: Resource, s: s)

proc lookupSym(c: SemContext, name: string): SymId =
  for (n, sym) in c.toplevelScope:
    if cmpIgnoreStyle(n, name) == 0:
      return sym
  raiseAssert "Undefined: " & name

proc skipParRi*(n: var Cursor) =
  assert n.kind == ParRi
  inc n

proc take(c: var SemContext, n: var Cursor) {.inline.} =
  if c.currentPhase == SymbolResolution:
    c.dest.add n.load
  inc n

proc takeParRi(c: var SemContext, n: var Cursor) {.inline.} =
  assert n.kind == ParRi
  if c.currentPhase == SymbolResolution:
    c.dest.addParRi()
  inc n

proc takeSkip(c: var SemContext, n: var Cursor) {.inline.} =
  if c.currentPhase == SymbolResolution:
    c.dest.takeTree(n)
  else:
    skip n

proc semStmt*(c: var SemContext, n: var Cursor) =
  case n.stmtKind
  of PassS:
    c.take n # (pass
    c.currentNode = passNode(n.symId)
    if c.currentPhase == SymbolResolution:
      c.toplevelScope.add (c.lit.syms[n.symId], n.symId)
      c.nodes[n.symId] = c.currentNode
    c.take n # :name
    assert n.kind == DotToken # dyn pass is not supported
    c.take n # .
    if n.kind == Ident and c.lit.strings[n.litId] == "pub":
      c.exported[c.currentNode.s] = FileId(0) # dummy file currently. TODO: implement
    c.take n # pub
    c.take n # passKind
    semStmt c, n
    c.takeParRi n
  of ModuleS:
    c.take n # (module
    c.currentNode = moduleNode(n.symId)
    if c.currentPhase == SymbolResolution:
      c.toplevelScope.add (c.lit.syms[n.symId], n.symId)
      c.nodes[n.symId] = c.currentNode
    c.take n # :name
    c.take n # dyn
    c.take n # pub
    c.take n # passType
    semStmt c, n
    c.takeParRi n
  of StmtsS:
    c.take n # (stmts
    while n.kind != ParRi:
      semStmt c, n
    c.takeParRi n
  of InputS:
    c.take n # (input
    case c.currentPhase
    of SymbolResolution:
      let sym = c.lit.syms.getOrIncl(c.lit.strings[n.litId])
      c.dest.add symdefToken(sym)
      inc n
    of GraphGeneration:
      c.graph.mgetOrPut(c.currentNode, @[]).add resourceNode(n.symId)
      c.nodes[n.symId] = resourceNode(n.symId)
      c.take n
    c.takeSkip n # type
    c.takeParRi n
  of OutputS:
    c.take n # (output
    case c.currentPhase
    of SymbolResolution:
      let sym = c.lit.syms.getOrIncl(c.lit.strings[n.litId])
      c.dest.add symdefToken(sym)
      inc n
    of GraphGeneration:
      c.graph.mgetOrPut(resourceNode(n.symId), @[]).add c.currentNode
      c.take n
    c.takeSkip n # type
    c.takeParRi n
  of ShaderS:
    # shader depends on pass
    c.take n # (shader
    c.take n # type: render/compute
    case c.currentPhase
    of SymbolResolution:
      let sym = c.lit.syms.getOrIncl(c.lit.strings[n.litId])
      c.dest.add symdefToken(sym)
      inc n
    of GraphGeneration:
      c.graph.mgetOrPut(resourceNode(n.symId), @[]).add c.currentNode
      c.take n
    c.takeParRi n
  of UseS:
    c.take n # (use
    case c.currentPhase
    of SymbolResolution:
      c.dest.add symToken(c.lookupSym(c.lit.strings[n.litId]))
      inc n
    of GraphGeneration:
      c.graph.mgetOrPut(c.currentNode, @[]).add c.nodes[n.symId]
      c.take n
    c.takeParRi n
  of NoStmt: raiseAssert "Invalid statement"
  else: raiseAssert "Unsupported statement"

proc phasex*(c: var SemContext, phase: Phase, input: var TokenBuf): TokenBuf =
  c.currentPhase = phase
  when c.Vm:
    c.dest = createTokenBufVm()
  else:
    c.dest = createTokenBuf()

  var cursor = beginRead(input)
  semStmt c, cursor
  endRead(input)
  result = ensureMove c.dest

proc topologicalSort(c: var SemContext): seq[Node] =
  # uses Kahn's algorithm for topological sorting

  var indegrees = initTable[Node, int]() # number of incoming nodes
  var queue = initDeque[Node]()

  for (owner, deps) in c.graph.pairs:
    indegrees[owner] = 0 # indegrees should be defined for all nodes to sort
    for dep in deps:
      indegrees[dep] = 0

  for (owner, deps) in c.graph.pairs:
    for dep in deps:
      inc indegrees[dep]

  for (node, indegree) in indegrees.pairs:
    if indegree == 0:
      queue.addLast node

  result = @[]
  while queue.len > 0:
    let u = queue.popFirst()
    result.add u

    for neighboor in c.graph.getOrDefault(u):
      dec indegrees[neighboor]
      if indegrees[neighboor] == 0:
        queue.addLast neighboor

  if len(result) != len(indegrees):
    raiseAssert "cyclic type dependence detected"

proc semcheck*(c: var SemContext, input: var TokenBuf) =
  var resolved = phasex(c, SymbolResolution, input)

  when defined(rgc.dumpSymbolResolution):
    echo "After SymbolResolution:"
    echo resolved.toString(c.lit)

  c.dest = phasex(c, GraphGeneration, resolved)

  echo "Dependency graph:"
  template repr(n: Node): string =
    $n.kind & "(" & c.lit.syms[n.s] & ")"

  for k, v in c.graph.pairs:
    var s = k.repr
    for i in v:
      s.add "\n  <- " & i.repr
    echo s
  
  echo ""
  var sorted = c.topologicalSort()
  echo "Sorted:"
  for i in sorted:
    echo i.repr
