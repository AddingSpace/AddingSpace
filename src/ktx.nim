# libktx bindings for texture loading
{.passL: "-lktx".}

type
  KtxErrorCode* {.importc: "KTX_error_code", header: "<ktx.h>".} = distinct int32
  KtxTextureCreateFlags* {.importc: "ktxTextureCreateFlags", header: "<ktx.h>".} = distinct uint32
  KtxTexture* {.importc: "ktxTexture", header: "<ktx.h>".} = object
    baseWidth*  {.importc: "baseWidth".}:  uint32
    baseHeight* {.importc: "baseHeight".}: uint32
    numLevels*  {.importc: "numLevels".}:  uint32
    dataSize*   {.importc: "dataSize".}:   csize_t
    pData*      {.importc: "pData".}:      ptr uint8
  KtxTexture2 {.importc: "ktxTexture2", header: "<ktx.h>".} = object

proc `==`*(a, b: KtxErrorCode): bool {.borrow.}

const
  KtxSuccess* = KtxErrorCode(0)
  KtxTextureCreateLoadImageDataBit* = KtxTextureCreateFlags(0x01)

proc ktxTexture_CreateFromNamedFile*(
  filename: cstring,
  createFlags: KtxTextureCreateFlags,
  newTex: ptr ptr KtxTexture): KtxErrorCode
  {.importc: "ktxTexture_CreateFromNamedFile", header: "<ktx.h>".}

proc ktxTexture_GetVkFormat*(tex: ptr KtxTexture): uint32
  {.importc: "ktxTexture_GetVkFormat".}

proc ktxTexture2_GetImageOffset_impl(
  tex: ptr KtxTexture2,
  level, layer, faceSlice: uint32,
  pOffset: ptr csize_t): KtxErrorCode
  {.importc: "ktxTexture2_GetImageOffset", header: "<ktx.h>".}

proc ktxTexture2_Destroy_impl(tex: ptr KtxTexture2)
  {.importc: "ktxTexture2_Destroy", header: "<ktx.h>".}

proc ktxTexture2_GetImageOffset*(tex: ptr KtxTexture, level, layer, faceSlice: uint32,
    pOffset: ptr csize_t): KtxErrorCode =
  ktxTexture2_GetImageOffset_impl(cast[ptr KtxTexture2](tex), level, layer, faceSlice, pOffset)

proc ktxTexture2_Destroy*(tex: ptr KtxTexture) =
  ktxTexture2_Destroy_impl(cast[ptr KtxTexture2](tex))

proc ktxTexture_Destroy*(tex: ptr KtxTexture) =
  # Maybe better to use generic version but it is macro if
  # I remember correctly
  ktxTexture2_Destroy_impl(cast[ptr KtxTexture2](tex))
