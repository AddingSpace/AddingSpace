# SPDX-License-Identifier: MIT
type
  MemoryLocation* = enum
    Unknown
    GpuOnly
    CpuToGpu
    GpuToCpu

  Allocation* = object
    handle*: pointer
    offset*: uint64
    size*: uint64
    memoryTypeIndex*: uint32
    location*: MemoryLocation
    mappedPtr*: pointer

  AllocDesc* = object
    size*: uint64
    alignment*: uint64
    memoryTypeBits*: uint32 = 0xFFFFFFFF'u32
    ## VkMemoryRequirements.memoryTypeBits
    ## Used by Vulkan backend; other backends ignore.
    location*: MemoryLocation
    linear*: bool = true
    ## true for buffers/linear textures, false for tiled textures.
    ## Used by Vulkan; other backends ignore.
    deviceAddress*: bool = false
    ## true if the buffer was created with VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.
    ## Used by Vulkan; other backends ignore.

  BackendAllocModel* = concept
    proc allocateDeviceMemory(b: var Self, size: uint64, memTyp: uint32, deviceAddress: bool): pointer
    proc freeDeviceMemory(b: var Self, handle: pointer)
    proc findMemoryType(b: Self, typeBits: uint32, loc: MemoryLocation): int32
    proc mapMemory(b: var Self, handle: pointer, offset, size: uint64): pointer
    proc unmapMemory(b: var Self, handle: pointer)

  GpuAllocator*[B: BackendAllocModel] = concept
    proc init(_: type Self, backend: B): Self
    proc alloc(a: var Self, desc: AllocDesc): Allocation
    proc free(a: var Self, alloc: Allocation)
    proc realloc(a: var Self, alloc: Allocation, newSize: uint64): Allocation
