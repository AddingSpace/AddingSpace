import pkg/vulkan
import ../allocators/gpualloc

type
  VulkanAllocModel* = object
    device: VkDevice
    pDevice: VkPhysicalDevice
    memProperties: VkPhysicalDeviceMemoryProperties

proc init*(
  _: type VulkanAllocModel, device: VkDevice,
  pDevice: VkPhysicalDevice): VulkanAllocModel =

  result = VulkanAllocModel(device: device, pDevice: pDevice)
  vkGetPhysicalDeviceMemoryProperties(result.pDevice, result.memProperties.addr)

func supportsMemoryType(typeBits: uint32, index: int): bool {.inline.} =
  (typeBits and (1'u32 shl index.uint32)) != 0'u32

proc findMemoryType*(b: VulkanAllocModel, typeBits: uint32,
                     location: MemoryLocation): int32 =
  let requiredFlags =
    case location
    of GpuOnly:  VkMemoryPropertyFlags{DeviceLocalBit}
    of CpuToGpu: VkMemoryPropertyFlags{HostVisibleBit, HostCoherentBit}
    of GpuToCpu: VkMemoryPropertyFlags{HostVisibleBit, HostCachedBit}
    of Unknown:  VkMemoryPropertyFlags(0)

  for i in 0 ..< b.memProperties.memoryTypeCount.int:
    let memoryType = b.memProperties.memoryTypes[i]
    if (
      supportsMemoryType(typeBits, i) and
      requiredFlags <= memoryType.propertyFlags):
      return i.int32
  return -1

proc allocateDeviceMemory*(
  b: var VulkanAllocModel, size: uint64,
  memoryTypeIndex: uint32, deviceAddress: bool): pointer =

  var allocFlagsInfo = VkMemoryAllocateFlagsInfo(
    sType: VkStructureType.MemoryAllocateFlagsInfo,
    flags: VkMemoryAllocateFlags{DeviceAddressBit})

  var allocCi = VkMemoryAllocateInfo(
    sType: VkStructureType.MemoryAllocateInfo,
    pNext: if deviceAddress: allocFlagsInfo.addr else: nil,
    allocationSize: VkDeviceSize(size),
    memoryTypeIndex: memoryTypeIndex)

  var memory = VkDeviceMemory(0)
  let res = vkAllocateMemory(b.device, allocCi.addr, nil, memory.addr)
  assert res == VkSuccess, "vkAllocateMemory failed: " & $res
  return cast[pointer](memory)

proc freeDeviceMemory*(b: var VulkanAllocModel, handle: pointer) =
  vkFreeMemory(b.device, cast[VkDeviceMemory](handle), nil)

proc mapMemory*(
  b: var VulkanAllocModel, handle: pointer,
  offset, size: uint64): pointer =

  result = nil
  if vkMapMemory(
    b.device, cast[VkDeviceMemory](handle),
    VkDeviceSize(offset), VkDeviceSize(size),
    VkMemoryMapFlags(0), result.addr) != VkSuccess: quit("vkMapMemory failed")

proc unmapMemory*(b: var VulkanAllocModel, handle: pointer) =
  vkUnmapMemory(b.device, cast[VkDeviceMemory](handle))

static:
  assert VulkanAllocModel is BackendAllocModel
