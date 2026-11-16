class_name AimRay
## 统一的"从相机中心打一条射线"
##
## 抽出来的原因很实际：build.gd 里 `_update_aim()` 和 `_try_remove()`
## 各写了一份几乎一样的射线代码，已经有轻微的漂移风险。
## 交互系统是第三个使用者 —— 再不抽，就要维护三份。

### 从当前相机中心朝前打射线。
## `exclude` 通常放玩家自己的 RID（否则会打到自己身上的胶囊）。
static func cast(viewport: Viewport, exclude: Array[RID], distance: float, mask: int) -> Dictionary:
	var cam := viewport.get_camera_3d()
	if cam == null:
		return {}
	var from := cam.global_position
	# 相机朝 -Z 看，所以前方是 -basis.z
	var to := from - cam.global_transform.basis.z * distance
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = mask
	query.exclude = exclude
	query.collide_with_areas = false
	return viewport.get_world_3d().direct_space_state.intersect_ray(query)
