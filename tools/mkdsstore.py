#!/usr/bin/env python3
"""给 DMG 卷写 .DS_Store：窗口大小、图标大小、背景图、图标位置。

用法：mkdsstore.py <卷挂载路径> [背景图相对路径]

为什么不走 AppleScript：`tell application "Finder"` 需要「自动化」TCC 授权，
在非交互环境里会静默失败（-1728 / -1743）。直接写 .DS_Store 是纯文件操作，
不需要任何授权，且结果和 Finder 自己排完版一模一样。
"""
import os
import sys

from ds_store import DSStore
from mac_alias import Alias

# 版面参数（单位 pt），与 tools/Artwork.swift 里画的 900×440 背景严格对齐
WINDOW_BOUNDS = "{{200, 180}, {900, 468}}"   # 含标题栏；内容区 900×440
ICON_SIZE = 120.0
POSITIONS = {
    "云枢开关.app": (130, 160),   # 图标左上角坐标（y 自内容区顶部向下）
    "应用程序": (390, 160),
    "使用说明.txt": (640, 160),
}
BACKGROUND = ".background/bg.png"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    vol = sys.argv[1]
    bg_rel = sys.argv[2] if len(sys.argv) > 2 else BACKGROUND

    store = os.path.join(vol, ".DS_Store")
    bg_path = os.path.join(vol, bg_rel)

    with DSStore.open(store, "w+") as d:
        # 标记这个文件夹的显示设置已由外部写入
        d["."]["vSrn"] = ("long", 1)

        d["."]["bwsp"] = {
            "WindowBounds": WINDOW_BOUNDS,
            "ShowSidebar": False,
            "ShowStatusBar": False,
            "ShowPathbar": False,
            "ShowTabView": False,
            "ShowToolbar": False,
            "ContainerShowSidebar": False,
            "PreviewPaneVisibility": False,
            "SidebarWidth": 0,
            "SidebarShowingSections": 0,
        }

        icvp = {
            "viewOptionsVersion": 1,
            "arrangeBy": "none",
            "showIconPreview": False,
            "showItemInfo": False,
            "labelOnBottom": True,
            "gridSpacing": 100.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
            "textSize": 13.0,
            "iconSize": ICON_SIZE,
        }
        if os.path.exists(bg_path):
            icvp["backgroundType"] = 2          # 2 = 背景图片
            icvp["backgroundImageAlias"] = Alias.for_file(bg_path).to_bytes()
        else:
            icvp["backgroundType"] = 1          # 1 = 纯白
        d["."]["icvp"] = icvp

        for name, pos in POSITIONS.items():
            if os.path.exists(os.path.join(vol, name)):
                d[name]["Iloc"] = pos
            else:
                print(f"  跳过（卷里没有）：{name}")

    print(f"  .DS_Store 已写入 {store}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
