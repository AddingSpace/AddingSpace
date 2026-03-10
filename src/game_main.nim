## The module that launches the game

import std/sequtils
import pkg/siwin
import pkg/vulkan
import pkg/chronicles

var siwinGlobals = newSiwinGlobals()
vkPreload() # load vulkan

proc initGameWindow(): window.Window =
  var appInfo = newVkApplicationInfo(
    pApplicationName = "Adding Space",
    applicationVersion = vkMakeVersion(0, 1, 0, 0),
    pEngineName = "Renderer",
    engineVersion = vkMakeVersion(0, 1, 0, 0),
    apiVersion = vkApiVersion1_3
  )

  let exts = getRequiredVulkanExtensions()
  let extsC = exts.mapIt(cstring(it))

  var instanceCreateInfo = VkInstanceCreateInfo(
    sType: VkStructureType.InstanceCreateInfo,
    pApplicationInfo: appInfo.addr,
    enabledLayerCount: 0,
    ppEnabledLayerNames: nil,
    enabledExtensionCount: uint32(extsC.len),
    ppEnabledExtensionNames:
      if extsC.len == 0: nil
      else: cast[cstringArray](extsC[0].addr),
  )

  var instance = VkInstance(0)
  if vkCreateInstance(instanceCreateInfo.addr, nil, instance.addr) != VKSuccess:
    quit("Failed to create Vulkan instance")

  vkInit(instance)

  # it's incredible but we need to create a window bound to the vulkan instance
  newVulkanWindow(
    siwinGlobals,
    cast[pointer](instance),
    title = "Adding Space")


let window = initGameWindow()
let surface = cast[VkSurfaceKHR](window.vulkanSurface)
info "Vulkan initialized", vksurface = cast[uint64](surface)

run window, WindowEventsHandler(
  onResize: proc(e: ResizeEvent) =
    discard,
  onRender: proc(e: RenderEvent) =
    discard,
  onKey: proc(e: KeyEvent) =
    if e.pressed and e.key == Key.escape:
      close e.window)

