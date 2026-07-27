using System;
using System.IO;
using System.Text.Json;

namespace PixShell.Terminal;

/// <summary>
/// 当前终端配色方案的持久化：单独一个 id 字符串存 `%APPDATA%\PixShell\term-scheme.json`。
/// 对齐老仓库 ui-settings.js 里的 colorScheme 字段（mac 端尚未接持久化，这里顺带补上）。
/// </summary>
public static class TermSchemeStore
{
    private static string FilePath => Path.Combine(HostStore.AppDir, "term-scheme.json");

    public static string CurrentId { get; private set; } = TermSchemes.DefaultDarkId;

    /// <summary>当前方案变化 → 通知已打开的会话（MainWindow 订阅，逐个 tab 调用 ApplyTermScheme）。</summary>
    public static event Action<TermScheme>? Changed;

    public static void Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var id = JsonSerializer.Deserialize<string>(File.ReadAllText(FilePath));
                if (!string.IsNullOrEmpty(id) && TermSchemes.Get(id) != null) CurrentId = id!;
            }
        }
        catch { /* 读取失败保留默认值 */ }
    }

    public static TermScheme Current => TermSchemes.Get(CurrentId) ?? TermSchemes.All[0];

    public static void SetCurrent(string id)
    {
        var scheme = TermSchemes.Get(id);
        if (scheme == null) return;
        CurrentId = scheme.Id;
        try { File.WriteAllText(FilePath, JsonSerializer.Serialize(scheme.Id)); } catch { /* 静默降级 */ }
        Changed?.Invoke(scheme);
    }
}
