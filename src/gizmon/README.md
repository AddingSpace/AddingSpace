Games need gizmos because it simplifies debugging.
Without it, debugging various vectors turns into hell, however this requires a gizmos system more complex than a basic one (i.e. gizmos in the form of editor tools like a rotation gizmo, position gizmo, scale gizmo), this is how various game engines do it, for example Godot. Essentially, a gizmo system is described here that should be both simple and suitable for debugging tasks.
Aproximate api:
```nim
var g = GizmoDrawer(thickness)
var obj = g.coordSystem(objPos)
obj.plane(normal) # normal only need for 3d
  .far(radius) # radius from what layout starts
  .ring(color, onDrag) # draws circle with known thickness at radius
  .offset(gap)
  .disc(color, onDrag) # draws filled circle, for 3d overload need orientation, will probably be described by normal
  .axis(color, vec2(-1, 0), Arrow, onDrag)

g.commit()
```

`far` op actually cuts the plane with a circle. Without it, `axis` will define a ray, not a line, disc will describe full plane
`offset` is basicly `far` but it know old `far` op radius and add offset, this makes layout calculations more reliable
In fact, it's worth seeing it as an onion.
