"""生成 Android 启动图标（含自适应图标）—— **单套**。

输出：
  mipmap-*/ic_launcher.png            传统图标（全幅缩放）
  mipmap-*/ic_launcher_foreground.png 自适应图标前景（66% 安全区，透明底）
  mipmap-anydpi-v26/ic_launcher.xml   自适应图标声明
  values/colors.xml                   自适应图标背景色

历史说明：这里原来还会生成 `ic_launcher_<name>` 这样**多套可切换图标**，
配合 Android 的 `activity-alias` 做「一键换桌面图标」。该功能**已按要求删除**
（不同 ROM 上表现不一致），所以本脚本不再生成多套图标 ——
否则每次跑它都会把已经删掉的死资源又造回来。
"""

import os

from PIL import Image, ImageDraw

SRC = r"C:\Users\user\.dsh\attachments\v1\objects\1b\1b7898b290b252b05ecae17826dd5ed44c30d92d83bc9e007019d9c6c4f174c1"
RES = r"C:\Users\user\Documents\deepseek-harness\default-workspace\tts_reader\android\app\src\main\res"

# 主图标底色（没有 color 资源时用它；自适应图标背景色取自下面这张）
BACKGROUND = (198, 40, 40)

LEGACY = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
# 自适应前景：108dp 画布，内容缩到 66%（72dp 安全区）居中
FOREGROUND = {name: int(size * 108 / 48) for name, size in LEGACY.items()}

source = Image.open(SRC).convert("RGB")
print(f"源图: {source.size[0]}x{source.size[1]}")


def make_foreground(canvas_size: int) -> Image.Image:
    """自适应图标的前景层：透明底 + 居中的圆角图"""
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    inner = int(canvas_size * 0.66)
    art = source.resize((inner, inner), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (inner, inner), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, inner - 1, inner - 1], radius=inner // 6, fill=255
    )
    art.putalpha(mask)
    offset = (canvas_size - inner) // 2
    canvas.paste(art, (offset, offset), art)
    return canvas


def write_adaptive() -> None:
    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background" />\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '</adaptive-icon>\n'
        )


def write_colors() -> None:
    values = os.path.join(RES, "values")
    os.makedirs(values, exist_ok=True)
    with open(os.path.join(values, "colors.xml"), "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<resources>\n"
            f'    <color name="ic_launcher_background">'
            f"#FF{BACKGROUND[0]:02X}{BACKGROUND[1]:02X}{BACKGROUND[2]:02X}</color>\n"
            "</resources>\n"
        )


for folder, size in LEGACY.items():
    path = os.path.join(RES, folder)
    os.makedirs(path, exist_ok=True)
    source.resize((size, size), Image.LANCZOS).save(
        os.path.join(path, "ic_launcher.png")
    )
    make_foreground(FOREGROUND[folder]).save(
        os.path.join(path, "ic_launcher_foreground.png")
    )
    print(f"  {folder}: 传统图标 + 自适应前景")

write_adaptive()
write_colors()
print("完成：单套图标 + colors.xml")
