extends Node3D
## 手持武器外观：只认一个 item_id，几何由 Goods 表还原
##
## 这就是"外观同步"的全部秘密：**过网的只有一个整数**。
## 如果同步的是"几个盒子、什么尺寸、什么颜色"，那两端就有机会算出不同的结果；
## 同步 id、两端各自查同一张常量表，造型差异从结构上就不可能发生。

var _parts: Array[Node3D] = []


func apply(item_id: int) -> void:
	for p in _parts:
		if is_instance_valid(p):
			p.queue_free()
	_parts.clear()

	if not Goods.has(item_id):
		return

	for part in Goods.get_item(item_id)["parts"]:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = part["size"]
		mi.mesh = box
		mi.position = part["offset"]

		var mat := StandardMaterial3D.new()
		mat.albedo_color = part["color"]
		mat.roughness = 0.55
		mat.metallic = 0.4
		mi.material_override = mat

		add_child(mi)
		_parts.append(mi)


func part_count() -> int:
	return _parts.size()
