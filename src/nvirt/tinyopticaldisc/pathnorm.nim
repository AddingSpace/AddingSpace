#
#
#            Nim's Runtime Library
#        (c) Copyright 2018 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## OS-Path normalization. Used by `os.nim` but also
## generally useful for dealing with paths.
##
## Unstable API.

import std/[strutils]

type
  PathIter* = object
    i, prev: int
    notFirst: bool

proc hasNext*(it: PathIter; x: string): bool =
  it.i < x.len

proc next*(
  it: var PathIter;
  x: string;
  dirSep = '/';
  altSep = '\0'): (int, int) =
  result = (0, 0)
  it.prev = it.i
  if not it.notFirst and (x[it.i] == dirSep or x[it.i] == altSep):
    # absolute path:
    inc it.i
  else:
    while it.i < x.len and x[it.i] != dirSep and x[it.i] != altSep:
      inc it.i
  if it.i > it.prev:
    result = (it.prev, it.i-1)
  elif hasNext(it, x):
    result = next(it, x, dirSep, altSep)
  # skip all separators:
  while it.i < x.len and (x[it.i] == dirSep or x[it.i] == altSep):
    inc it.i
  it.notFirst = true

iterator dirs(x: string; dirSep = '/'; altSep = '\0'): (int, int) =
  var it = default PathIter
  while hasNext(it, x): yield next(it, x, dirSep, altSep)

proc isDot(x: string; bounds: (int, int)): bool =
  bounds[1] == bounds[0] and x[bounds[0]] == '.'

proc isDotDot(x: string; bounds: (int, int)): bool =
  bounds[1] == bounds[0] + 1 and x[bounds[0]] == '.' and x[bounds[0]+1] == '.'

proc isSlash(x: string; bounds: (int, int); dirSep, altSep: char): bool =
  bounds[1] == bounds[0] and
    (x[bounds[0]] == dirSep or x[bounds[0]] == altSep)

func splitDrive(p: string): tuple[drive, path: string] =
  result = ("", p)
  if p.len < 2:
    return
  const sep = '\\'
  let normp = p.replace('/', sep)
  if p.len > 2 and normp[0] == sep and normp[1] == sep and normp[2] != sep:
    let start = block:
      const unc = "\\\\?\\UNC"
      let idx = min(8, normp.len)
      if unc == normp[0..<idx].strip(chars = {sep}, leading = false).toUpperAscii:
        8
      else:
        2
    let index = normp.find(sep, start)
    if index == -1:
      return
    var index2 = normp.find(sep, index + 1)
    if index2 == index + 1:
      return
    if index2 == -1:
      index2 = p.len
    return (p[0..<index2], p[index2..^1])
  if p[1] == ':':
    return (p[0..1], p[2..^1])

proc addNormalizePath*(x: string; result: var string; state: var int;
    dirSep = '/'; altSep = '\0'; doslikeFileSystem = false) =
  ## Low level proc. Undocumented.

  var x = x
  if doslikeFileSystem: # Add Windows drive at start without normalization
    if result == "":
      let (drive, file) = splitDrive(x)
      x = file
      result.add drive
      for c in result.mitems:
        if c == dirSep or c == altSep:
          c = dirSep

  # state: 0th bit set if isAbsolute path. Other bits count
  # the number of path components.
  var it: PathIter = default(PathIter)
  it.notFirst = (state shr 1) > 0
  if it.notFirst:
    while it.i < x.len and (x[it.i] == dirSep or x[it.i] == altSep):
      inc it.i
  while hasNext(it, x):
    let b = next(it, x, dirSep, altSep)
    if (state shr 1 == 0) and isSlash(x, b, dirSep, altSep):
      if result.len == 0 or
          (result[result.len - 1] != dirSep and result[result.len - 1] != altSep):
        result.add dirSep
      state = state or 1
    elif isDotDot(x, b):
      if (state shr 1) >= 1:
        var d = result.len
        # f/..
        # We could handle stripping trailing sep here: foo// => foo like this:
        # while (d-1) > (state and 1) and result[d-1] in {DirSep, AltSep}: dec d
        # but right now we instead handle it inside os.joinPath

        # strip path component: foo/bar => foo
        while (d-1) > (state and 1) and
            result[d-1] != dirSep and result[d-1] != altSep:
          dec d
        if d > 0:
          setLen(result, d-1)
          dec state, 2
      else:
        if result.len > 0 and
            result[result.len - 1] != dirSep and result[result.len - 1] != altSep:
          result.add dirSep
        result.add substr(x, b[0], b[1])
    elif isDot(x, b):
      discard "discard the dot"
    elif b[1] >= b[0]:
      if result.len > 0 and
          result[result.len - 1] != dirSep and result[result.len - 1] != altSep:
        result.add dirSep
      result.add substr(x, b[0], b[1])
      inc state, 2
  if result == "" and x != "": result = "."

proc normalizePath*(
  path: string;
  dirSep = '/';
  altSep = '\0';
  doslikeFileSystem = false): string =
  runnableExamples:
    when defined(posix):
      doAssert normalizePath("./foo//bar/../baz") == "foo/baz"

  ## - Turns multiple slashes into single slashes.
  ## - Resolves `'/foo/../bar'` to `'/bar'`.
  ## - Removes `'./'` from the path, but `"foo/.."` becomes `"."`.
  result = newStringOfCap(path.len)
  var state = 0
  addNormalizePath(path, result, state, dirSep, altSep, doslikeFileSystem)
