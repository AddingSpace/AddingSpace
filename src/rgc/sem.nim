import ir, model

type
  SemContext*[Vm: static bool] = object
    when Vm:
      dest: VmTokenBuf
    else:
      data: RtTokenBuf
    
    lit*: Literals
    
proc semStmt*(c: var SemContext, n: var Cursor) =
  echo "STMT: ", n.toString(c.lit)
  case n.stmtKind
  of PassS:
    echo "hello"
  else: discard
  skip n

proc semcheck*(c: var SemContext, n: Cursor) =
  var n = n
  while n.kind != ParRi:
    semStmt c, n
