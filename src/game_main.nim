## The module that launches the game

import std/[math, sequtils, sets, times]
import pkg/siwin
import pkg/vulkan
import pkg/chronicles
import pkg/vmath
import pkg/gallonim
import ktx

const maxFramesInFlight {.define: "nari.maxFramesInFlight".} = 2

type
  Texture = object
    image: VkImage
    imageAlloc: Allocation
    view: VkImageView
    sampler: VkSampler

  # until render graph:
  ShaderData = object
    proj: Mat4
    view: Mat4
    model: array[3, Mat4]
    lightPos: Vec4 = vec4(0, -10, 10, 0)
    selected: uint32 = 1

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
    swapchainImages: seq[VkImage]
    swapchainImageViews: seq[VkImageView]
    allocator: PassthroughGpuAllocator[VulkanAllocModel] # TODO: implement freelist allocator etc.

    commandPool: VkCommandPool
    commandBuffers: array[maxFramesInFlight, VkCommandBuffer]

    # Until render graph integration:
    depthImage: VkImage
    depthImageView: VkImageView
    vertexBuffer: VkBuffer
    shaderDataBuffers: array[maxFramesInFlight, VkBuffer]
    shaderDataAllocs: array[maxFramesInFlight, Allocation]
    shaderDataAddresses: array[maxFramesInFlight, VkDeviceAddress]
    shaderData: array[maxFramesInFlight, ShaderData]
    # XXX: for render graph we need good way to define shader data, because this only for specific resource
    fences: array[maxFramesInFlight, VkFence]
    presentSemaphores: array[maxFramesInFlight, VkSemaphore]
    renderSemaphores: seq[VkSemaphore]

    textures: seq[Texture]
    textureDescriptors: seq[VkDescriptorImageInfo]
    descriptorPool: VkDescriptorPool
    descriptorSetLayoutTex: VkDescriptorSetLayout
    descriptorSetTex: VkDescriptorSet
    pipelineLayout: VkPipelineLayout
    pipeline: VkPipeline
    frameIndex: uint32
    indexCount: uint32
    vertexBufferSize: VkDeviceSize

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
    sType: InstanceCreateInfo,
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
    frameless = true, # TODO: implement qowldecor to replace libdecor and allow frame...
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
    shaderInt64: VkBool32(1),
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

  var enabledVk14Features = VkPhysicalDeviceVulkan14Features(
    sType: PhysicalDeviceVulkan14Features,
    pNext: enabledVk13Features.addr,
    maintenance5: VkBool32(1))
  
  var deviceCI = VkDeviceCreateInfo(
    sType: DeviceCreateInfo,
    pNext: enabledVk14Features.addr,
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

  for imageView in nariInstance.swapchainImageViews:
    vkDestroyImageView(nariInstance.device, imageView, nil)
  nariInstance.swapchainImageViews.shrink(0)

  let imageFormat = VK_FORMAT_B8G8R8A8_SRGB
  var swapchainCi = VkSwapchainCreateInfoKHR(
    sType: SwapchainCreateInfoKHR,
    surface: nariInstance.surface,
    oldSwapchain: nariInstance.swapchain,
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

  var imageCount = 0'u32
  if vkGetSwapchainImagesKHR(
    nariInstance.device,
    nariInstance.swapchain,
    imageCount.addr,
    nil
  ) != VKSuccess: quit("Can't get swapchain image count")
  nariInstance.swapchainImages = newSeq[VkImage](imageCount.int)

  if vkGetSwapchainImagesKHR(
    nariInstance.device,
    nariInstance.swapchain,
    imageCount.addr,
    nariInstance.swapchainImages[0].addr
  ) != VKSuccess: quit("Can't get swapchain images")
  nariInstance.swapchainImageViews = newSeq[VkImageView](imageCount.int)

  for i in 0 ..< imageCount.int:
    var imageViewCi = VkImageViewCreateInfo(
      sType: ImageViewCreateInfo,
      image: nariInstance.swapchainImages[i],
      viewType: VK_IMAGE_VIEW_TYPE_2D,
      format: imageFormat,
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        levelCount: 1,
        layerCount: 1
      )
    )

    if vkCreateImageView(
      nariInstance.device,
      imageViewCi.addr,
      nil,
      nariInstance.swapchainImageViews[i].addr
    ) != VKSuccess: quit("Can't create swapchain image view")

  if swapchainCi.oldSwapchain != VkSwapchainKHR(0):
    vkDestroySwapchainKHR(nariInstance.device, swapchainCi.oldSwapchain, nil)
  
  info  "Created swapchain",
        format = swapchainCi.imageFormat,
        extent = [swapchainCi.imageExtent.width, swapchainCi.imageExtent.height],
        images = imageCount,
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
  let s = 0.5'f32
  var vertices: seq[Vertex] = @[]
  var indices: seq[uint16] = @[]

  template addQuad(p0, p1, p2, p3: Vec3; n: Vec3) =
    let base = uint16(vertices.len)
    vertices.add Vertex(pos: p0, normal: n, uv: vec2(0, 1))
    vertices.add Vertex(pos: p1, normal: n, uv: vec2(1, 1))
    vertices.add Vertex(pos: p2, normal: n, uv: vec2(1, 0))
    vertices.add Vertex(pos: p3, normal: n, uv: vec2(0, 0))
    indices.add [base, base+1, base+2, base, base+2, base+3]

  addQuad(vec3(-s,-s, s), vec3( s,-s, s), vec3( s, s, s), vec3(-s, s, s), vec3( 0, 0, 1)) # front
  addQuad(vec3( s,-s,-s), vec3(-s,-s,-s), vec3(-s, s,-s), vec3( s, s,-s), vec3( 0, 0,-1)) # back
  addQuad(vec3( s,-s, s), vec3( s,-s,-s), vec3( s, s,-s), vec3( s, s, s), vec3( 1, 0, 0)) # right
  addQuad(vec3(-s,-s,-s), vec3(-s,-s, s), vec3(-s, s, s), vec3(-s, s,-s), vec3(-1, 0, 0)) # left
  addQuad(vec3(-s, s, s), vec3( s, s, s), vec3( s, s,-s), vec3(-s, s,-s), vec3( 0, 1, 0)) # top
  addQuad(vec3(-s,-s,-s), vec3( s,-s,-s), vec3( s,-s, s), vec3(-s,-s, s), vec3( 0,-1, 0)) # bottom

  var vBufSize = sizeof(Vertex) * vertices.len
  var iBufSize = sizeof(uint16) * indices.len # when it will work, try make sizeof(indices)
  nariInstance.vertexBufferSize = VkDeviceSize(vBufSize)
  nariInstance.indexCount = uint32(indices.len)
  var bufferCi =  VkBufferCreateInfo(
    sType: BufferCreateInfo,
    size: VkDeviceSize(vBufSize + iBufSize),
    usage: VkBufferUsageFlags{VertexBufferBit, IndexBufferBit}
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

proc makeShaderDataBuffers(nariInstance) =
  for i in 0..<maxFramesInFlight:
    var bufferCi = VkBufferCreateInfo(
      sType: BufferCreateInfo,
      size: VkDeviceSize(sizeof(ShaderData)),
      usage: VkBufferUsageFlags{ShaderDeviceAddressBit}
    )

    if vkCreateBuffer(
      nariInstance.device,
      bufferCi.addr, nil,
      nariInstance.shaderDataBuffers[i].addr
    ) != VkSuccess: quit("Can't create shader data buffer")

    var memReq = default(VkMemoryRequirements)
    vkGetBufferMemoryRequirements(
      nariInstance.device,
      nariInstance.shaderDataBuffers[i],
      memReq.addr
    )

    nariInstance.shaderDataAllocs[i] = nariInstance.allocator.alloc(AllocDesc(
      size: memReq.size.uint64,
      alignment: memReq.alignment.uint64,
      memoryTypeBits: memReq.memoryTypeBits,
      location: CpuToGpu,
      linear: true,
      deviceAddress: true,
    ))

    if vkBindBufferMemory(
      nariInstance.device,
      nariInstance.shaderDataBuffers[i],
      cast[VkDeviceMemory](nariInstance.shaderDataAllocs[i].handle),
      VkDeviceSize(nariInstance.shaderDataAllocs[i].offset)
    ) != VkSuccess: quit("Can't bind shader data buffer memory")

    var bdaInfo = VkBufferDeviceAddressInfo(
      sType: BufferDeviceAddressInfo,
      buffer: nariInstance.shaderDataBuffers[i])
    nariInstance.shaderDataAddresses[i] = vkGetBufferDeviceAddress(
      nariInstance.device, bdaInfo.addr)

  info "shader data buffers created"

proc createSemaphores(nariInstance) =
  var semaphoreCi = VkSemaphoreCreateInfo(
    sType: SemaphoreCreateInfo)
  var fenceCi = VkFenceCreateInfo(
    sType: FenceCreateInfo,
    flags: VkFenceCreateFlags{SignaledBit})

  for i in 0..<maxFramesInFlight:
    if vkCreateFence(
      nariInstance.device, fenceCi.addr, nil,
      nariInstance.fences[i].addr
    ) != VkSuccess: quit("Can't create fence")
    if vkCreateSemaphore(
      nariInstance.device, semaphoreCi.addr, nil,
      nariInstance.presentSemaphores[i].addr
    ) != VkSuccess: quit("Can't create present semaphore")

  nariInstance.renderSemaphores.setLen(nariInstance.swapchainImages.len)
  for semaphore in nariInstance.renderSemaphores.mitems:
    if vkCreateSemaphore(
      nariInstance.device, semaphoreCi.addr, nil,
      semaphore.addr
    ) != VkSuccess: quit("Can't create render semaphore")

  info "semaphores and fences created"

proc allocCommandBuffers(nariInstance) =
  var commandPoolCI = VkCommandPoolCreateInfo(
    sType: CommandPoolCreateInfo,
    flags: VkCommandPoolCreateFlags{ResetCommandBufferBit},
    queueFamilyIndex: nariInstance.familyIndices.graphicsFamily
  )
  if vkCreateCommandPool(
    nariInstance.device, commandPoolCI.addr,
    nil, nariInstance.commandPool.addr
  ) != VkSuccess: quit("Can't create command pool")

  var cbAllocCI = VkCommandBufferAllocateInfo(
    sType: CommandBufferAllocateInfo,
    commandPool: nariInstance.commandPool,
    commandBufferCount: maxFramesInFlight
  )
  if vkAllocateCommandBuffers(
    nariInstance.device, cbAllocCI.addr,
    nariInstance.commandBuffers[0].addr
  ) != VkSuccess: quit("Can't allocate command buffers")

  info "command buffers allocated"

proc loadTextures(nariInstance) =
  let filename = "assets/uv_checker.ktx"

  var ktxTexture: ptr KtxTexture = nil
  if ktxTexture_CreateFromNamedFile(
    filename.cstring, KtxTextureCreateLoadImageDataBit, ktxTexture.addr
  ) != KtxSuccess: quit("Can't load texture: " & filename)

  var tex = Texture()

  let texFormat = cast[VkFormat](ktxTexture_GetVkFormat(ktxTexture))
  var texImgCI = VkImageCreateInfo(
    sType: ImageCreateInfo,
    imageType: VK_IMAGE_TYPE_2D,
    format: texFormat,
    extent: VkExtent3D(width: ktxTexture.baseWidth, height: ktxTexture.baseHeight, depth: 1),
    mipLevels: ktxTexture.numLevels,
    arrayLayers: 1,
    samples: VK_SAMPLE_COUNT_1_BIT,
    tiling: VK_IMAGE_TILING_OPTIMAL,
    usage: VkImageUsageFlags(
      VkImageUsageFlagBits.TransferDstBit.uint32 or
      VkImageUsageFlagBits.SampledBit.uint32),
    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED
  )
  if vkCreateImage(nariInstance.device, texImgCI.addr, nil, tex.image.addr) != VkSuccess:
    quit("Can't create texture image")

  var memReq = default(VkMemoryRequirements)
  vkGetImageMemoryRequirements(nariInstance.device, tex.image, memReq.addr)
  tex.imageAlloc = nariInstance.allocator.alloc(AllocDesc(
    size: memReq.size.uint64,
    alignment: memReq.alignment.uint64,
    memoryTypeBits: memReq.memoryTypeBits,
    location: GpuOnly,
    linear: false,
  ))
  if vkBindImageMemory(
    nariInstance.device, tex.image,
    cast[VkDeviceMemory](tex.imageAlloc.handle),
    VkDeviceSize(tex.imageAlloc.offset)
  ) != VkSuccess: quit("Can't bind texture image memory")

  var texVewCI = VkImageViewCreateInfo(
    sType: ImageViewCreateInfo,
    image: tex.image,
    viewType: VK_IMAGE_VIEW_TYPE_2D,
    format: texFormat,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      levelCount: ktxTexture.numLevels,
      layerCount: 1
    )
  )
  if vkCreateImageView(nariInstance.device, texVewCI.addr, nil, tex.view.addr) != VkSuccess:
    quit("Can't create texture image view")

  var imgSrcBuffer = VkBuffer(0)
  var imgSrcBufferCI = VkBufferCreateInfo(
    sType: BufferCreateInfo,
    size: VkDeviceSize(ktxTexture.dataSize),
    usage: VkBufferUsageFlags(VkBufferUsageFlagBits.TransferSrcBit)
  )
  if vkCreateBuffer(nariInstance.device, imgSrcBufferCI.addr, nil, imgSrcBuffer.addr) != VkSuccess:
    quit("Can't create staging buffer")

  var stagingMemReq = default(VkMemoryRequirements)
  vkGetBufferMemoryRequirements(nariInstance.device, imgSrcBuffer, stagingMemReq.addr)
  var imgSrcAllocation = nariInstance.allocator.alloc(AllocDesc(
    size: stagingMemReq.size.uint64,
    alignment: stagingMemReq.alignment.uint64,
    memoryTypeBits: stagingMemReq.memoryTypeBits,
    location: CpuToGpu,
    linear: true,
  ))
  if vkBindBufferMemory(
    nariInstance.device, imgSrcBuffer,
    cast[VkDeviceMemory](imgSrcAllocation.handle),
    VkDeviceSize(imgSrcAllocation.offset)
  ) != VkSuccess: quit("Can't bind staging buffer memory")

  copyMem(imgSrcAllocation.mappedPtr, ktxTexture.pData, ktxTexture.dataSize)

  var fenceOneTimeCI = VkFenceCreateInfo(sType: FenceCreateInfo)
  var fenceOneTime = VkFence(0)
  if vkCreateFence(nariInstance.device, fenceOneTimeCI.addr, nil, fenceOneTime.addr) != VkSuccess:
    quit("Can't create fence")

  var cbOneTimeAI = VkCommandBufferAllocateInfo(
    sType: CommandBufferAllocateInfo,
    commandPool: nariInstance.commandPool,
    commandBufferCount: 1
  )
  var cbOneTime = VkCommandBuffer(0)
  if vkAllocateCommandBuffers(nariInstance.device, cbOneTimeAI.addr, cbOneTime.addr) != VkSuccess:
    quit("Can't allocate command buffer")

  var cbOneTimeBI = VkCommandBufferBeginInfo(
    sType: CommandBufferBeginInfo,
    flags: VkCommandBufferUsageFlags{OneTimeSubmitBit}
  )
  if vkBeginCommandBuffer(cbOneTime, cbOneTimeBI.addr) != VkSuccess: quit("Can't begin command buffer")

  var barrierTexImage = VkImageMemoryBarrier2(
    sType: ImageMemoryBarrier2,
    srcStageMask: VkPipelineStageFlags2{VkPipelineStageFlagBits2.None},
    srcAccessMask: VkAccessFlags2{VkAccessFlagBits2.None},
    dstStageMask: VkPipelineStageFlags2{AllTransferBit},
    dstAccessMask: VkAccessFlags2{TransferWriteBit},
    oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
    newLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    image: tex.image,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      levelCount: ktxTexture.numLevels, layerCount: 1
    )
  )
  var barrierTexInfo = VkDependencyInfo(
    sType: DependencyInfo,
    imageMemoryBarrierCount: 1,
    pImageMemoryBarriers: barrierTexImage.addr
  )
  vkCmdPipelineBarrier2(cbOneTime, barrierTexInfo.addr)

  var copyRegions = newSeq[VkBufferImageCopy](ktxTexture.numLevels.int)
  for j in 0..<ktxTexture.numLevels.int:
    var mipOffset: csize_t = 0
    discard ktxTexture2_GetImageOffset(
      ktxTexture, j.uint32, 0, 0, mipOffset.addr)

    copyRegions[j] = VkBufferImageCopy(
      bufferOffset: VkDeviceSize(mipOffset),
      imageSubresource: VkImageSubresourceLayers(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        mipLevel: j.uint32,
        layerCount: 1
      ),
      imageExtent: VkExtent3D(
        width: ktxTexture.baseWidth shr j,
        height: ktxTexture.baseHeight shr j,
        depth: 1
      )
    )

  vkCmdCopyBufferToImage(
    cbOneTime, imgSrcBuffer, tex.image,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    copyRegions.len.uint32, copyRegions[0].addr
  )

  var barrierTexRead = VkImageMemoryBarrier2(
    sType: ImageMemoryBarrier2,
    srcStageMask: VkPipelineStageFlags2{AllTransferBit},
    srcAccessMask: VkAccessFlags2{TransferWriteBit},
    dstStageMask: VkPipelineStageFlags2{FragmentShaderBit},
    dstAccessMask: VkAccessFlags2{ShaderReadBit},
    oldLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    newLayout: ReadOnlyOptimal,
    image: tex.image,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      levelCount: ktxTexture.numLevels, layerCount: 1
    )
  )
  barrierTexInfo.pImageMemoryBarriers = barrierTexRead.addr
  vkCmdPipelineBarrier2(cbOneTime, barrierTexInfo.addr)

  if vkEndCommandBuffer(cbOneTime) != VkSuccess:
    quit("Can't end command buffer")

  var oneTimeSI = VkSubmitInfo(
    sType: SubmitInfo,
    commandBufferCount: 1,
    pCommandBuffers: cbOneTime.addr
  )
  if vkQueueSubmit(nariInstance.queue, 1, oneTimeSI.addr, fenceOneTime) != VkSuccess:
    quit("Can't submit queue")
  if vkWaitForFences(
    nariInstance.device, 1, fenceOneTime.addr, VkBool32(1), uint64.high
  ) != VkSuccess: quit("Waiting for fence failed")

  vkDestroyFence(nariInstance.device, fenceOneTime, nil)
  vkFreeCommandBuffers(nariInstance.device, nariInstance.commandPool, 1, cbOneTime.addr)
  vkDestroyBuffer(nariInstance.device, imgSrcBuffer, nil)
  nariInstance.allocator.free(imgSrcAllocation)

  var samplerCI = VkSamplerCreateInfo(
    sType: SamplerCreateInfo,
    magFilter: VK_FILTER_LINEAR,
    minFilter: VK_FILTER_LINEAR,
    mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
    anisotropyEnable: VkBool32(1),
    maxAnisotropy: 8.0,
    maxLod: float32(ktxTexture.numLevels)
  )
  if vkCreateSampler(nariInstance.device, samplerCI.addr, nil, tex.sampler.addr) != VkSuccess:
    quit("Can't create sampler")

  ktxTexture_Destroy(ktxTexture)
  nariInstance.textures.add(tex)
  nariInstance.textureDescriptors.add(VkDescriptorImageInfo(
    sampler: tex.sampler,
    imageView: tex.view,
    imageLayout: ReadOnlyOptimal
  ))

  var descVariableFlag = VkDescriptorBindingFlags{VariableDescriptorCountBit}
  var descBindingFlags = VkDescriptorSetLayoutBindingFlagsCreateInfo(
    sType: DescriptorSetLayoutBindingFlagsCreateInfo,
    bindingCount: 1,
    pBindingFlags: descVariableFlag.addr
  )
  var descLayoutBindingTex = VkDescriptorSetLayoutBinding(
    descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    descriptorCount: uint32(nariInstance.textures.len),
    stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT)
  )
  var descLayoutTexCI = VkDescriptorSetLayoutCreateInfo(
    sType: DescriptorSetLayoutCreateInfo,
    pNext: descBindingFlags.addr,
    bindingCount: 1,
    pBindings: descLayoutBindingTex.addr
  )
  if vkCreateDescriptorSetLayout(
    nariInstance.device, descLayoutTexCI.addr, nil,
    nariInstance.descriptorSetLayoutTex.addr
  ) != VkSuccess: quit("Can't create descriptor set layout")

  var poolSize = VkDescriptorPoolSize(
    `type`: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    descriptorCount: uint32(nariInstance.textures.len)
  )
  var descPoolCI = VkDescriptorPoolCreateInfo(
    sType: DescriptorPoolCreateInfo,
    maxSets: 1,
    poolSizeCount: 1,
    pPoolSizes: poolSize.addr
  )
  if vkCreateDescriptorPool(
    nariInstance.device, descPoolCI.addr, nil,
    nariInstance.descriptorPool.addr
  ) != VkSuccess: quit("Can't create descriptor pool")

  var variableDescCount = uint32(nariInstance.textures.len)
  var variableDescCountAI = VkDescriptorSetVariableDescriptorCountAllocateInfo(
    sType: DescriptorSetVariableDescriptorCountAllocateInfo,
    descriptorSetCount: 1,
    pDescriptorCounts: variableDescCount.addr
  )
  var texDescSetAlloc = VkDescriptorSetAllocateInfo(
    sType: DescriptorSetAllocateInfo,
    pNext: variableDescCountAI.addr,
    descriptorPool: nariInstance.descriptorPool,
    descriptorSetCount: 1,
    pSetLayouts: nariInstance.descriptorSetLayoutTex.addr
  )
  if vkAllocateDescriptorSets(
    nariInstance.device, texDescSetAlloc.addr,
    nariInstance.descriptorSetTex.addr
  ) != VkSuccess: quit("Can't allocate descriptor set")

  var writeDescSet = VkWriteDescriptorSet(
    sType: WriteDescriptorSet,
    dstSet: nariInstance.descriptorSetTex,
    dstBinding: 0,
    descriptorCount: uint32(nariInstance.textureDescriptors.len),
    descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    pImageInfo: nariInstance.textureDescriptors[0].addr
  )
  vkUpdateDescriptorSets(nariInstance.device, 1, writeDescSet.addr, 0, nil)

  info "textures loaded"

proc createPipeline(nariInstance) =
  let vertSpirv = readFile("src/shaders/shader.vert.spv")
  let fragSpirv = readFile("src/shaders/shader.frag.spv")

  var vertShaderModuleCI = VkShaderModuleCreateInfo(
    sType: ShaderModuleCreateInfo,
    codeSize: vertSpirv.len.uint,
    pCode: cast[ptr uint32](vertSpirv[0].addr)
  )
  var fragShaderModuleCI = VkShaderModuleCreateInfo(
    sType: ShaderModuleCreateInfo,
    codeSize: fragSpirv.len.uint,
    pCode: cast[ptr uint32](fragSpirv[0].addr)
  )

  var shaderStages = [
    VkPipelineShaderStageCreateInfo(
      sType: PipelineShaderStageCreateInfo,
      pNext: vertShaderModuleCI.addr,
      stage: VK_SHADER_STAGE_VERTEX_BIT,
      pName: "main"
    ),
    VkPipelineShaderStageCreateInfo(
      sType: PipelineShaderStageCreateInfo,
      pNext: fragShaderModuleCI.addr,
      stage: FragmentBit,
      pName: "main"
    )
  ]

  var pushConstantRange = VkPushConstantRange(
    stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT),
    size: uint32(sizeof(VkDeviceAddress))
  )
  var pipelineLayoutCI = VkPipelineLayoutCreateInfo(
    sType: PipelineLayoutCreateInfo,
    setLayoutCount: 1,
    pSetLayouts: nariInstance.descriptorSetLayoutTex.addr,
    pushConstantRangeCount: 1,
    pPushConstantRanges: pushConstantRange.addr
  )
  if vkCreatePipelineLayout(
    nariInstance.device, pipelineLayoutCI.addr, nil,
    nariInstance.pipelineLayout.addr
  ) != VkSuccess: quit("Can't create pipeline layout")

  var vertexBinding = VkVertexInputBindingDescription(
    binding: 0,
    stride: uint32(sizeof(Vertex)),
    inputRate: VK_VERTEX_INPUT_RATE_VERTEX
  )
  var vertexAttributes = [
    VkVertexInputAttributeDescription(location: 0, binding: 0, format: VK_FORMAT_R32G32B32_SFLOAT, offset: 0),
    VkVertexInputAttributeDescription(location: 1, binding: 0, format: VK_FORMAT_R32G32B32_SFLOAT, offset: uint32(sizeof(Vec3))),
    VkVertexInputAttributeDescription(location: 2, binding: 0, format: VK_FORMAT_R32G32_SFLOAT, offset: uint32(sizeof(Vec3) * 2))
  ]
  var vertexInputState = VkPipelineVertexInputStateCreateInfo(
    sType: PipelineVertexInputStateCreateInfo,
    vertexBindingDescriptionCount: 1,
    pVertexBindingDescriptions: vertexBinding.addr,
    vertexAttributeDescriptionCount: uint32(vertexAttributes.len),
    pVertexAttributeDescriptions: vertexAttributes[0].addr
  )
  var inputAssemblyState = VkPipelineInputAssemblyStateCreateInfo(
    sType: PipelineInputAssemblyStateCreateInfo,
    topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
  )
  var viewportState = VkPipelineViewportStateCreateInfo(
    sType: PipelineViewportStateCreateInfo,
    viewportCount: 1,
    scissorCount: 1
  )
  var dynamicStates = [Viewport, Scissor]
  var dynamicState = VkPipelineDynamicStateCreateInfo(
    sType: PipelineDynamicStateCreateInfo,
    dynamicStateCount: uint32(dynamicStates.len),
    pDynamicStates: dynamicStates[0].addr
  )
  var depthStencilState = VkPipelineDepthStencilStateCreateInfo(
    sType: PipelineDepthStencilStateCreateInfo,
    depthTestEnable: VkBool32(1),
    depthWriteEnable: VkBool32(1),
    depthCompareOp: VK_COMPARE_OP_LESS_OR_EQUAL
  )

  var imageFormat = VK_FORMAT_B8G8R8A8_SRGB
  let depthFormat = findDepthFormat()
  var renderingCI = VkPipelineRenderingCreateInfo(
    sType: PipelineRenderingCreateInfo,
    colorAttachmentCount: 1,
    pColorAttachmentFormats: imageFormat.addr,
    depthAttachmentFormat: depthFormat
  )

  var blendAttachment = VkPipelineColorBlendAttachmentState(
    colorWriteMask: VkColorComponentFlags{RBit, GBit, BBit, ABit}
  )
  var colorBlendState = VkPipelineColorBlendStateCreateInfo(
    sType: PipelineColorBlendStateCreateInfo,
    attachmentCount: 1,
    pAttachments: blendAttachment.addr
  )
  var rasterizationState = VkPipelineRasterizationStateCreateInfo(
    sType: PipelineRasterizationStateCreateInfo,
    lineWidth: 1.0
  )
  var multisampleState = VkPipelineMultisampleStateCreateInfo(
    sType: PipelineMultisampleStateCreateInfo,
    rasterizationSamples: VK_SAMPLE_COUNT_1_BIT
  )

  var pipelineCI = VkGraphicsPipelineCreateInfo(
    sType: GraphicsPipelineCreateInfo,
    pNext: renderingCI.addr,
    stageCount: uint32(shaderStages.len),
    pStages: shaderStages[0].addr,
    pVertexInputState: vertexInputState.addr,
    pInputAssemblyState: inputAssemblyState.addr,
    pViewportState: viewportState.addr,
    pRasterizationState: rasterizationState.addr,
    pMultisampleState: multisampleState.addr,
    pDepthStencilState: depthStencilState.addr,
    pColorBlendState: colorBlendState.addr,
    pDynamicState: dynamicState.addr,
    layout: nariInstance.pipelineLayout
  )
  if vkCreateGraphicsPipelines(
    nariInstance.device, VkPipelineCache(0), 1, pipelineCI.addr, nil,
    nariInstance.pipeline.addr
  ) != VkSuccess: quit("Can't create graphics pipeline")

  info "graphics pipeline created"

var lastWindowSize = ivec2(0, 0)
var camDist = -8.0'f32
var camRotation = vec2(0.0'f32, 0.0'f32)
var keysDown = initHashSet[Key]()

proc renderFrame(nariInstance; w, h: int) =
  let fi = nariInstance.frameIndex

  if vkWaitForFences(nariInstance.device, 1, nariInstance.fences[fi].addr, VkBool32(1), uint64.high) != VkSuccess:
    quit("Waiting for fence failed")
  if vkResetFences(nariInstance.device, 1, nariInstance.fences[fi].addr) != VkSuccess:
    quit("Can't reset fence")

  var imageIndex: uint32 = 0
  let acquireResult = vkAcquireNextImageKHR(
    nariInstance.device, nariInstance.swapchain, uint64.high,
    nariInstance.presentSemaphores[fi], VkFence(0), imageIndex.addr)
  if acquireResult != VkSuccess and acquireResult != VkSuboptimalKhr:
    quit("Can't acquire next image")

  var proj = perspective(45.0'f32, float32(w) / float32(h), 0.1'f32, 32.0'f32)
  # remap opengl z [-1,1] to vulkan [0,1] (vmath uses opengl convention)
  proj[2, 2] = proj[2, 2] * 0.5'f32 + proj[2, 3] * 0.5'f32
  proj[3, 2] = proj[3, 2] * 0.5'f32 + proj[3, 3] * 0.5'f32
  nariInstance.shaderData[fi].proj = proj
  nariInstance.shaderData[fi].view = translate(vec3(0, 0, camDist)) * rotateX(camRotation.x) * rotateY(camRotation.y)
  for i in 0..2:
    let instancePos = vec3(float32(i - 1) * 3.0'f32, 0.0'f32, 0.0'f32)
    nariInstance.shaderData[fi].model[i] = translate(instancePos)

  copyMem(
    nariInstance.shaderDataAllocs[fi].mappedPtr,
    nariInstance.shaderData[fi].addr,
    sizeof(ShaderData))

  let cb = nariInstance.commandBuffers[fi]
  if vkResetCommandBuffer(cb, VkCommandBufferResetFlags(0)) != VkSuccess:
    quit("Can't reset command buffer")

  var cbBI = VkCommandBufferBeginInfo(
    sType: CommandBufferBeginInfo,
    flags: VkCommandBufferUsageFlags{OneTimeSubmitBit})
  if vkBeginCommandBuffer(cb, cbBI.addr) != VkSuccess:
    quit("Can't begin command buffer")

  var outputBarriers = [
    VkImageMemoryBarrier2(
      sType: ImageMemoryBarrier2,
      srcStageMask: VkPipelineStageFlags2{ColorAttachmentOutputBit},
      srcAccessMask: VkAccessFlags2{VkAccessFlagBits2.None},
      dstStageMask: VkPipelineStageFlags2{ColorAttachmentOutputBit},
      dstAccessMask: VkAccessFlags2{ColorAttachmentReadBit, ColorAttachmentWriteBit},
      oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
      newLayout: AttachmentOptimal,
      image: nariInstance.swapchainImages[imageIndex],
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        levelCount: 1, layerCount: 1)
    ),
    VkImageMemoryBarrier2(
      sType: ImageMemoryBarrier2,
      srcStageMask: VkPipelineStageFlags2{LateFragmentTestsBit},
      srcAccessMask: VkAccessFlags2{DepthStencilAttachmentWriteBit},
      dstStageMask: VkPipelineStageFlags2{EarlyFragmentTestsBit},
      dstAccessMask: VkAccessFlags2{DepthStencilAttachmentWriteBit},
      oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
      newLayout: AttachmentOptimal,
      image: nariInstance.depthImage,
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(
          VK_IMAGE_ASPECT_DEPTH_BIT.uint32 or VK_IMAGE_ASPECT_STENCIL_BIT.uint32),
        levelCount: 1, layerCount: 1)
    )
  ]
  var barrierDependencyInfo = VkDependencyInfo(
    sType: DependencyInfo,
    imageMemoryBarrierCount: uint32(outputBarriers.len),
    pImageMemoryBarriers: outputBarriers[0].addr)
  vkCmdPipelineBarrier2(cb, barrierDependencyInfo.addr)

  var colorAttachmentInfo = VkRenderingAttachmentInfo(
    sType: RenderingAttachmentInfo,
    imageView: nariInstance.swapchainImageViews[imageIndex],
    imageLayout: AttachmentOptimal,
    loadOp: Clear,
    storeOp: Store,
    clearValue: VkClearValue(color: VkClearColorValue(float32: [1.0'f32, 0.6'f32, 0.2'f32, 1.0'f32]))
  )
  var depthAttachmentInfo = VkRenderingAttachmentInfo(
    sType: RenderingAttachmentInfo,
    imageView: nariInstance.depthImageView,
    imageLayout: AttachmentOptimal,
    loadOp: Clear,
    storeOp: DontCare,
    clearValue: VkClearValue(depthStencil: VkClearDepthStencilValue(depth: 1.0'f32, stencil: 0))
  )
  var renderingInfo = VkRenderingInfo(
    sType: RenderingInfo,
    renderArea: VkRect2D(extent: VkExtent2D(width: w.uint32, height: h.uint32)),
    layerCount: 1,
    colorAttachmentCount: 1,
    pColorAttachments: colorAttachmentInfo.addr,
    pDepthAttachment: depthAttachmentInfo.addr)

  vkCmdBeginRendering(cb, renderingInfo.addr)


  var vp = VkViewport(
    y: float32(h), width: float32(w), height: -float32(h),
    minDepth: 0.0, maxDepth: 1.0)
  vkCmdSetViewport(cb, 0, 1, vp.addr)
  var scissor = VkRect2D(extent: VkExtent2D(width: w.uint32, height: h.uint32))
  vkCmdSetScissor(cb, 0, 1, scissor.addr)
  vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, nariInstance.pipeline)
  vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, nariInstance.pipelineLayout,
    0, 1, nariInstance.descriptorSetTex.addr, 0, nil)
  var vOffset = VkDeviceSize(0)
  vkCmdBindVertexBuffers(cb, 0, 1, nariInstance.vertexBuffer.addr, vOffset.addr)
  vkCmdBindIndexBuffer(cb, nariInstance.vertexBuffer, nariInstance.vertexBufferSize, VK_INDEX_TYPE_UINT16)
  vkCmdPushConstants(cb, nariInstance.pipelineLayout,
    VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT), 0,
    uint32(sizeof(VkDeviceAddress)), nariInstance.shaderDataAddresses[fi].addr)
  vkCmdDrawIndexed(cb, nariInstance.indexCount, 3, 0, 0, 0)


  vkCmdEndRendering(cb)

  var barrierPresent = VkImageMemoryBarrier2(
    sType: ImageMemoryBarrier2,
    srcStageMask: VkPipelineStageFlags2{ColorAttachmentOutputBit},
    srcAccessMask: VkAccessFlags2{ColorAttachmentWriteBit},
    dstStageMask: VkPipelineStageFlags2{ColorAttachmentOutputBit},
    dstAccessMask: VkAccessFlags2{VkAccessFlagBits2.None},
    oldLayout: AttachmentOptimal,
    newLayout: PresentSrcKhr,
    image: nariInstance.swapchainImages[imageIndex],
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      levelCount: 1, layerCount: 1)
  )
  var barrierPresentInfo = VkDependencyInfo(
    sType: DependencyInfo,
    imageMemoryBarrierCount: 1,
    pImageMemoryBarriers: barrierPresent.addr)
  vkCmdPipelineBarrier2(cb, barrierPresentInfo.addr)

  if vkEndCommandBuffer(cb) != VkSuccess:
    quit("Can't end command buffer")

  var waitStage = VkPipelineStageFlags{ColorAttachmentOutputBit}
  var submitInfo = VkSubmitInfo(
    sType: SubmitInfo,
    waitSemaphoreCount: 1,
    pWaitSemaphores: nariInstance.presentSemaphores[fi].addr,
    pWaitDstStageMask: waitStage.addr,
    commandBufferCount: 1,
    pCommandBuffers: cb.unsafeAddr,
    signalSemaphoreCount: 1,
    pSignalSemaphores: nariInstance.renderSemaphores[imageIndex].addr)
  if vkQueueSubmit(nariInstance.queue, 1, submitInfo.addr, nariInstance.fences[fi]) != VkSuccess:
    quit("Can't submit queue")

  nariInstance.frameIndex = (fi + 1) mod uint32(maxFramesInFlight)

  var presentInfo = VkPresentInfoKHR(
    sType: PresentInfoKHR,
    waitSemaphoreCount: 1,
    pWaitSemaphores: nariInstance.renderSemaphores[imageIndex].addr,
    swapchainCount: 1,
    pSwapchains: nariInstance.swapchain.addr,
    pImageIndices: imageIndex.addr)
  discard vkQueuePresentKHR(nariInstance.queue, presentInfo.addr)

proc cleanupSwapchainResources(nariInstance) =
  discard vkDeviceWaitIdle(nariInstance.device)
  vkDestroyImageView(nariInstance.device, nariInstance.depthImageView, nil)
  vkDestroyImage(nariInstance.device, nariInstance.depthImage, nil)
  vkDestroyBuffer(nariInstance.device, nariInstance.vertexBuffer, nil)
  for i in 0..<maxFramesInFlight:
    vkDestroyBuffer(nariInstance.device, nariInstance.shaderDataBuffers[i], nil)
    nariInstance.allocator.free(nariInstance.shaderDataAllocs[i])
    vkDestroyFence(nariInstance.device, nariInstance.fences[i], nil)
    vkDestroySemaphore(nariInstance.device, nariInstance.presentSemaphores[i], nil)
  for semaphore in nariInstance.renderSemaphores:
    vkDestroySemaphore(nariInstance.device, semaphore, nil)
  vkDestroyCommandPool(nariInstance.device, nariInstance.commandPool, nil)

run window, WindowEventsHandler(
  onResize: proc(e: ResizeEvent) =
    if not e.initial and e.size == lastWindowSize: return
    lastWindowSize = e.size
    if not e.initial:
      nari.cleanupSwapchainResources()
    nari.createSwapchain(e.size.x, e.size.y)
    nari.configureDepth(e.size.x, e.size.y)
    nari.makeBuffers()
    nari.makeShaderDataBuffers()
    nari.createSemaphores()
    nari.allocCommandBuffers()
    if e.initial:
      nari.loadTextures()
      nari.createPipeline()
  ,
  onTick: proc(e: TickEvent) =
    let dt = float32(e.deltaTime.inMicroseconds) / 1_000_000.0'f32
    let speed = 2.0'f32
    if Key.w in keysDown: camRotation.x -= speed * dt
    if Key.s in keysDown: camRotation.x += speed * dt
    if Key.a in keysDown: camRotation.y -= speed * dt
    if Key.d in keysDown: camRotation.y += speed * dt,
  onRender: proc(e: RenderEvent) =
    let sz = e.window.size
    if sz.x > 0 and sz.y > 0:
      nari.renderFrame(sz.x, sz.y)
    redraw e.window
  ,
  onScroll: proc(e: ScrollEvent) =
    camDist += float32(e.delta) * 0.5'f32,
  onKey: proc(e: KeyEvent) =
    if e.pressed: keysDown.incl(e.key)
    else: keysDown.excl(e.key)
    if e.pressed and e.key == Key.escape:
      close e.window)
