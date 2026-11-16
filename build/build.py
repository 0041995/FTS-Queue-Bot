#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 src/core.js 与 src/probe.js 注入到两个模板里，生成可直接分发的单文件脚本。

产物:
    dist/autofts.sh    Linux / Termux / macOS 用，LF 换行，带执行位
    dist/autofts.ps1   Windows 用，CRLF 换行 + UTF-8 BOM

为什么 ps1 必须是 CRLF + BOM:
    * 没有 BOM，PowerShell 5.1 会按系统代码页(中文机器是 GBK)解析，中文全部乱码；
    * 只有 LF，Windows 控制台里的 here-string 不会回车，帮助文本会串成一行。

用法:
    python3 build/build.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "src")
TPL_DIR = os.path.join(ROOT, "templates")
DIST_DIR = os.path.join(ROOT, "dist")

CORE_MARK = "@@CORE_JS@@"
PROBE_MARK = "@@PROBE_JS@@"
UPDATE_MARK = "@@UPDATE_JS@@"


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read().replace("\r\n", "\n")


def check_ps_safe(name, body):
    """PowerShell here-string 遇到行首的 '@ 会提前结束，必须确保源码里没有。"""
    for lineno, line in enumerate(body.split("\n"), 1):
        if line.startswith("'@") or line.startswith('"@'):
            sys.exit(
                "错误: %s 第 %d 行以 %r 开头，会提前终止 PowerShell here-string"
                % (name, lineno, line[:2])
            )


def main():
    version = read_text(os.path.join(ROOT, "VERSION")).strip()
    if not version:
        sys.exit("错误: VERSION 文件为空")
    core = read_text(os.path.join(SRC_DIR, "core.js"))
    probe = read_text(os.path.join(SRC_DIR, "probe.js"))
    updater = read_text(os.path.join(SRC_DIR, "update.js"))
    check_ps_safe("src/core.js", core)
    check_ps_safe("src/probe.js", probe)
    check_ps_safe("src/update.js", updater)
    # 模板里占位符独占一行，源码结尾的换行要先去掉，否则会多出一个空行
    core_inject = core.rstrip("\n")
    probe_inject = probe.rstrip("\n")
    update_inject = updater.rstrip("\n")

    os.makedirs(DIST_DIR, exist_ok=True)

    # ---- Linux / Termux ----
    sh = read_text(os.path.join(TPL_DIR, "autofts.sh.tpl"))
    if CORE_MARK not in sh or PROBE_MARK not in sh or UPDATE_MARK not in sh:
        sys.exit("错误: autofts.sh.tpl 里缺少占位符")
    sh = (sh.replace(CORE_MARK, core_inject).replace(PROBE_MARK, probe_inject)
            .replace(UPDATE_MARK, update_inject).replace("@@VERSION@@", version))
    sh_path = os.path.join(DIST_DIR, "autofts.sh")
    with open(sh_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(sh)
    try:
        os.chmod(sh_path, 0o755)
    except OSError:
        pass  # Windows 上无所谓，Linux 上才有意义

    # ---- Windows ----
    ps = read_text(os.path.join(TPL_DIR, "autofts.ps1.tpl"))
    if CORE_MARK not in ps or PROBE_MARK not in ps or UPDATE_MARK not in ps:
        sys.exit("错误: autofts.ps1.tpl 里缺少占位符")
    ps = (ps.replace(CORE_MARK, core_inject).replace(PROBE_MARK, probe_inject)
            .replace(UPDATE_MARK, update_inject).replace("@@VERSION@@", version))
    ps = ps.replace("\r\n", "\n").replace("\n", "\r\n")
    ps_path = os.path.join(DIST_DIR, "autofts.ps1")
    # utf-8-sig = 写 BOM；newline="" 防止 Python 再动一次换行
    with open(ps_path, "w", encoding="utf-8-sig", newline="") as f:
        f.write(ps)

    # ---- 一键更新附属文件 ----
    update_sh_src = read_text(os.path.join(ROOT, "scripts", "update.sh"))
    update_sh_path = os.path.join(DIST_DIR, "update.sh")
    with open(update_sh_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(update_sh_src)
    try:
        os.chmod(update_sh_path, 0o755)
    except OSError:
        pass

    update_ps_src = read_text(os.path.join(ROOT, "scripts", "update.ps1"))
    update_ps_path = os.path.join(DIST_DIR, "update.ps1")
    with open(update_ps_path, "w", encoding="utf-8-sig", newline="") as f:
        f.write(update_ps_src.replace("\r\n", "\n").replace("\n", "\r\n"))

    updater_path = os.path.join(DIST_DIR, "update.js")
    with open(updater_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(updater)

    for path in (sh_path, ps_path):
        with open(path, encoding="utf-8-sig") as f:
            if "@@" in f.read():
                sys.exit("错误: %s 里还有没替换的占位符" % os.path.basename(path))

    for p in (sh_path, ps_path, update_sh_path, update_ps_path, updater_path):
        size = os.path.getsize(p)
        print("已生成 %-24s %8.1f KB" % (os.path.relpath(p, ROOT), size / 1024.0))


if __name__ == "__main__":
    main()
