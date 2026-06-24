# 工作学习日志

每月一个文件，记录每天的工作内容、学习收获和踩坑记录。

## 文件命名

```
logs/
├── 2026-06.md
├── 2026-07.md
└── ...
```

## 检索方法

```bash
# 本地搜索关键词（如查所有 bypy 相关记录）
grep -r "bypy" logs/

# 搜索某个标签
grep -r "#backup" logs/

# 搜索某个日期
grep -A 20 "## 2026-06-24" logs/2026-06.md

# 搜索某类问题
grep -r "遇到的问题" logs/ -A 5
```

## GitHub 检索

在仓库页面按 `t` 键，或使用 GitHub 搜索：

```
repo:CN-big-cabbage/llm-in-practise bypy
repo:CN-big-cabbage/llm-in-practise #kubernetes
```

## 写日志的时机

- 每天结束时花 5 分钟填写
- 或者遇到重要问题解决后随手记
- 不需要面面俱到，**踩的坑和学到的东西** 最有价值
