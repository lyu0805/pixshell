import Foundation

/// 下载任务清单（工具浮窗「下载任务将显示在这里」那一块的数据源）。
/// 老仓库 #toolsDlBox 就是这个用途 —— 工具浮窗本体主要就是给用户看下载进度/结果的。
/// 只在内存里保留最近若干条；进程退出即清空（与老仓库一致，不做持久化）。
final class DownloadTasks {
    static let shared = DownloadTasks()
    private init() {}

    enum State { case running, done, failed }

    struct Task {
        let id: UUID
        var name: String        // 文件名/包名
        var dest: String        // 落地路径
        var state: State
        var detail: String      // 失败原因 / 完成提示
        var started: Date
    }

    private(set) var tasks: [Task] = []
    private let maxKeep = 30

    /// 有变化就通知（工具浮窗订阅它刷新列表）。
    var onChange: (() -> Void)?

    @discardableResult
    func start(name: String, dest: String) -> UUID {
        let t = Task(id: UUID(), name: name, dest: dest, state: .running, detail: "", started: Date())
        let id = t.id
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tasks.insert(t, at: 0)
            if self.tasks.count > self.maxKeep { self.tasks.removeLast(self.tasks.count - self.maxKeep) }
            self.notify()
        }
        return id
    }

    func finish(_ id: UUID, ok: Bool, detail: String = "") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let i = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            self.tasks[i].state = ok ? .done : .failed
            self.tasks[i].detail = detail
            self.notify()
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tasks.removeAll()
            self.notify()
        }
    }

    private func notify() {
        if Thread.isMainThread { onChange?() }
        else { DispatchQueue.main.async { [weak self] in self?.onChange?() } }
    }
}
