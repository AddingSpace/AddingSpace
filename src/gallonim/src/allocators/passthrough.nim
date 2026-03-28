# Passthrough Allocator
# port of https://kylehalladay.com/blog/tutorial/2017/12/13/Custom-Allocators-Vulkan.html
import gpualloc

type
  PassthroughGpuAllocator*[B] = object
    backend*: B
    # debug info:
    totalAllocated*: uint64
    numAllocs*: uint32

proc init*[B](
  _: type PassthroughGpuAllocator[B],
  backend: B): PassthroughGpuAllocator[B] =
  PassthroughGpuAllocator[B](backend: backend)

proc alloc*[B](a: var PassthroughGpuAllocator[B], desc: AllocDesc): Allocation =
  let memTyp = a.backend.findMemoryType(desc.memoryTypeBits, desc.location)
  assert memTyp >= 0, "No compatible memory type found"

  let handle = a.backend.allocateDeviceMemory(desc.size, memTyp.uint32, desc.deviceAddress)
  a.totalAllocated += desc.size
  inc a.numAllocs

  let mappedPtr: pointer # TODO: guarantee that it uses strict defs
                         # even when used as installed library
  if desc.location in {CpuToGpu, GpuToCpu}:
    mappedPtr = a.backend.mapMemory(handle, 0u64, desc.size)
  else:
    mappedPtr = nil

  Allocation(
    handle: handle,
    offset: 0'u64,
    size: desc.size,
    memoryTypeIndex: memTyp.uint32,
    location: desc.location,
    mappedPtr: mappedPtr)

proc free*[B](a: var PassthroughGpuAllocator[B], alloc: Allocation) =
  if alloc.mappedPtr != nil: a.backend.unmapMemory(alloc.handle)
  a.backend.freeDeviceMemory(alloc.handle)
  a.totalAllocated -= alloc.size
  dec a.numAllocs

proc realloc*[B](
  a: var PassthroughGpuAllocator[B], alloc: Allocation,
  newSize: uint64): Allocation =
  let desc = AllocDesc(
    size: newSize,
    alignment: 0'u64,
    memoryTypeBits: 1'u32 shl alloc.memoryTypeIndex,
    location: alloc.location)

  result = a.alloc(desc)
  if alloc.mappedPtr != nil and result.mappedPtr != nil:
    copyMem(result.mappedPtr, alloc.mappedPtr, min(alloc.size, newSize))
  a.free(alloc)
