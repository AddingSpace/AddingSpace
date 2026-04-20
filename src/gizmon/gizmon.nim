import pkg/vmath

type
  GizmoRenderCmdKind = enum
    # byte
    Disc
    Plane
    Ring
    Line
    Ray
  
  GizmoTip* = enum
    # TODO: use msdf 3d image and use real 3d object...
    None
    Arrow

  GizmoRenderCmd = object
    # 16 bytes
    # Engeneering good layout is hard...
    # TODO: tip should be refactored to handle msdf 3d image! 
    # BECAUSE I WANT RENDER DIFFERENT CUSTOM SHAPES FOR GIZMO (CONE for move gizmo, LAMP 3d model for lights, ue like CAMERA 3d model)
    shape0: Vec4 # normal.xyz, radius; allow us drawing `Disc` and `Plane`

    shape1: Vec4 # dir.xy, reserved, reserved; allow us drawing `Line`
                 # If in future it will require more slots, we can change pos.xy, dir.xy into polar system (angle, a, b) i.e we have one slot

    color0: Vec4 # color.rgb, thickness

    meta0: UVec4 # kind, tip, clipped, reserved; clipped can be replaced by radius <= 0.0 check

  GizmoDrawer* = object
    # TODO: maybe add generic specialization for 2d games??
    # Should this refactored into CoordSystem object?
    objectPos*: Vec3
    thickness*: float32 # TODO: maybe refactor thickness into axis/ring proc field?
    cmdList: seq[GizmoRenderCmd]

  GizmoPlane* = object
    normal: Vec3
    currentRadius: float32 = -1 # <= 0.0 means not clipped

proc init(
  _: type GizmoRenderCmd,
  kind: GizmoRenderCmdKind,
  tip: GizmoTip,
  planeNormal: Vec3,
  radius: float32,
  thickness: float32,
  dir: Vec2,
  color: Vec3): GizmoRenderCmd =

  GizmoRenderCmd(
    shape0: vec4(planeNormal, radius),
    shape1: vec4(dir, vec2(0, 0)),
    color0: vec4(color, thickness),
    meta0: uvec4(uint8(kind), uint8(tip), uint8(radius <= 0.0), 0))

proc `$`(cmd: GizmoRenderCmd): string =
  result = "GizmoRenderCmd(\n"
  result.add "  kind: " & $GizmoRenderCmdKind(cmd.meta0.x) & '\n'
  result.add "  planeNormal:  " & $cmd.shape0.xy & '\n'
  result.add "  radius:  " & $cmd.shape0.zw & '\n'
  result.add "  tip:  " & $GizmoTip(cmd.meta0.y) & '\n'
  result.add "  clipped:  " & $bool(cmd.meta0.z) & '\n'
  result.add "  planeNormal:  " & $cmd.shape0.xyz & '\n'
  result.add "  dir:  " & $cmd.shape1.xy & '\n'
  result.add "  thickness:  " & $cmd.color0.w & '\n'
  result.add "  color:  " & $cmd.color0.xyz & '\n'
  result.add ')'

proc init*(
    _: type GizmoDrawer,
    thickness: float32 = 1.0): GizmoDrawer =
  GizmoDrawer(thickness: thickness)

proc plane*(drawer: var GizmoDrawer; normal: Vec3): GizmoPlane =
  GizmoPlane(normal: normal)

proc clipped(plane: GizmoPlane): bool = plane.currentRadius <= 0.0

proc far*(
    _: var GizmoDrawer;
    plane: var GizmoPlane,
    radius: float32) =
  plane.currentRadius = radius

proc offset*(
    _: var GizmoDrawer;
    plane: var GizmoPlane,
    gap: float32) =
  plane.currentRadius -= gap

proc disc*(
    drawer: var GizmoDrawer;
    plane: var GizmoPlane,
    color: Vec3) =
  # TODO: onDrag, it will hard and maybe will need
  # big refactor of onDrag API
  drawer.cmdList.add GizmoRenderCmd.init(
    kind =
      if plane.clipped: Disc
      else: Plane
    ,
    tip = None,
    planeNormal = plane.normal,
    radius = plane.currentRadius,
    thickness = drawer.thickness,
    dir = vec2(0, 0), # don't care
    color = color)

proc ring*(
    drawer: var GizmoDrawer;
    plane: var GizmoPlane,
    color: Vec3) = 
  drawer.cmdList.add GizmoRenderCmd.init(
    kind = Ring,
    tip = None,
    planeNormal = plane.normal,
    radius = plane.currentRadius,
    thickness = drawer.thickness,
    dir = vec2(0, 0), # don't care
    color = color)

proc axis*(
    drawer: var GizmoDrawer;
    plane: var GizmoPlane,
    color: Vec3,
    dir: Vec2,
    tip: GizmoTip = Arrow) =
  drawer.cmdList.add GizmoRenderCmd.init(
    kind =
      if plane.clipped: Line
      else: Ray
    ,
    tip = tip,
    planeNormal = plane.normal,
    radius = plane.currentRadius,
    thickness = drawer.thickness,
    dir = dir, # don't care
    color = color)

when isMainModule:
  var gizmoDrawer = GizmoDrawer.init()
  gizmoDrawer.objectPos = vec3(0, 0, 0)
  var p = gizmoDrawer.plane(vec3(0, 1, 0))
  gizmoDrawer.far(p, 42)
  gizmoDrawer.ring(p, vec3(1, 0, 0))
  gizmoDrawer.offset(p, 3)
  gizmoDrawer.disc(p, vec3(0, 1, 0))
  gizmoDrawer.axis(p, vec3(0, 0, 1), vec2(-1, 0), Arrow)

  echo gizmoDrawer.cmdList
