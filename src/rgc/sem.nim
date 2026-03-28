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
      typeRegistry*: VmTypes
    else:
      dest*: RtTokenBuf
      typeRegistry*: RtTypes
    typeTable*: TypeTable

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
    resourceTypes*: Table[SymId, TypeId]
    resourceScopes*: Table[SymId, seq[SymId]]

proc passNode(s: SymId): Node = Node(kind: Pass, s: s)
proc moduleNode(s: SymId): Node = Node(kind: Module, s: s)
proc resourceNode(s: SymId): Node = Node(kind: Resource, s: s)

proc lookupSym(c: SemContext, name: string): SymId =
  for (n, sym) in c.toplevelScope:
    if cmpIgnoreStyle(n, name) == 0:
      return sym
  raiseAssert "Undefined: " & name

proc lookupResource(c: SemContext, owner: SymId, name: string): SymId =
  for sym in c.resourceScopes.getOrDefault(owner):
    if cmpIgnoreStyle(c.lit.syms[sym], name) == 0:
      return sym
  raiseAssert "Undefined resource: " & name

proc skipParRi*(n: var Cursor) =
  assert n.kind == ParRi
  inc n

proc resolveResourceRef(c: var SemContext, n: var Cursor) =
  if n.kind == ParLe and n.exprKind == DotE:
    inc n # (dot
    let ownerSym = c.lookupSym(c.lit.strings[n.litId])
    inc n # owner
    let sym = c.lookupResource(ownerSym, c.lit.strings[n.litId])
    inc n # resource
    c.dest.add symToken(sym)
    skipParRi n
  else:
    assert n.kind == Ident
    c.dest.add symToken(c.lookupResource(c.currentNode.s, c.lit.strings[n.litId]))
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

# XXX: `==` in sem.nim need because what??, `==` should be type bound,
# so maybe nimvm doesn't implement type bound ops
proc `==`*(a, b: TypeId): bool {.borrow.}

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
    # TODO: refactor of InputS, of OutputS into one case
    # motivation: same SymbolResolution logic, difference only at
    # GraphGeneration phase, it should be simple
    c.take n # (input
    case c.currentPhase
    of SymbolResolution:
      let sym = c.lit.syms.getOrIncl(c.lit.strings[n.litId])
      c.resourceScopes.mgetOrPut(c.currentNode.s, @[]).add(sym)
      c.dest.add symdefToken(sym)
      inc n
      if n.stmtKind == UsageS: c.dest.takeTree(n) # (usage
      else: c.take n # .
      let typId = getOrGenType(c.typeTable, c.typeRegistry, n, c.dest)
      c.resourceTypes[sym] = typId

    of GraphGeneration:
      c.graph.mgetOrPut(c.currentNode, @[]).add resourceNode(n.symId)
      c.nodes[n.symId] = resourceNode(n.symId)
      c.take n
      skip n # (usage or .
      skip n # type
    c.takeParRi n
  of OutputS:
    c.take n # (output
    case c.currentPhase
    of SymbolResolution:
      let sym = c.lit.syms.getOrIncl(c.lit.strings[n.litId])
      c.resourceScopes.mgetOrPut(c.currentNode.s, @[]).add(sym)
      c.dest.add symdefToken(sym)
      inc n
      if n.stmtKind == UsageS: c.dest.takeTree(n) # (usage
      else: c.take n # .
      let typId = getOrGenType(c.typeTable, c.typeRegistry, n, c.dest)
      c.resourceTypes[sym] = typId

    of GraphGeneration:
      c.graph.mgetOrPut(resourceNode(n.symId), @[]).add c.currentNode
      c.nodes[n.symId] = resourceNode(n.symId)
      c.take n
      skip n # (usage or .
      skip n # type
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
  of ConnectS:
    c.take n # (connect
    case c.currentPhase
    of SymbolResolution:
      c.resolveResourceRef(n)
      c.resolveResourceRef(n)
    of GraphGeneration:
      let srcSym = n.symId
      c.take n
      let dstSym = n.symId
      c.take n
      c.graph.mgetOrPut(resourceNode(dstSym), @[]).add resourceNode(srcSym)
    c.takeParRi n
  of NoStmt: raiseAssert "Invalid statement"
  else: raiseAssert "Unsupported statement"

proc phasex*(c: var SemContext, phase: Phase, input: var TokenBuf): TokenBuf =
  c.currentPhase = phase
  when c.Vm:
    c.dest = createTokenBufVm()
    c.typeRegistry = initTypesVm()
  else:
    c.dest = createTokenBuf()
    c.typeRegistry = initTypes()

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
  echo "Resource types:"
  for sym in c.resourceTypes.keys:
    let tid = c.resourceTypes[sym]
    echo "  ", c.lit.syms[sym], ": ", c.typeTable.toString(tid),
         " [TypeId=", tid.uint32, "]"

  echo ""
  var sorted = c.topologicalSort()
  echo "Sorted:"
  for i in sorted:
    echo i.repr
