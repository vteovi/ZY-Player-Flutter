import os
import sys
import json
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext


def get_base_dir():
    """获取程序所在目录（兼容脚本运行和 PyInstaller 打包后的 exe）"""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    else:
        return os.path.dirname(os.path.abspath(__file__))


CONFIG_PATH = os.path.join(get_base_dir(), "gitee_desktop_config.json")


# ============ 常见 Git 英文提示 → 中文解释 ============
GIT_MSG_CN = [
    ("invalid gitfile format",
     "远程地址格式无效。常见原因：把“Gitee 远程”填成了本地文件路径。正确格式应类似 https://gitee.com/用户名/仓库名.git"),
    ("could not read from remote repository",
     "无法读取远程仓库。请检查远程地址、仓库是否存在、是否有访问权限。"),
    ("please make sure you have the correct access rights and the repository exists",
     "请确认：1) 远程地址是否正确；2) 仓库是否存在；3) 当前账号是否有访问权限。"),
    ("repository not found",
     "找不到该仓库。请检查地址拼写，或确认仓库不是私有仓库。"),
    ("authentication failed",
     "身份认证失败。需要配置 Gitee 用户名 + 密码，或使用私人令牌（推荐）。"),
    ("permission denied",
     "权限不足。请检查账号权限或 SSH 公钥是否已添加到 Gitee。"),
    ("fatal: not a git repository",
     "当前目录不是 Git 仓库。请先点“初始化仓库”。"),
    ("not a git repository",
     "当前目录不是 Git 仓库。请先点“初始化仓库”。"),
    ("nothing to commit",
     "没有需要提交的改动（工作区是干净的）。"),
    ("nothing added to commit",
     "没有需要提交的改动。可能所有文件都已被提交过。"),
    ("your branch is up to date",
     "本地分支已是最新，和远程一致。"),
    ("your branch is ahead",
     "本地分支领先远程，有提交还没推送。"),
    ("your branch is behind",
     "本地分支落后于远程，建议先点“拉取”。"),
    ("your branch and",  # Your branch and 'origin/main' have diverged
     "本地和远程分支已经分叉，需要先拉取合并。"),
    ("rejected",
     "推送被拒绝。远程有本地没有的提交，请先点“拉取”，再推送。"),
    ("failed to push some refs",
     "部分内容推送失败，通常是远程有新提交，请先拉取。"),
    ("fetch first",
     "请先拉取远程的更新再推送。"),
    ("non-fast-forward",
     "非快进推送被拒绝，需要先拉取并合并远程改动。"),
    ("updates were rejected",
     "更新被拒绝，请先拉取远程的改动。"),
    ("couldn't find remote ref",
     "找不到远程分支。请确认分支名是否正确，或远程是否已有该分支。"),
    ("could not resolve host",
     "无法解析主机名。请检查网络或地址拼写。"),
    ("connection refused",
     "连接被拒绝。请检查网络、代理或地址。"),
    ("connection timed out",
     "连接超时。请检查网络，或稍后重试。"),
    ("timed out",
     "操作超时。请检查网络，或稍后重试。"),
    ("ssl certificate problem",
     "SSL 证书问题。可能是网络代理导致，请检查网络环境。"),
    ("host key verification failed",
     "SSH 主机密钥验证失败。请先把 Gitee 加入 known_hosts。"),
    ("ssh: could not resolve hostname",
     "无法解析 SSH 主机名。请检查网络或 SSH 配置。"),
    ("unable to access",
     "无法访问该地址。请检查地址和网络。"),
    ("permission to",  # permission to xxx denied
     "没有权限访问该仓库。请检查账号权限。"),
    ("non-fast-forward updates were rejected",
     "推送被拒绝，请先拉取远程改动再推送。"),
    ("already up to date",
     "已是最新，无需更新。"),
    ("already up-to-date",
     "已是最新，无需更新。"),
    ("merge conflict",
     "合并冲突，需要手动解决冲突后再提交。"),
    ("conflict",
     "存在冲突，请手动解决。"),
    ("detached head",
     "处于游离 HEAD 状态（没有在任何一个分支上）。"),
    ("you are not currently on a branch",
     "当前不在任何分支上。"),
    ("branch is currently checked out",
     "该分支当前已检出，不能删除。"),
    ("fatal:",
     "Git 命令执行失败。"),
    ("error:",
     "出错了。"),
]


def translate_git_output(text):
    """把常见的 Git 英文提示后追加一行中文解释。未命中的行原样输出。"""
    if not text:
        return text
    out_lines = []
    for line in text.splitlines():
        out_lines.append(line)
        low = line.lower()
        for en, zh in GIT_MSG_CN:
            if en in low:
                out_lines.append(f"  → 中文提示：{zh}")
                break
    return "\n".join(out_lines)
# ======================================================


class GiteeDesktop:
    def __init__(self, root):
        self.root = root
        root.title("Gitee Desktop - Python 简易版")
        root.geometry("900x620")

        self._busy = False
        self._buttons = []

        self.config = {
            "repo_path": "",
            "remote_url": "",
            "branch": "main",
            "commit_msg": "",
            "last_browse_dir": os.path.expanduser("~"),
            "history_count": 100,
        }
        self.load_config()

        frm = ttk.Frame(root, padding=10)
        frm.pack(fill=tk.BOTH, expand=True)

        ttk.Label(frm, text="本地仓库：").grid(row=0, column=0, sticky=tk.W)
        self.repo_path = tk.StringVar(value=self.config["repo_path"])
        ttk.Entry(frm, textvariable=self.repo_path).grid(row=0, column=1, sticky=tk.EW)
        ttk.Button(frm, text="浏览", command=self.browse).grid(row=0, column=2)

        ttk.Label(frm, text="Gitee 远程：").grid(row=1, column=0, sticky=tk.W)
        self.remote_url = tk.StringVar(value=self.config["remote_url"])
        ttk.Entry(frm, textvariable=self.remote_url).grid(row=1, column=1, sticky=tk.EW)
        ttk.Button(frm, text="设置远程", command=self.set_remote).grid(row=1, column=2)

        ttk.Label(frm, text="分支：").grid(row=2, column=0, sticky=tk.W)
        self.branch = tk.StringVar(value=self.config["branch"])
        ttk.Entry(frm, textvariable=self.branch).grid(row=2, column=1, sticky=tk.W)

        ttk.Label(frm, text="提交信息：").grid(row=3, column=0, sticky=tk.W)
        self.commit_msg = tk.StringVar(value=self.config["commit_msg"])
        ttk.Entry(frm, textvariable=self.commit_msg).grid(row=3, column=1, sticky=tk.EW)

        self.status_var = tk.StringVar(value="就绪")
        status_bar = ttk.Label(frm, textvariable=self.status_var, anchor=tk.W,
                               relief=tk.SUNKEN, padding=(6, 2))
        status_bar.grid(row=4, column=0, columnspan=3, sticky=tk.EW, pady=(6, 4))

        btns = ttk.Frame(frm)
        btns.grid(row=5, column=0, columnspan=3, pady=4, sticky=tk.W)

        buttons = [
            ("检查状态", self.status),
            ("提交历史", self.history),
            ("初始化仓库", self.init_repo),
            ("添加并提交", self.commit),
            ("推送到 Gitee", self.push),
            ("拉取", self.pull),
            ("保存配置", self.save_config_manual),
            ("打开配置目录", self.open_config_dir),
            ("清空输出", self.clear_log),
        ]

        for text, cmd in buttons:
            b = ttk.Button(btns, text=text, command=cmd)
            b.pack(side=tk.LEFT, padx=4)
            self._buttons.append(b)

        self.log_text = scrolledtext.ScrolledText(frm, height=20)
        self.log_text.grid(row=6, column=0, columnspan=3, sticky=tk.NSEW)

        frm.columnconfigure(1, weight=1)
        frm.rowconfigure(6, weight=1)

        for var in (self.repo_path, self.remote_url, self.branch, self.commit_msg):
            var.trace_add("write", lambda *a: self.save_config())

        root.protocol("WM_DELETE_WINDOW", self.on_close)

        self.log(f"配置文件：{CONFIG_PATH}")
        if not os.path.isfile(CONFIG_PATH):
            self.log("（配置文件尚不存在，会在第一次修改时自动创建）")

    # ---------- 配置 ----------

    def load_config(self):
        if os.path.isfile(CONFIG_PATH):
            try:
                with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict):
                    self.config.update({k: data.get(k, v) for k, v in self.config.items()})
            except Exception as e:
                print("读取配置失败：", e)

    def save_config(self):
        try:
            self.config["repo_path"] = self.repo_path.get().strip()
            self.config["remote_url"] = self.remote_url.get().strip()
            self.config["branch"] = self.branch.get().strip() or "main"
            self.config["commit_msg"] = self.commit_msg.get()

            with open(CONFIG_PATH, "w", encoding="utf-8") as f:
                json.dump(self.config, f, ensure_ascii=False, indent=2)
        except Exception as e:
            print("保存配置失败：", e)

    def save_config_manual(self):
        self.save_config()
        messagebox.showinfo("提示", f"配置已保存到：\n{CONFIG_PATH}")

    def open_config_dir(self):
        folder = os.path.dirname(CONFIG_PATH)
        try:
            if sys.platform.startswith("win"):
                os.startfile(folder)
            elif sys.platform == "darwin":
                subprocess.Popen(["open", folder])
            else:
                subprocess.Popen(["xdg-open", folder])
        except Exception as e:
            messagebox.showerror("错误", f"无法打开目录：\n{folder}\n{e}")

    def on_close(self):
        self.save_config()
        self.root.destroy()

    # ---------- 日志 ----------

    def log(self, msg):
        self.log_text.insert(tk.END, msg + "\n")
        self.log_text.see(tk.END)

    def log_git(self, msg):
        """输出 Git 内容，附带中文解释"""
        self.log(translate_git_output(msg))

    def clear_log(self):
        self.log_text.delete("1.0", tk.END)

    # ---------- 忙碌状态 ----------

    def set_busy(self, busy):
        self._busy = busy
        state = tk.DISABLED if busy else tk.NORMAL
        for b in self._buttons:
            try:
                b.config(state=state)
            except Exception:
                pass
        try:
            self.root.config(cursor="watch" if busy else "")
        except Exception:
            pass
        self.status_var.set("正在执行，请稍候…" if busy else "就绪")
        self.root.update_idletasks()

    # ---------- 目录 ----------

    def browse(self):
        init_dir = self.config.get("last_browse_dir") or os.path.expanduser("~")
        if not os.path.isdir(init_dir):
            init_dir = os.path.expanduser("~")
        path = filedialog.askdirectory(initialdir=init_dir)
        if path:
            self.repo_path.set(path)
            self.config["last_browse_dir"] = path
            self.save_config()

    # ---------- 异步 Git ----------

    def _run_git_cmds(self, cmds, on_done=None):
        cwd = self.repo_path.get().strip()
        if not cwd:
            messagebox.showwarning("提示", "请先选择本地仓库目录")
            return
        if not os.path.isdir(cwd):
            messagebox.showerror("错误", "本地仓库目录不存在")
            return
        if self._busy:
            self.log("（上一个 Git 命令还没执行完，请稍等）")
            return

        self.set_busy(True)

        def worker():
            env = os.environ.copy()
            env["GIT_TERMINAL_PROMPT"] = "0"
            results = []

            for args, ignore_error in cmds:
                self.root.after(0, lambda a=args: self.log("$ git " + " ".join(a)))

                try:
                    r = subprocess.run(
                        ["git"] + args, cwd=cwd,
                        capture_output=True, text=True,
                        encoding="utf-8", errors="replace",
                        env=env
                    )
                except FileNotFoundError:
                    self.root.after(0, lambda: self._finish_git(
                        err="未找到 git，请先安装 Git 并加入 PATH"))
                    return
                except Exception as e:
                    self.root.after(0, lambda e=e: self._finish_git(err=str(e)))
                    return

                results.append(r)

                out = (r.stdout or "").strip()
                err = (r.stderr or "").strip()
                if out:
                    self.root.after(0, lambda o=out: self.log_git(o))
                if err:
                    self.root.after(0, lambda e=err: self.log_git(e))
                if r.returncode != 0 and not ignore_error:
                    self.root.after(0, lambda rc=r.returncode: self.log(
                        f"[命令失败，退出码 {rc}]"))

            self.root.after(0, lambda: self._finish_git(results=results, on_done=on_done))

        threading.Thread(target=worker, daemon=True).start()

    def _finish_git(self, err=None, results=None, on_done=None):
        self.set_busy(False)
        if err:
            messagebox.showerror("错误", err)
            return
        if on_done:
            try:
                on_done(results or [])
            except Exception as e:
                self.log(f"处理结果出错：{e}")

    # ---------- Git 操作 ----------

    def init_repo(self):
        branch = self.branch.get().strip() or "main"

        def done(results):
            if results and results[0].returncode == 0:
                self.log("初始化完成。")

        self._run_git_cmds([
            (["init"], False),
            (["branch", "-M", branch], True),
        ], on_done=done)

    def set_remote(self):
        url = self.remote_url.get().strip()
        if not url:
            messagebox.showwarning("提示", "请填写 Gitee 仓库地址")
            return

        # 简单校验：远程地址应该以 http/https/git@ 开头
        if not (url.startswith("http://") or url.startswith("https://")
                or url.startswith("git@") or url.startswith("ssh://")):
            messagebox.showwarning(
                "地址格式可能不对",
                "Gitee 远程地址应以 http://、https://、git@ 或 ssh:// 开头。\n\n"
                "例如：https://gitee.com/你的用户名/仓库名.git"
            )
            return

        def done(results):
            self.log("远程 origin 已设置。")

        self._run_git_cmds([
            (["remote", "remove", "origin"], True),
            (["remote", "add", "origin", url], False),
        ], on_done=done)

    def status(self):
        self._run_git_cmds([
            (["status", "--short", "--branch"], False),
        ])

    def commit(self):
        msg = self.commit_msg.get().strip()
        if not msg:
            messagebox.showwarning("提示", "请填写提交信息")
            return
        self._run_git_cmds([
            (["add", "-A"], False),
            (["commit", "-m", msg], False),
        ])

    def push(self):
        branch = self.branch.get().strip() or "main"
        self._run_git_cmds([
            (["push", "-u", "origin", branch], False),
        ])

    def pull(self):
        branch = self.branch.get().strip() or "main"
        self._run_git_cmds([
            (["pull", "origin", branch], False),
        ])

    # ---------- 提交历史 ----------

    def history(self):
        cwd = self.repo_path.get().strip()
        if not cwd:
            messagebox.showwarning("提示", "请先选择本地仓库目录")
            return
        if not os.path.isdir(cwd):
            messagebox.showerror("错误", "本地仓库目录不存在")
            return

        count = str(self.config.get("history_count", 100))
        sep = "%x1f"
        pretty = f"--pretty=format:%h{sep}%an{sep}%ad{sep}%s"
        args = ["log", pretty, "--date=format:%Y-%m-%d %H:%M", "-n", count]

        def on_done(results):
            if not results:
                return
            r = results[0]
            if r.returncode != 0:
                err = (r.stderr or "").strip()
                self.log_git(err or "获取提交历史失败。")
                messagebox.showerror(
                    "错误",
                    "获取提交历史失败。\n\n可能原因：该目录还不是 Git 仓库，或还没有任何提交。"
                )
                return

            lines = [ln for ln in (r.stdout or "").splitlines() if ln.strip()]
            if not lines:
                self.log("暂无提交记录。")
                messagebox.showinfo("提示", "暂无提交记录")
                return

            rows = [ln.split("\x1f", 3) for ln in lines]
            rows = [row for row in rows if len(row) == 4]
            self.log(f"共 {len(rows)} 条提交记录（最多显示最近 {count} 条）。")
            self._show_history_window(rows)

        self._run_git_cmds([(args, False)], on_done=on_done)

    def _show_history_window(self, rows):
        win = tk.Toplevel(self.root)
        win.title("提交历史")
        win.geometry("860x480")

        top = ttk.Frame(win, padding=(8, 8, 8, 0))
        top.pack(fill=tk.X)

        ttk.Label(top, text=f"共 {len(rows)} 条记录").pack(side=tk.LEFT)
        ttk.Label(top, text="（双击某一行可查看该次提交的详细改动）",
                  foreground="#666666").pack(side=tk.LEFT, padx=8)

        frame = ttk.Frame(win, padding=8)
        frame.pack(fill=tk.BOTH, expand=True)

        cols = ("hash", "author", "date", "subject")
        tree = ttk.Treeview(frame, columns=cols, show="headings", selectmode="browse")

        tree.heading("hash", text="提交")
        tree.heading("author", text="作者")
        tree.heading("date", text="时间")
        tree.heading("subject", text="说明")

        tree.column("hash", width=90, anchor=tk.W, stretch=False)
        tree.column("author", width=130, anchor=tk.W, stretch=False)
        tree.column("date", width=140, anchor=tk.W, stretch=False)
        tree.column("subject", width=440, anchor=tk.W, stretch=True)

        vsb = ttk.Scrollbar(frame, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=vsb.set)

        tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        vsb.pack(side=tk.RIGHT, fill=tk.Y)

        for row in rows:
            tree.insert("", tk.END, values=row)

        tree.tag_configure("odd", background="#f5f5f5")
        for i, item in enumerate(tree.get_children()):
            if i % 2:
                tree.item(item, tags=("odd",))

        tree.bind("<Double-1>", lambda e: self._on_history_double_click(tree))

        win.transient(self.root)

    def _on_history_double_click(self, tree):
        sel = tree.selection()
        if not sel:
            return
        values = tree.item(sel[0], "values")
        if not values:
            return
        commit_hash = values[0]

        self.log("")
        self.log(f"===== 提交 {commit_hash} 详情 =====")
        self._run_git_cmds([
            (["show", "--stat", "--pretty=fuller", commit_hash], True),
        ])


if __name__ == "__main__":
    root = tk.Tk()
    app = GiteeDesktop(root)
    root.mainloop()