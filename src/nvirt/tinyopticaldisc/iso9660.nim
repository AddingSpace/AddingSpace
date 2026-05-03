# ECMA-119 spec is so bad...
import std/[streams, options, endians, strutils]
import ./posixpaths

type
  Iso9660Reader* = object 
    logicalSectorSize: int
    logicalBlockSize: int
    volume: Volume
    volumeDescriptorSet: VolumeDescriptorSet
  
  LogicalSector = distinct string # some seq of blocks

  VolumeDescriptorSet = object
    primary: Option[VolumeDescriptor] # one PrimaryVolumeDescriptor
    supplementary: seq[VolumeDescriptor] # zero or more SupplementaryVolumeDescriptor
    enchanced: seq[VolumeDescriptor] # zero or more EnchancedVolumeDescriptor
    partition: seq[VolumeDescriptor] # zero or more VolumePartitionDescriptor
    boot: seq[VolumeDescriptor] # zero or more BootRecord
    terminators: seq[VolumeDescriptor] # one or more 

  Volume = object
    systemArea: array[16, LogicalSector]
    dataArea: seq[LogicalSector]
  
  AChar = distinct char
  # TODO: implement char checking, but it will be future
  #[
  Table A.2 — a-characters

  SP (i.e. Space) ! " % & ' ( ) * + , - . /
  0 1 2 3 4 5 6 7 8 9
  : ; < = > ?
  A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
  _

  ]#

  DChar = distinct char
  #[
  Table A.1 — d-characters

  0 1 2 3 4 5 6 7 8 9
  A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
  _

  = [0-9A-Z_]
  ]#

  VolumeDescriptorType {.size: 1.} = enum
    BootRecord = 0
    PrimaryVolumeDescriptor = 1
    SupplementaryVolumeDescriptor = 2
    VolumePartitionDescriptor = 3
    EnchancedVolumeDescriptor = 4
    VolumeDescriptorSetTerminator = 255

  VolumeFlag {.size: 1.} = enum
    NonStandardEscapeSequences
    ReservedVolumeFlag1
    ReservedVolumeFlag2
    ReservedVolumeFlag3
    ReservedVolumeFlag4
    ReservedVolumeFlag5
    ReservedVolumeFlag6
    ReservedVolumeFlag7
  
  FileFlag {.size: 1.} = enum
    Existence
    Directory
    AssociatedFile
    Record
    Protection
    ReservedFileFlag1
    ReservedFileFlag2
    MultiExtent

  PathComponent* = enum
    pcFile
    pcDir
  
  DirectoryRecord = object
    len: byte
    extendedAttributeRecordLen: byte
    extentLocation: uint64
    dataLen: uint64
    recordingDate: array[7, byte]
    fileFlags: set[FileFlag]
    fileUnitSize: byte
    interleaveGapSize: byte
    volumeSequenceNumber: uint32
    fileIdentifier: string # wtf: check for d-characters, d1-characters,
                           # separator 1, separator 2,
                           # (00) or (01) byte

  VolumeDescriptor = object
    # CD001
    version: byte
    systemIdentifier: array[32, AChar]
    case typ: VolumeDescriptorType
    of BootRecord:
      # bootSystemIdentifier: array[32, AChar]
      bootIdentifier: array[32, AChar]
      # bootSystemUse: seek to 2048
    of VolumeDescriptorSetTerminator: discard # seek to 2048, note that we don't care that it should be (00) bytes but it can be changed in future to be more strict
    of PrimaryVolumeDescriptor, SupplementaryVolumeDescriptor, EnchancedVolumeDescriptor:
      flags: set[VolumeFlag] # only for SupplementaryVolumeDescriptor, EnchancedVolumeDescriptor
      # skip byte
      # systemIdentifier: array[32, AChar]
      volumeIdentifier: array[32, DChar]
      # skip byte
      volumeSpaceSize: uint64
      # skip 32 bytes
      volumeSetSize: uint32
      volumeSequenceNumber: uint32
      logicalBlockSize: uint32
      pathTableSize: uint64
      # maybe merge it?
      mainLocLPathTable: uint32
      optLocLPathTable: uint32
      # maybe merge it?
      mainLocMPathTable: uint32
      optLocMPathTable: uint32
      directoryRecord: DirectoryRecord
      volumeSetIdentifier: array[128, DChar]
      publisherIdentifier: array[128, AChar]
      dataPreparerIdentifier: array[128, AChar]
      applicationIdentifier: array[128, AChar]
      # why is so hard? wtf is separator 1, separator 2, how code should capture it???? Maybe best way is make it via new type but it will in future
      # copyrightFileIdentifier: array[37, DChar, separator 1, separator 2]
      # abstractFileIdentifier: array[37, DChar, separator 1, separator 2]
      # bibliographicFileIdentifier: array[37, DChar, separator 1, separator 2]
      volumeCreationDate: array[17, byte]
      volumeModificationDate: array[17, byte]
      volumeExpirationDate: array[17, byte]
      volumeEffectiveDate: array[17, byte]
      fileStructureVersion: byte
      # skip byte, application use, reserve
      # i.e seek to 2048
    of VolumePartitionDescriptor:
      volumeDescriptorVersion: array[32, DChar]
      volumePartitionLocation: uint64
      volumePartitionSize: uint64
      # seek to 2048

    content: string

const
  currentDir = $char(0x00)
  parentDir = $char(0x01)

proc `$`(s: LogicalSector): string {.borrow.}

proc bitFloor[T: uint32 or uint64](x: T): T =
  if x == 0: return 0

  var x = x
  for i in [1, 2, 4, 8, 16]:
    x = x or (x shr i)

  if x is uint64:
    x = x or (x shr 32)

  x - (x shr 1)

proc init*(
  _: type Iso9660Reader,
  dataFieldSize: int = 0,
  logicalBlockSize: int = -1): Iso9660Reader =
  # dataFieldSize specific for storage, for .iso files it 2048,
  # for CD discs it can get it from datafield in physical sectors,
  # every sector 2352 bytes

  result = Iso9660Reader(
    logicalSectorSize: max(2048, int bitFloor(dataFieldSize.uint32)),
  )
  if logicalBlockSize > 0:
    assert logicalBlockSize <= result.logicalSectorSize
    result.logicalBlockSize = logicalBlockSize
  else:
    # ISO 9660, CD roms etc have same sizes
    result.logicalBlockSize = result.logicalSectorSize

proc readSector(reader: var Iso9660Reader, sector: var LogicalSector, s: Stream) =
  s.readStr(reader.logicalSectorSize, string sector)

proc parseDirectoryRecord(reader: var Iso9660Reader, stream: Stream, record: var DirectoryRecord): bool =
  result = true
  let start = stream.getPosition()
  var
    raw16: uint16 = 0
    raw32: uint32 = 0
    le16: uint16 = 0
    le32: uint32 = 0
  
  record.len = stream.readUint8()
  record.extendedAttributeRecordLen = stream.readUint8().byte
  
  raw32 = stream.readUint32()
  littleEndian32(addr le32, addr raw32)
  record.extentLocation = uint64(le32)
  stream.setPosition(stream.getPosition + 4) # skip big-endian copy
  
  raw32 = stream.readUint32()
  littleEndian32(addr le32, addr raw32)
  record.dataLen = uint64(le32)
  stream.setPosition(stream.getPosition + 4) # skip big-endian copy

  stream.read(record.recordingDate)
  record.fileFlags = cast[set[FileFlag]](stream.readUint8())
  record.fileUnitSize = stream.readUint8().byte
  record.interleaveGapSize = stream.readUint8().byte
  raw16 = stream.readUint16()
  littleEndian16(addr le16, addr raw16)
  record.volumeSequenceNumber = uint32(le16)
  stream.setPosition(stream.getPosition + 2) # skip big-endian copy

  let fileIdentifierLen = stream.readUint8().int
  record.fileIdentifier = stream.readStr(fileIdentifierLen)

  stream.setPosition(start + record.len.int)

iterator walkDir*(
  reader: var Iso9660Reader,
  s: Stream,
  dir: string,
  relative = false,
  checkDir = false,
  skipSpecial = false): tuple[kind: PathComponent, path: string] =
  # Highly co-authored with gpt 5.5
  var
    dirRecord = reader.volumeDescriptorSet.primary.get.directoryRecord
    dirPath = "/"
    componentIdx = 0
    start = int64(dirRecord.extentLocation) * int64(reader.logicalBlockSize)
    finish = start + int64(dirRecord.dataLen)

  let
    normalizedDir = joinPosixPath("/", dir).strip(chars = {'/'}) # should be normalized posix path after it...
    components =
      if normalizedDir.len == 0: newSeq[string]()
      else: normalizedDir.split('/')

  s.setPosition(start)

  while s.getPosition() < finish:
    let
      recordStart = s.getPosition()
      recordLen = s.readUint8()

    if recordLen == 0'u8:
      s.setPosition((recordStart div reader.logicalBlockSize + 1) * reader.logicalBlockSize)
      continue

    s.setPosition(recordStart)
    var record = DirectoryRecord()
    if not reader.parseDirectoryRecord(s, record): break

    if record.fileIdentifier == currentDir or record.fileIdentifier == parentDir: continue # special paths: 0x00, 0x01

    if componentIdx < components.len:
      # important: we not found target dir and need early continue untill target will reached

      if Directory in record.fileFlags and record.fileIdentifier == components[componentIdx]:
        # found dir!
        dirRecord = record
        dirPath = joinPosixPath(dirPath, components[componentIdx])
        inc componentIdx

        start = int64(dirRecord.extentLocation) * int64(reader.logicalBlockSize)
        finish = start + int64(dirRecord.dataLen)
        s.setPosition(start)

      continue

    if skipSpecial and ({AssociatedFile, Record, Protection, MultiExtent} * record.fileFlags).len > 0:
      continue

    let
      name = record.fileIdentifier
      kind =
        if Directory in record.fileFlags: pcDir
        else: pcFile
      path =
        if relative: name
        else: joinPosixPath(dirPath, name)

    yield (kind, path)

  if componentIdx < components.len and checkDir:
    raise newException(OSError, "No such directory: " & dir)

iterator walkDirRec*(
  reader: var Iso9660Reader,
  s: Stream,
  dir: string,
  yieldFilter = {pcFile}, followFilter = {pcDir},
  relative = false, checkDir = false, skipSpecial = false): string =
  # I just make small fix to std impl of it but not tested it properly
  # but it should work correctly
  var stack = @[""]
  var checkDir = checkDir
  while stack.len > 0:
    let d = stack.pop()
    for k, p in walkDir(
        reader, s, joinPosixPath(dir, d), relative = true, checkDir = checkDir,
        skipSpecial = skipSpecial):

      let rel = joinPosixPath(d, p)
      if k == pcDir and k in followFilter:
        stack.add rel
      if k in yieldFilter:
        yield
          if relative: rel
          else: joinPosixPath(dir, rel)

    checkDir = false
      # We only check top-level dir, otherwise if a subdir is invalid (eg. wrong
      # permissions), it'll abort iteration and there would be no way to
      # continue iteration.
      # Future work can provide a way to customize this and do error reporting.

proc parseVolumeDescriptorSet(reader: var Iso9660Reader, s: LogicalSector): bool =
  result = false # need VolumeDescriptorSetTerminator to mark it as true (parsed)
  let data = string(s)
  if data.len < reader.logicalSectorSize: return

  var stream = newStringStream(data) # yes, it realy bad idea and we can skip
                                     # parsing LogicalSector into string,
                                     # we can just use seek ops and maybe mmap things but it for future
  # ai generated data type parser:
  let rawTyp = stream.readUint8()
  if stream.readStr(5) != "CD001": return
  let version = stream.readUint8()

  let typ =
    case rawTyp
    of 0'u8: BootRecord
    of 1'u8: PrimaryVolumeDescriptor
    of 2'u8:
      if version == 2: EnchancedVolumeDescriptor
      else: SupplementaryVolumeDescriptor
    of 3'u8: VolumePartitionDescriptor
    of 255'u8: VolumeDescriptorSetTerminator
    else: return

  var descriptor = VolumeDescriptor(
    typ: typ,
    version: byte(version),
    content: data)

  case typ
  of BootRecord:
    stream.read(descriptor.systemIdentifier)
    stream.read(descriptor.bootIdentifier)
    reader.volumeDescriptorSet.boot.add descriptor
  of VolumeDescriptorSetTerminator:
    reader.volumeDescriptorSet.terminators.add descriptor
    result = true
  of PrimaryVolumeDescriptor, SupplementaryVolumeDescriptor, EnchancedVolumeDescriptor:
    var flags = stream.readUint8()
    if typ != PrimaryVolumeDescriptor:
      descriptor.flags = cast[set[VolumeFlag]](flags)

    stream.read(descriptor.systemIdentifier)
    stream.read(descriptor.volumeIdentifier)
    stream.setPosition(80)

    var
      raw16: uint16 = 0
      raw32: uint32 = 0
      le16: uint16 = 0
      le32: uint32 = 0

    raw32 = stream.readUint32()
    littleEndian32(addr le32, addr raw32)
    descriptor.volumeSpaceSize = uint64(le32)
    stream.setPosition(120)

    raw16 = stream.readUint16()
    littleEndian16(addr le16, addr raw16)
    descriptor.volumeSetSize = uint32(le16)
    stream.setPosition(124)

    raw16 = stream.readUint16()
    littleEndian16(addr le16, addr raw16)
    descriptor.volumeSequenceNumber = uint32(le16)
    stream.setPosition(128)

    raw16 = stream.readUint16()
    littleEndian16(addr le16, addr raw16)
    descriptor.logicalBlockSize = uint32(le16)
    stream.setPosition(132)

    raw32 = stream.readUint32()
    littleEndian32(addr le32, addr raw32)
    descriptor.pathTableSize = uint64(le32)
    stream.setPosition(140)

    raw32 = stream.readUint32()
    littleEndian32(addr descriptor.mainLocLPathTable, addr raw32)
    raw32 = stream.readUint32()
    littleEndian32(addr descriptor.optLocLPathTable, addr raw32)
    raw32 = stream.readUint32()
    bigEndian32(addr descriptor.mainLocMPathTable, addr raw32)
    raw32 = stream.readUint32()
    bigEndian32(addr descriptor.optLocMPathTable, addr raw32)

    if not reader.parseDirectoryRecord(stream, descriptor.directoryRecord): return

    stream.read(descriptor.volumeSetIdentifier)
    stream.read(descriptor.publisherIdentifier)
    stream.read(descriptor.dataPreparerIdentifier)
    stream.read(descriptor.applicationIdentifier)
    stream.setPosition(813)
    stream.read(descriptor.volumeCreationDate)
    stream.read(descriptor.volumeModificationDate)
    stream.read(descriptor.volumeExpirationDate)
    stream.read(descriptor.volumeEffectiveDate)
    descriptor.fileStructureVersion = stream.readUint8().byte

    case typ
    of PrimaryVolumeDescriptor:
      reader.volumeDescriptorSet.primary = some descriptor
    of SupplementaryVolumeDescriptor:
      reader.volumeDescriptorSet.supplementary.add descriptor
    of EnchancedVolumeDescriptor:
      reader.volumeDescriptorSet.enchanced.add descriptor
    else: discard

  of VolumePartitionDescriptor:
    stream.setPosition(8)
    stream.read(descriptor.systemIdentifier)
    stream.read(descriptor.volumeDescriptorVersion)

    var
      raw32 = stream.readUint32()
      le32: uint32 = 0

    littleEndian32(addr le32, addr raw32)
    descriptor.volumePartitionLocation = uint64(le32)
    stream.setPosition(80)

    raw32 = stream.readUint32()
    littleEndian32(addr le32, addr raw32)
    descriptor.volumePartitionSize = uint64(le32)
    reader.volumeDescriptorSet.partition.add descriptor

proc read*(reader: var Iso9660Reader, s: Stream) =
  for i in 0..<reader.volume.systemArea.len:
    reader.readSector reader.volume.systemArea[i], s

  while not s.atEnd:
    var newSector = LogicalSector(newStringOfCap(reader.logicalSectorSize))
    reader.readSector newSector, s
    if reader.parseVolumeDescriptorSet(newSector): break

when isMainModule:
  var s = newFileStream("1mb.iso")
  var r = Iso9660Reader.init()
  r.read(s)

  for entry in r.walkDir(s, "/", relative = true):
    echo entry
