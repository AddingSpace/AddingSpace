import pathnorm

template endsWithPosixSep(path: string): bool =
  path.len > 0 and path[^1] == '/'

proc normalizePosixPathEnd*(path: var string, trailingSep = false) =
  # https://github.com/nim-lang/Nim/blob/bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/lib/std/private/ospaths2.nim#L46
  if path.len == 0: return
  var i = path.len
  while i >= 1:
    if path[i-1] == '/': dec(i)
    elif path[i-1] == '.' and i >= 2 and path[i-2] == '/': dec(i)
    else: break

  if trailingSep:
    # foo// => foo
    path.setLen(i)
    # foo => foo/
    path.add '/'
  elif i > 0:
    # foo// => foo
    path.setLen(i)
  else:
    # // => / (empty case was already taken care of)
    path = "/"

proc normalizePosixPathEnd*(path: string, trailingSep = false): string =
  result = path
  result.normalizePosixPathEnd(trailingSep)

proc joinPosixPathImpl(result: var string, state: var int, tail: string) =
  let trailingSep =
    tail.endsWithPosixSep or
    tail.len == 0 and
    result.endsWithPosixSep

  result.normalizePosixPathEnd(trailingSep = false)
  addNormalizePath(tail, result, state, dirSep = '/', altSep = '\0')
  result.normalizePosixPathEnd(trailingSep = trailingSep)

proc joinPosixPath*(head, tail: string): string =
  result = newStringOfCap(head.len + tail.len)
  var state = 0
  joinPosixPathImpl(result, state, head)
  joinPosixPathImpl(result, state, tail)

proc resolvePosixPath*(base, path: string): string =
  joinPosixPath(
    if path.len > 0 and path[0] == '/': ""
    else: base
  , path)
