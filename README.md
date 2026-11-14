# 奔奔开门 · iOS 测试工程

SwiftUI App + WidgetKit 桌面/锁屏小组件，最低 iOS 17。无需第三方依赖，直接使用 Xcode 工程。

界面已改为液态玻璃风格：冰蓝色柔光背景、圆形玻璃开门按钮、悬浮设置入口、默认折叠的连接日志。使用 Xcode 26 或更高版本构建后，iOS 26 及以上采用系统 `glassEffect`；iOS 17–18 使用兼容磨砂材质。支持浅色/深色模式、减少透明度、增强对比度及减少动态效果。桌面小组件使用配套的冰蓝渐变和玻璃轮廓，锁屏样式保留系统渲染。

主页标题与设置入口固定在顶部安全区域内；下方内容独立滚动并裁剪到滚动视口。仅装饰背景延伸到状态栏后方，避免滚动文字或开门控件与状态栏重叠。

已内置冰蓝玻璃门图标：`App/Assets.xcassets/AppIcon.appiconset` 包含 iPhone 各尺寸及 1024px 主图，已连接 App 的资源编译和 AppIcon 设置。提交源码时请包含整个 Assets.xcassets 文件夹和更新后的 project.pbxproj。图标 PNG 为不透明正方形，由系统应用外轮廓。

点击小组件后，系统打开 App；App 进入前台后自动执行一次“扫描 → 连接 → 选锁 → 开门 → 显示结果”。普通打开 App 不会自动开门。手机需要解锁时先由系统完成解锁。首次使用需要导入配置并授权蓝牙。

这是基于用户提供小程序源码的测试实现，已完成协议静态核对和原始 JS 测试向量生成。制作环境为 Windows，尚未用 Xcode 编译、未安装到 iPhone、未实机开门。工程内 XCTest 需要在 Mac 上运行，不能将当前交付理解为已签名 IPA。

## 安装到 iPhone

没有 Mac 时，可使用已附带的 GitHub Actions 工作流编译未签名 IPA，不需要配置签名 Secrets。将本目录内容（含 `.github`）提交到仓库根目录，再到 Actions 手动运行 **Build unsigned iOS IPA**。详见 [GitHub Actions 编译说明](GitHub-Actions编译说明.md)。产物需后续签名才可安装，当前还未实际触发云编译。

分支推送或手动构建成功后，工作流自动发布 Release，附带 IPA 与 SHA-256 校验文件；Pull Request 仅验证构建。发布标签包含运行序号及重跑次数，便于区分每次产物。

1. 将整个 BenbenDoor 文件夹复制到 Mac，使用支持 iOS 17 的 Xcode 打开 BenbenDoor.xcodeproj。
2. 选中 BenbenDoor 和 BenbenDoorWidget 两个 target，在 Signing & Capabilities 中选择同一个开发 Team，开启自动签名。
3. 将 App Bundle Identifier 改为自己唯一的标识，例如 com.yourname.benbendoor；Widget 改为其下级 com.yourname.benbendoor.widget。两者需保持前缀关系。测试 target 如需签名，也选择相同 Team。
4. 连接 iPhone，按 Xcode 提示启用开发者模式及信任设置；选择 BenbenDoor scheme 和该 iPhone，点击 Run。
5. 将交付文件“奔奔门锁配置.private.json”存入 iPhone 的“文件”App。在奔奔开门中点击“导入门锁配置”，选择该文件。
6. 靠近已授权门锁，先在 App 内点击“一键开门”，允许蓝牙权限。结果应显示为“门锁返回开门成功”。
7. 返回桌面，长按空白处，添加“奔奔一键开门”小组件。提供小号、中号，以及锁屏圆形/矩形样式。安装后需至少先启动一次 App，系统才可能列出其小组件。

初次配置完成后，小组件入口不再要求在 App 里额外点一次“开门”。App 在前台执行，离开 App 会停止当前操作；已经发出的指令无法撤回。

## 快捷指令入口

App 注册了 URL scheme：`benbenlock://unlock`。

可以在快捷指令中添加“URL”动作，填入上述值，再添加“打开 URL”动作。运行会打开 App 并自动执行一次。小组件使用同一入口，配置文件和钥匙参数均不会放入 URL。

## 配置文件

交付的真实配置文件与源码压缩包分开，依据用户之前提供的 loadShareEkey 响应生成。它只包含本次蓝牙开门所需字段，不含手机号、OpenID、Bearer Token、完整 owner 或 EKeyID。不要将真实配置加入源码仓库或分享包。

工程中的“配置格式示例.json”使用合成设备标识与序号，仅用于说明结构，不能用于真实门锁。

导入选择器允许选择普通文件，避免文件提供者将 JSON 标记为文本或通用数据后不可选。选中后仍需通过完整 JSON 结构和授权有效期校验。支持 UTF-8 BOM；通过系统文件协调器读取文件提供者中的内容。若云盘文件无法读取，请先在“文件”App 中下载/保存至“我的 iPhone”后再选取。文件选择失败会显示在主页状态及连接日志中。

导入内容保存到此 App 的本机 Keychain，使用 WhenUnlockedThisDeviceOnly；小组件不读取钥匙，不需要 App Group。卸载、签名或 Bundle ID 变化后，应确认钥匙是否需要重新导入。App 提供“移除本机钥匙”。

本版本采用授权快照，不自动同步平台续期、撤销或订单更新。它在本地检查授权起止时间和手机时间回退，连接后从门锁取得会话字段，但不能替代平台实时授权校验。正式使用前需要接入受支持的授权更新机制。

## 实现范围

- 单把房间门锁，按 KD-设备编号精确匹配；当前配置来自用户的房间门锁样本。
- 服务 FFF0、写入 FFF2、通知 FFF1。自动选择 characteristic 支持的写入方式。
- 原代码的 ASCII ID 查表转换、选锁报文、secKey 响应读取、时间编码、普通开门报文及带设备参数的校验。
- 支持通知分片拼接、帧头同步、长度和校验检查、阶段超时、取消及错误提示。
- 只有收到业务响应 resultCode=0 才显示成功；蓝牙写入确认或超时不会当作成功。
- 普通开门操作不自动重试，避免结果不明时重复下发。
- 不包含电梯、设卡、改密码、设置指纹、门锁校时或平台日志回传。不会复刻原小程序的 SOE 读取/清除确认流程。
- 不依赖网络、位置权限、App Group 或蓝牙后台模式。实际门锁兼容性仍需实机确认。

## 首次测试如何定位问题

开启“记录原始通信字节”后重新操作一次，可通过分享按钮导出日志。日志默认只显示阶段和字节长度。原始通信记录包含当前会话数据，仅在排查时开启。

| 停留位置 | 核对内容 |
|---|---|
| 未找到目标 | 靠近并唤醒门锁；核对广播名和 FFF0 是否在广播中 |
| 已连接但发现特征失败 | 核对设备是否为同一协议；FFF1/FFF2 属性是否符合预期 |
| 选锁无响应/校验失败 | 用 TX/RX 日志比对 region、subregion、devID 及原协议 |
| 开门结果非零 | 保留具体结果码；核对授权、设备参数、手机/门锁时间与反锁状态 |
| 开门响应超时 | 结果未确认，先检查现场状态，再决定是否手动重试 |

本实现不自动校时。若门锁时间偏差导致拒绝，先用原小程序正常同步门锁时间，再继续测试。

## 验证

在 Mac 上选 BenbenDoor scheme，执行 Product → Test。Tests/DoorProtocolTests.swift 含 7 项测试，预期报文由原始小程序 JS 使用合成参数生成，覆盖 ID 转换、选锁、时区、开门报文、固件选项、响应校验与有效期。

命令行示例（把设备替换为实际可用的 Simulator）：

```sh
xcodebuild -list -project BenbenDoor.xcodeproj
xcodebuild test -project BenbenDoor.xcodeproj -scheme BenbenDoor -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Simulator 可跑协议单元测试，实际蓝牙开门需 iPhone。当前制作环境没有执行这些 Xcode 命令。详见 VALIDATION.md。

## 文件

- App/：界面、Core Bluetooth 状态机、Keychain 与协议编码。
- Widget/：桌面/锁屏入口。
- Tests/：使用原始 JS 预期值的协议测试。
- BenbenDoor.xcodeproj/：App、Widget 和 XCTest targets，含共享 scheme。
- 配置格式示例.json：合成配置格式。
