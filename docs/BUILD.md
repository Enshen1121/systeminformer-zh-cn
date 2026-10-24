# 从源码构建

终端用户运行补丁无需编译软件。开发者构建两个插件需要 Windows、Visual Studio Build Tools（C++ 桌面工具）及 Windows SDK，`vswhere.exe` 用于定位编译工具。

在仓库目录执行：

```cmd
tools\Build.cmd x64
tools\Build.cmd x86
```

输出分别写入 `payload/x64`、`payload/x86`，中间文件在 `build`。`src/localization-plugin` 是动态汉化插件，`src/third-party` 是新增主页插件，`runtime/third-party` 是后台及恢复脚本。兼容导出序号固定于 4.0.26241.138，不能直接用于其他版本。

`zh_dictionary.h` 是提交的可审查生成数据；`data/community-zh-CN.json` 保留原始中文数据。修改词典后请同步生成头文件及资源，并核对格式占位符。`patches/*.rc` 是可编辑对话框资源，`*.res` 是对应编译结果；修改 `.rc` 后需使用兼容资源编译器重新编译 `.res`。Resource Hacker 可用于开发机编译这些导出格式，但它不包含在补丁中，也不是安装依赖。

`src/ResourcePatch.cs` 通过 Win32 资源 API 只写 DIALOG，并回读逐字节验证；安装时由 PowerShell/.NET 编译，不包含宿主源码或完整宿主构建流程。

构建插件后执行 `tools/Update-PayloadHashes.ps1` 更新清单中的补丁文件哈希，再运行测试。原版文件哈希是固定兼容基线，不能为了绕过版本检查改成未知文件。更新兼容版本应重新适配接口、资源和所有测试。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Resources.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Installer.ps1 -OriginalDirectory "官方程序目录" -WorkDirectory "独立测试目录"
```

安装测试使用新建目录，不结束现有用户进程、不修改系统自启项。管理员写操作需要在隔离 Windows 测试环境内另行验证。
