## The module that launches the game

import std/sequtils
import pkg/siwin
import pkg/vulkan
import pkg/chronicles
import pkg/vmath
import pkg/gallonim

type
  QueueFamilyIndices = object
    # maybe will be needed in future
    graphicsFamily: uint32

  QueueFamilies = object
    # maybe will be needed in future
    graphicsFamily: VkQueueFamilyProperties

  NariInstance = object
    vkInstance: VkInstance
    devices: seq[VkPhysicalDevice] # TODO: rename to pDevices
    deviceId: int # TODO: implement selection
    familyIndices: QueueFamilyIndices
    families: QueueFamilies

    surface: VkSurfaceKHR
    device: VkDevice
    queue: VkQueue
    swapchain: VkSwapchainKHR
    allocator: PassthroughGpuAllocator[VulkanAllocModel] # TODO: implement freelist allocator etc.

    # Until render graph integration:
    depthImage: VkImage
    depthImageView: VkImageView
    vertexBuffer: VkBuffer

var siwinGlobals = newSiwinGlobals()
vkPreload() # load vulkan

using nariInstance: var NariInstance
proc initGameWindow(nariInstance): window.Window =
  var appInfo = newVkApplicationInfo(
    pApplicationName = "Adding Space",
    applicationVersion = vkMakeVersion(0, 1, 0, 0),
    pEngineName = "Renderer",
    engineVersion = vkMakeVersion(0, 1, 0, 0),
    apiVersion = vkApiVersion1_4
  )

  var exts = getRequiredVulkanExtensions()
  exts.add "VK_KHR_surface"
  # exts.add "VK_KHR_swapchain_maintenance1"
  when defined(nari.vulkanDebug):
    info "Vulkan validation layers requested"
    exts.add "VK_EXT_debug_utils"
    const validationLayers = [cstring"VK_LAYER_KHRONOS_validation"]
  let extsC = exts.mapIt(cstring(it))

  var instanceCi = VkInstanceCreateInfo(
    sType: VkStructureType.InstanceCreateInfo,
    pApplicationInfo: appInfo.addr,
    enabledLayerCount:
      when defined(nari.vulkanDebug): validationLayers.len
      else: 0,
    ppEnabledLayerNames:
      when defined(nari.vulkanDebug): cast[cstringArray](validationLayers[0].addr)
      else: nil,
    enabledExtensionCount: uint32(extsC.len),
    ppEnabledExtensionNames:
      if extsC.len == 0: nil
      else: cast[cstringArray](extsC[0].addr),
  )

  if vkCreateInstance(instanceCi.addr, nil, nariInstance.vkInstance.addr) != VKSuccess:
    quit("Failed to create Vulkan instance")
  
  vkInit(nariInstance.vkInstance)
  loadVK_KHR_surface()
  loadVK_KHR_swapchain()
  # loadVK_KHR_swapchain_maintenance1()

  # it's incredible but we need to create a window bound to the vulkan instance
  result = newVulkanWindow(
    siwinGlobals,
    cast[pointer](nariInstance.vkInstance),
    title = "Adding Space")
  
  nariInstance.surface = cast[VkSurfaceKHR](result.vulkanSurface)

proc findDevices(nariInstance) =
  info "Grep device list"
  var deviceCount = 0'u32
  if vkEnumeratePhysicalDevices(
    nariInstance.vkInstance,
    deviceCount.addr, nil) != VKSuccess:
      quit("Can't enumerate devices")
  
  nariInstance.devices = newSeq[VkPhysicalDevice](deviceCount)
  if vkEnumeratePhysicalDevices(nariInstance.vkInstance, deviceCount.addr, nariInstance.devices[0].addr) != VKSuccess:
    quit("Can't find devices")

  for i in 0..<deviceCount:
    var deviceProperties = VkPhysicalDeviceProperties2(
      sType: PhysicalDeviceProperties2)
    vkGetPhysicalDeviceProperties2(nariInstance.devices[i], deviceProperties.addr)
    var s = ""
    for i in deviceProperties.properties.deviceName:
      if i == '\0': continue
      s.add i
    
    info "Found device: ", device = s

proc handleDeviceLost(res: VkResult, nariInstance): VkResult =
  # Should be used for
  # vkQueueSubmit, vkQueueSubmit2
  # vkQueuePresentKHR, vkAcquireNextImageKHR
  # vkQueueBindSparse, vkWaitForFences, vkGetFenceStatus,
  # vkDeviceWaitIdle, vkQueueWaitIdle, vkEventGetStatus
  # vkCreateDevice, vkCreateSwapchainKHR, vkAllocateMemory,
  # vkMapMemory, vkBindBufferMemory, vkBindImageMemory,
  # vkCreateGraphicsPipelines, vkCreateComputePipelines,
  # vkGetQueryPoolResults, vkGetPipelineExecutablePropertiesKHR
  
  if res == VK_ERROR_DEVICE_LOST:
    # TODO: add VK_EXT_device_fault to know why VK_ERROR_DEVICE_LOST happened
    nariInstance.findDevices()
  res

# proc selectDevice(nariInstance) =

proc findQueueFamilyIndices(nariInstance) =
  var familyCount = 0'u32
  vkGetPhysicalDeviceQueueFamilyProperties(
    nariInstance.devices[nariInstance.deviceId],
    familyCount.addr, nil)
  
  var families = newSeq[VkQueueFamilyProperties](familyCount)
  vkGetPhysicalDeviceQueueFamilyProperties(
    nariInstance.devices[nariInstance.deviceId],
    familyCount.addr, families[0].addr
  )
  var i = 0'u32
  for family in families:
    if (family.queueFlags.uint32 and VkQueueGraphicsBit.uint32) > 0'u32:
      nariInstance.families.graphicsFamily = family
      nariInstance.familyIndices.graphicsFamily = i
    inc i
  


  # TODO: add validation of nariInstance.families and nariInstance.familyIndices

  var presentSupport = default(VkBool32)
  discard vkGetPhysicalDeviceSurfaceSupportKHR(
    nariInstance.devices[nariInstance.deviceId],
    nariInstance.familyIndices.graphicsFamily, nariInstance.surface,
    presentSupport.addr)
  
  if presentSupport.ord != 1:
    quit("No presentation support found(")

proc peekDevice(nariInstance) =
  let qfpriorities = 1.0f
  var queueCi = VkDeviceQueueCreateInfo(
    sType: DeviceQueueCreateInfo,
    queueFamilyIndex: nariInstance.familyIndices.graphicsFamily,
    queueCount: 1,
    pQueuePriorities: qfpriorities.addr)
  
  const deviceExtensions = [cstring"VK_KHR_swapchain"]
  
  var enabledVk10Features = VkPhysicalDeviceFeatures(
    samplerAnisotropy: VkBool32(1))
  
  var enabledVk12Features = VkPhysicalDeviceVulkan12Features(
    sType: PhysicalDeviceVulkan12Features,
    descriptorIndexing: VkBool32(1),
    shaderSampledImageArrayNonUniformIndexing: VkBool32(1),
    descriptorBindingVariableDescriptorCount: VkBool32(1),
    runtimeDescriptorArray: VkBool32(1),
    bufferDeviceAddress: VkBool32(1))
  
  var enabledVk13Features = VkPhysicalDeviceVulkan13Features(
    sType: PhysicalDeviceVulkan13Features,
    pNext: enabledVk12Features.addr,
    synchronization2: VkBool32(1),
    dynamicRendering: VkBool32(1))
  
  var deviceCI = VkDeviceCreateInfo(
    sType: DeviceCreateInfo,
    pNext: enabledVk13Features.addr,
    queueCreateInfoCount: 1,
    pQueueCreateInfos: queueCi.addr,
    enabledExtensionCount: deviceExtensions.len.uint32,
    ppEnabledExtensionNames: cast[cstringArray](deviceExtensions[0].addr),
    pEnabledFeatures: enabledVk10Features.addr)
  
  if vkCreateDevice(
    nariInstance.devices[nariInstance.deviceId],
    deviceCI.addr, nil, nariInstance.device.addr
    ) != VKSuccess: quit("Can't create device")
  
  info "Logical device created"
  vkGetDeviceQueue(
    nariInstance.device,
    nariInstance.familyIndices.graphicsFamily,
    0,
    nariInstance.queue.addr)

proc createSwapchain(nariInstance; w, h: int) =
  var surfaceCaps = default(VkSurfaceCapabilitiesKHR)
  if vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
    nariInstance.devices[nariInstance.deviceId],
    nariInstance.surface,
    surfaceCaps.addr) != VKSuccess: quit("Get surface caps error")

  let imageFormat = VK_FORMAT_B8G8R8A8_SRGB
  var swapchainCi = VkSwapchainCreateInfoKHR(
    sType: SwapchainCreateInfoKHR,
    surface: nariInstance.surface,
    minImageCount: surfaceCaps.minImageCount,
    imageFormat: imageFormat,
    imageColorSpace: VK_COLORSPACE_SRGB_NONLINEAR_KHR,
    imageExtent: VkExtent2D(
      width: w.uint32,
      height: h.uint32), # XXX: we can't use surfaceCaps.currentExtend due to siwin issue
    imageArrayLayers: 1,
    imageUsage: cast[VkImageUsageFlags](VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT),
    preTransform: VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
    compositeAlpha: VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    presentMode: VK_PRESENT_MODE_FIFO_KHR
  )

  if vkCreateSwapchainKHR(
    nariInstance.device, swapchainCi.addr,
    nil, nariInstance.swapchain.addr) != VKSuccess: quit("Can't create swapchain")
  
  info  "Created swapchain",
        format = swapchainCi.imageFormat,
        extent = [swapchainCi.imageExtent.width, swapchainCi.imageExtent.height],
        images = swapchainCi.minImageCount,
        p = cast[uint32](nariInstance.swapchain)


var nari = NariInstance()
let window = initGameWindow(nari)
let surface = cast[VkSurfaceKHR](window.vulkanSurface)
info "Vulkan initialized", vksurface = cast[uint64](surface)

nari.findDevices()
nari.findQueueFamilyIndices()
nari.peekDevice()

nari.allocator = PassthroughGpuAllocator[VulkanAllocModel].init(
  VulkanAllocModel.init(nari.device, nari.devices[nari.deviceId]))

info "Gallonim Passthrough GPU allocator initialized"

# depth attachment
proc findDepthFormat(): VkFormat =
  const formats = [VK_FORMAT_D32_SFLOAT_S8_UINT, VK_FORMAT_D24_UNORM_S8_UINT]
  result = formats[0]
  for i in formats:
    let formatProperties = VkFormatProperties2(sType:  FormatProperties2)
    vkGetPhysicalDeviceFormatProperties2(nari.devices[nari.deviceId], i, formatProperties.addr)
    if (
      formatProperties.formatProperties.optimalTilingFeatures.uint32 and
      VkFormatFeatureFlagBits.DepthStencilAttachmentBit.uint32) > 0'u32: return i
    # TODO: maybe there better way that work with sets like
    # cast[set[VkFormatFeatureFlagBits]](optimalTilingFeatures)

proc configureDepth(nariInstance; w, h: int) =
  # depth testing required for 3d games

  # This is basicly should be generated by render graph compiler.
  # I.e use depth resource => create this but I don't know how to formalize it
  # and is this realy correct
  let depthFormat = findDepthFormat()
  var depthImageCi = VkImageCreateInfo(
    sType: ImageCreateInfo,
    imageType: VK_IMAGE_TYPE_2D,
    format: depthFormat,
    extent: VkExtent3D(
      width: w.uint32,
      height: h.uint32,
      depth: 1),
    mipLevels: 1,
    arrayLayers: 1,
    samples: VK_SAMPLE_COUNT_1_BIT,
    tiling: VK_IMAGE_TILING_OPTIMAL,
    usage: VkImageUsageFlags(VkImageUsageFlagBits.DepthStencilAttachmentBit),
    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED
  )

  
  if vkCreateImage(
    nariInstance.device,
    depthImageCi.addr, nil,
    nariInstance.depthImage.addr
  ) != VkSuccess: quit("Can't create image")

  var memReq = default(VkMemoryRequirements)
  vkGetImageMemoryRequirements(nariInstance.device, nariInstance.depthImage, memReq.addr)


  var alloc = nariInstance.allocator.alloc(AllocDesc(
    size: memReq.size.uint64,
    alignment: memReq.alignment.uint64,
    memoryTypeBits: memReq.memoryTypeBits,
    location: GpuOnly,
    linear: true,
  ))

  if vkBindImageMemory(
    nariInstance.device, nariInstance.depthImage,
    cast[VkDeviceMemory](alloc.handle),
    VkDeviceSize(alloc.offset)) != VkSuccess: quit("Can't bind image memory")

  var depthViewCI = VkImageViewCreateInfo(
    sType: ImageViewCreateInfo,
    image: nariInstance.depthImage,
    viewType: VK_IMAGE_VIEW_TYPE_2D,
    format: depthFormat,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT),
      levelCount: 1, layerCount: 1
    )
  )

  if vkCreateImageView(
    nariInstance.device,
    depthViewCI.addr, nil,
    nariInstance.depthImageView.addr) != VkSuccess: quit("Can't create depth image view")
  
  info "depth attachment created"

# 3D rendering:

type Vertex = object
  pos: Vec3
  normal: Vec3
  uv: Vec2

proc makeBuffers(nariInstance) =

  let n = 0.57735026'f32
  var vertices: seq[Vertex] = @[
    Vertex(
      pos: vec3(0.25'f32, 0.25'f32, 0.25'f32),
      normal: vec3(n, n, n),
      uv: vec2(1.0'f32, 1.0'f32)
    ),
    Vertex(
      pos: vec3(-0.25'f32, -0.25'f32, 0.25'f32),
      normal: vec3(-n, -n, n),
      uv: vec2(0.0'f32, 1.0'f32)
    ),
    Vertex(
      pos: vec3(-0.25'f32, 0.25'f32, -0.25'f32),
      normal: vec3(-n, n, -n),
      uv: vec2(0.0'f32, 0.0'f32)
    ),
    Vertex(
      pos: vec3(0.25'f32, -0.25'f32, -0.25'f32),
      normal: vec3(n, -n, -n),
      uv: vec2(1.0'f32, 0.0'f32)
    )
  ]
  var indices: seq[uint16] = @[
    0'u16, 2'u16, 1'u16,
    0'u16, 1'u16, 3'u16,
    0'u16, 3'u16, 2'u16,
    1'u16, 2'u16, 3'u16
  ]

  var vBufSize = sizeof(Vertex) * vertices.len
  var iBufSize = sizeof(uint16) * indices.len # when it will work, try make sizeof(indices)
  var bufferCi =  VkBufferCreateInfo(
    sType: BufferCreateInfo,
    size: VkDeviceSize(vBufSize + iBufSize),
    usage: VkBufferUsageFlags(
      VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.uint32 or
      VK_BUFFER_USAGE_INDEX_BUFFER_BIT.uint32)
    # TODO: use {} operator or some better way to do it
  )

  var memReq = default(VkMemoryRequirements)

  if vkCreateBuffer(
    nariInstance.device,
    bufferCi.addr, nil,
    nariInstance.vertexBuffer.addr
  ) != VkSuccess: quit("Can't create vertex/index buffer")

  vkGetBufferMemoryRequirements(
    nariInstance.device,
    nariInstance.vertexBuffer,
    memReq.addr
  )

  var alloc = nariInstance.allocator.alloc(AllocDesc(
    size: memReq.size.uint64,
    alignment: memReq.alignment.uint64,
    memoryTypeBits: memReq.memoryTypeBits,
    location: CpuToGpu,
    linear: true,
  ))

  if vkBindBufferMemory(
    nariInstance.device,
    nariInstance.vertexBuffer,
    cast[VkDeviceMemory](alloc.handle),
    VkDeviceSize(alloc.offset)
  ) != VkSuccess: quit("Can't bind vertex/index buffer memory")

  let indicesStart = cast[pointer](cast[uint](alloc.mappedPtr) + uint(vBufSize))
  copyMem(alloc.mappedPtr, vertices[0].addr, vBufSize)
  copyMem(indicesStart, indices[0].addr, iBufSize)

  info "vertex/index buffer created"

run window, WindowEventsHandler(
  onResize: proc(e: ResizeEvent) =
    nari.createSwapchain(e.size.x, e.size.y)
    nari.configureDepth(e.size.x, e.size.y)
    nari.makeBuffers()
  ,
  onRender: proc(e: RenderEvent) =
    discard,
  onKey: proc(e: KeyEvent) =
    if e.pressed and e.key == Key.escape:
      close e.window)
