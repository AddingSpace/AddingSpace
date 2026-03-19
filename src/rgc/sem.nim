import ir, model, bitabs, lineinfos
import std/tables

type
  NodeKind = enum
    Module
    Pass
    Resource
  
  Node = object
    kind: NodeKind
    s: SymId

  SemContext*[Vm: static bool] = object
    when Vm:
      dest: VmTokenBuf
    else:
      data: RtTokenBuf
    
    lit*: Literals

    graph*: Table[Node, Node]
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
    currentNodeSym: SymId
    currentPassKind: string # Currently I don't care about scopes
    exported*: Table[SymId, FileId] # exported node to it's file

proc semStmt*(c: var SemContext, n: var Cursor) =
  echo "STMT: ", n.toString(c.lit)
  echo n.stmtKind
  case n.stmtKind
  of PassS:
    inc n
    c.currentNodeSym = n.symId
    inc n
    assert n.kind == DotToken # dyn pass is not supported
    inc n
    if n.kind == Ident and c.lit.strings[n.litId] == "pub":
      c.exported[c.currentNodeSym] = FileId(0) # dummy file currently. TODO: implement
    inc n
    c.currentPassKind = c.lit.strings[n.litID]
    inc n
    semStmt c, n
  of ModuleS: skip n
  of StmtsS:
    inc n
    while n.kind != ParRi:
      semStmt c, n
  of NoStmt: raiseAssert"Holly fuck?"

proc semcheck*(c: var SemContext, n: Cursor) =
  var n = n
  while n.kind != ParRi:
    semStmt c, n
