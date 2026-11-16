# Proposal

## Why

当前商店只有手持武器，玩家只能在地面移动，缺少一种能改变探索路线与战斗节奏的高价值装备。加入飞行翅膀可以让玩家越过城镇障碍、从高处观察丧尸，并为后续空战、体力或燃料系统留下扩展点。

## What Changes

- 新增可购买、可持续装备的“飞行翅膀”，作为独立背部装备槽；购买翅膀不会替换当前手持武器。
- 装备翅膀后，玩家可在首次起跳后的空中再次按跳跃键展开翅膀：按住跳跃键上升，松开后缓降；落地后恢复下一次起飞能力。
- 翅膀以程序化左右翼片显示，并在所有联机端同步装备状态与飞行姿态。
- 商店面板显示翅膀商品，并在装备、可起飞、飞行中状态给出明确反馈。
- 新增服务器权威的飞行模拟与无头验收，客户端只能提交输入意图，不能直接赋予速度、装备或升空能力。
- 本次不引入体力、燃料、耐久、空战武器、飞行专属敌人或存档；价格仍沿用现有商店的占位数值体系。

## Capabilities

### New Capabilities

- `flight-wings`: 飞行翅膀的购买与背部装备、联机可见性、双击空格起飞、按住上升、松手缓降、落地复位以及对应状态反馈。

### Modified Capabilities

无。项目当前没有已落地的 OpenSpec 能力规格。

## Impact

- 商品与装备：`game/scripts/shop/goods.gd`、`game/scripts/shop/shop_service.gd`、`game/scripts/ui/shop_panel.gd`。
- 玩家与场景：`game/scenes/player.gd`、`game/scenes/player.tscn`，新增背部翅膀外观组件或脚本。
- 输入与移动：继续使用现有 `jump` 动作，扩展本地输入采集和服务器输入 RPC 的持有状态。
- 状态与 HUD：`game/scripts/game_state.gd`、`game/scenes/hud.gd`、`game/scenes/hud.tscn`。
- 联机：装备账本由单槽扩展为手持/背部两个槽位，并保留新玩家加入时的快照重放。
- 验证：扩展 `game/scripts/dev/selftest.gd` 的商店、装备同步和飞行物理探针。
