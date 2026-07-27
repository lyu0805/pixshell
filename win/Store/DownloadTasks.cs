using System;
using System.Collections.Generic;
using System.Linq;

namespace PixShell;

/// <summary>
/// 下载任务清单（工具浮窗「下载任务将显示在这里」那一块的数据源）。
/// 老仓库 #toolsDlBox 就是这个用途 —— 工具浮窗本体主要就是给用户看下载进度/结果的。
/// 只在内存里保留最近若干条；进程退出即清空（与老仓库一致，不做持久化）。
/// 对齐 mac Store/DownloadTasks.swift。
/// </summary>
public static class DownloadTasks
{
    public enum State { Running, Done, Failed }

    public sealed class Task
    {
        public Guid Id { get; init; } = Guid.NewGuid();
        public string Name { get; set; } = "";
        public string Dest { get; set; } = "";
        public State State { get; set; } = State.Running;
        public string Detail { get; set; } = "";
        public DateTime Started { get; init; } = DateTime.Now;
    }

    private static readonly List<Task> _tasks = new();
    private const int MaxKeep = 30;

    /// <summary>有变化就通知（工具浮窗订阅它刷新列表）。</summary>
    public static event Action? Changed;

    public static IReadOnlyList<Task> Items
    {
        get { lock (_tasks) return _tasks.ToList(); }
    }

    public static Guid Start(string name, string dest)
    {
        var t = new Task { Name = name, Dest = dest, State = State.Running };
        lock (_tasks)
        {
            _tasks.Insert(0, t);
            if (_tasks.Count > MaxKeep) _tasks.RemoveRange(MaxKeep, _tasks.Count - MaxKeep);
        }
        Notify();
        return t.Id;
    }

    public static void Finish(Guid id, bool ok, string detail = "")
    {
        lock (_tasks)
        {
            var t = _tasks.FirstOrDefault(x => x.Id == id);
            if (t == null) return;
            t.State = ok ? State.Done : State.Failed;
            t.Detail = detail;
        }
        Notify();
    }

    public static void Clear()
    {
        lock (_tasks) _tasks.Clear();
        Notify();
    }

    private static void Notify()
    {
        var app = System.Windows.Application.Current;
        if (app == null) { Changed?.Invoke(); return; }
        // UI 线程外（SFTP 传输在后台线程回调）也要能安全刷新界面。
        if (app.Dispatcher.CheckAccess()) Changed?.Invoke();
        else app.Dispatcher.BeginInvoke(new Action(() => Changed?.Invoke()));
    }
}
