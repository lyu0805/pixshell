using System;
using System.IO;
using System.Text.Json;

namespace PixShell.Terminal;

/// <summary>
/// 终端背景覆盖色的持久化：单独一个 hex 字符串存 `%APPDATA%\PixShell\term-bg-override.json`。
/// 空字符串 = 不覆盖，用配色方案/主题默认背景。对齐 mac 版 `pixshell.termBgOverride`（UserDefaults）。
/// </summary>
public static class TermBackgroundStore
{
    private static string FilePath => Path.Combine(HostStore.AppDir, "term-bg-override.json");

    public static string Override { get; private set; } = "";

    /// <summary>覆盖色变化 → 通知已打开的会话（MainWindow 订阅，逐个 tab 应用）。</summary>
    public static event Action<string>? Changed;

    public static void Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var hex = JsonSerializer.Deserialize<string>(File.ReadAllText(FilePath));
                if (hex != null) Override = hex;
            }
        }
        catch { /* 读取失败保留默认值(不覆盖) */ }
    }

    public static void Set(string hex)
    {
        Override = hex ?? "";
        try { File.WriteAllText(FilePath, JsonSerializer.Serialize(Override)); } catch { /* 静默降级 */ }
        Changed?.Invoke(Override);
    }

    public static void Reset() => Set("");
}
