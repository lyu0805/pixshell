using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Threading;

namespace PixShell.Logging;

/// <summary>
/// 文件日志（对齐 mac 版 Store/Log.swift 的契约）：
///   1) `%APPDATA%\PixShell\logs\pixshell-YYYY-MM-DD.log`  —— 按天归档
///   2) `%APPDATA%\PixShell\logs\pixshell-runtime.log`      —— 运行时主日志，滚动保留最近 1000 行
/// 铁律：**绝不把异常抛回调用方**（任何写失败都静默降级），日志本身不能拖垮 App。
/// 写入方式：调用方只把一行文本丢进内存队列（几乎零成本），单独一条后台线程串行消费写盘，
/// 对齐 mac 版 DispatchQueue(label: "com.pixshell.log") 的"异步 + 串行"效果。
/// </summary>
public static class Log
{
    public enum Level { Error = 0, Warn = 1, Info = 2, Debug = 3 }

    /// <summary>低于（数值上大于）该级别的日志会被丢弃，默认全部记录。</summary>
    public static Level MinLevel = Level.Debug;

    private const int MaxRuntimeLines = 1000;

    /// <summary>日志目录：`%APPDATA%\PixShell\logs\`；创建失败则退化到临时目录，绝不抛异常。</summary>
    public static readonly string Dir = ResolveDir();

    private static readonly BlockingCollection<string> _queue = new();
    private static readonly Thread _worker;
    private static int _seq;

    static Log()
    {
        _worker = new Thread(ConsumeLoop) { IsBackground = true, Name = "pixshell-log" };
        _worker.Start();
    }

    private static string ResolveDir()
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "PixShell", "logs");
            Directory.CreateDirectory(dir);
            return dir;
        }
        catch
        {
            try { return Path.GetTempPath(); } catch { return "."; }
        }
    }

    public static void Error(string msg, string tag = "") => Write(Level.Error, tag, msg);
    public static void Warn(string msg, string tag = "") => Write(Level.Warn, tag, msg);
    public static void Info(string msg, string tag = "") => Write(Level.Info, tag, msg);
    public static void Debug(string msg, string tag = "") => Write(Level.Debug, tag, msg);

    /// <summary>启动横幅：便于在日志里区分每次运行。对齐 mac Log.banner(_:)。</summary>
    public static void Banner(string version)
    {
        try
        {
            Info($"==== PixShell {version} 启动 · Windows {Environment.OSVersion.VersionString} ====", "app");
            Info($"日志目录 {Dir}", "app");
        }
        catch { /* 绝不抛出 */ }
    }

    private static string LevelTag(Level l) => l switch
    {
        Level.Error => "ERROR",
        Level.Warn => "WARN",
        Level.Info => "INFO",
        Level.Debug => "DEBUG",
        _ => "INFO",
    };

    private static void Write(Level level, string tag, string msg)
    {
        try
        {
            if ((int)level > (int)MinLevel) return;
            var now = DateTime.Now;
            var ts = now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff", CultureInfo.InvariantCulture);
            var tagPart = string.IsNullOrEmpty(tag) ? "" : $" [{tag}]";
            var line = $"{ts} [{LevelTag(level)}]{tagPart} {msg}";
            if (!_queue.IsAddingCompleted) _queue.Add(line);
        }
        catch { /* 绝不抛出：日志失败不能影响调用方 */ }
    }

    private static void ConsumeLoop()
    {
        foreach (var line in _queue.GetConsumingEnumerable())
        {
            try
            {
                var now = DateTime.Now;
                var daily = Path.Combine(Dir, $"pixshell-{now:yyyy-MM-dd}.log");
                AppendLine(daily, line);
                var runtime = Path.Combine(Dir, "pixshell-runtime.log");
                AppendLine(runtime, line);
                _seq++;
                if (_seq % 50 == 0) TrimRuntime(runtime); // 每 50 行检查一次滚动，避免频繁重写
            }
            catch { /* 单条写失败不影响后续日志 */ }
        }
    }

    private static void AppendLine(string path, string line)
    {
        try
        {
            File.AppendAllText(path, line + Environment.NewLine);
        }
        catch { /* 静默降级 */ }
    }

    /// <summary>运行时日志只保留最近 N 行。</summary>
    private static void TrimRuntime(string path)
    {
        try
        {
            if (!File.Exists(path)) return;
            var lines = File.ReadAllLines(path);
            if (lines.Length <= MaxRuntimeLines + 200) return;
            var tail = lines[^MaxRuntimeLines..];
            File.WriteAllLines(path, tail);
        }
        catch { /* 静默降级 */ }
    }
}
