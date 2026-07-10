# 🐛 ubuntu傻逼

> 一个严肃记录 Ubuntu 各种陈年老坑的民间考古项目。
> 这些 Bug 比你小学毕业证还老，但至今活得好好的。
> 我就是要看看，到底要多少个 LTS 版本，才能把这些坑填平。

---

## 🤔 为什么会有这个仓库？

我用了十几年 Ubuntu，期间被各种想都想不到的坑折磨了无数次。每次踩坑去搜解决方案的时候，总会发现：

- **Launchpad 上的 Bug Report**：发表于 2012 年，最后一条回复是 2018 年的 "me too"，状态：`Confirmed` → `Triaged` → `Won't Fix` → `Opinion`
- **StackExchange 上的问题**：70 个回答，最高票方案是「重装系统」
- **Ubuntu 官方论坛**：版主回复「Please mark as [SOLVED]」然后锁帖，但帖子里根本没解决方案
- **Arch Wiki**：写得明明白白，每一步都管用。可我用的是 Ubuntu 😭

所以我把这些坑都记下来。不指望 Canonical 修，起码给自己和后人留个路标。

---

## 📂 目录结构

```
ubuntu-sb/
├── README.md                          # 你正在看的这个文件
├── 0.赛亚人续命丹claudecode/           # 杀不死你的，只会让你更强大
│   ├── install-claude-code-ubuntu.sh  # 一键救命脚本
│   └── # 在 Ubuntu 24安装nodeJS.md     # 你以为 apt install nodejs 就完了？天真
├── 1.关于更新kernal以后无法启动这件事/   # 更个内核，机器直接进 emergency mode
│   ├── ubuntu-kernel-boot-fix-diagnosis.md  # 7 种死法 + 自动修复脚本
│   └── boot-guard/                    # Boot Guard 给你锁了 BIOS，爽不爽？
└── 更多坑，施工中……
```

---

## 🏆 目前收录的 Ubuntu 经典名场面

| # | 名场面 | 坑龄（约） | 一句话总结 |
|---|--------|-----------|-----------|
| 0 | **在 Ubuntu 24.04 上装 Node.js** | ？ | `apt install nodejs` 装完发现是 12.x，或者装了 snap 版结果 `node` 指令都不认。赛亚人来了都得掉层皮，所以我写了个一键脚本续命 |
| 1 | **内核更新后启动不了** | 10年+ | 更新个 kernel，重启直接 emergency mode。fstab 没 `nofail`、initramfs 没重建、GRUB 写错位置、NVIDIA 驱动炸了……七种死法，总有一款适合你 |

---

## 📊 统计面板

| 指标 | 数值 |
|------|------|
| 已记录坑数 | 2 |
| 其中 Launchpad 有 Bug Report 但十年未修的 | 猜猜看 |
| Ubuntu 官方镜像下一个版本能修好几个 | 我赌 0 个 |
| 这个仓库还要更新多久 | ∞ |

---

## 🙋 如何贡献

你也被 Ubuntu 坑过吗？欢迎提 PR！

1. Fork 本仓库
2. 新建目录 `N.你的坑的简短描述/`
3. 里面放：一篇 Markdown（诊断 + 修复步骤），相关脚本，截图/日志
4. 发 PR，附上 Launchpad Bug Report 链接（如果有的话），我们来比一比谁的 Bug 更长寿
5. 一起骂完，继续用 Ubuntu 🤡

---

## ⚠️ 免责声明

这个仓库叫「ubuntu傻逼」纯属情绪宣泄，不代表我认为 Ubuntu 真的一无是处。
Ubuntu 仍然是最好用的 Linux 发行版之一——尤其在它不出 Bug 的时候。
问题在于，它不出 Bug 的时候比较少。

> **Ubuntu 是一款非常优秀的操作系统，前提是你别用它。**
> —— 某不愿透露姓名的长期 Ubuntu 用户

---

## 📜 许可证

WTFPL — 反正这些 Bug 也不是我写的，解决方案都在网上公开了十几年了，随意取用。
