"""把「下载完成提示」的三个候选方案画成一张对比图（给用户挑样式）。

为什么要用 Pillow 画：Flutter 的测试环境里只有 Ahem 字体，中文全是方框，
拿来当设计稿给人看没法读。这里用系统微软雅黑，能显示真中文。
"""
from PIL import Image, ImageDraw, ImageFont

W, H = 1080, 1500
BG = (244, 241, 250)
CARD = (233, 227, 243)
CARD2 = (226, 220, 240)
PRIMARY = (103, 80, 164)
PRIMARY_SOFT = (232, 222, 248)
TEXT = (29, 27, 32)
MUTED = (73, 69, 79)
WHITE = (255, 255, 255)

F_TITLE = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 34)
F_BODY = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 30)
F_SMALL = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 24)
F_BTN = ImageFont.truetype(r"C:\Windows\Fonts\msyhbd.ttc", 28)
F_LABEL = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 26)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)


def label(y, text):
    d.text((36, y), text, font=F_LABEL, fill=MUTED)


def rrect(box, r, fill, outline=None, width=2):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def txt_center(cx, cy, text, font, fill):
    w = d.textlength(text, font=font)
    bbox = font.getbbox(text)
    h = bbox[3] - bbox[1]
    d.text((cx - w / 2, cy - h / 2 - bbox[1]), text, font=font, fill=fill)


BOOK = "钢铁是怎样炼成的"

# ---------------- 方案 1：底部提示条 ----------------
label(40, "方案 1：底部提示条（图标 + 立即朗读 + ✕ + 倒计时细条）")
y = 90
rrect((36, y, W - 36, y + 214), 32, CARD)
# 圆形图标
d.ellipse((68, y + 52, 140, y + 124), fill=PRIMARY_SOFT)
d.ellipse((90, y + 74, 118, y + 102), fill=PRIMARY)
d.text((166, y + 44), "已下载并导入文档库", font=F_BODY, fill=TEXT)
d.text((168, y + 92), BOOK, font=F_SMALL, fill=MUTED)
# 主按钮
rrect((W - 400, y + 58, W - 200, y + 122), 32, PRIMARY_SOFT)
txt_center((W - 300), y + 90, "立即朗读", F_BTN, PRIMARY)
# 关闭
d.line((W - 140, y + 74, W - 112, y + 102), fill=MUTED, width=5)
d.line((W - 140, y + 102, W - 112, y + 74), fill=MUTED, width=5)
# 倒计时细条（贴底）
d.rounded_rectangle((36, y + 204, W - 36, y + 214), radius=5, fill=(214, 206, 232))
d.rounded_rectangle((36, y + 204, 36 + int((W - 72) * 0.42), y + 214), radius=5, fill=PRIMARY)

# ---------------- 方案 2：迷你卡片（带封面） ----------------
label(330, "方案 2：迷你卡片（封面缩略图 + 播放键，像播放器小条）")
y = 380
rrect((36, y, W - 36, y + 200), 36, CARD)
# 封面
cov = Image.new("RGB", (120, 164))
cd = ImageDraw.Draw(cov)
for i in range(164):
    t = i / 163
    cd.line([(0, i), (120, i)], fill=(int(91 + (46 - 91) * t), int(70 + (34 - 70) * t), int(150 + (92 - 150) * t)))
d.rounded_rectangle((70, y + 18, 190, y + 182), radius=18, fill=None, outline=None)
mask = Image.new("L", cov.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 120, 164), radius=18, fill=255)
img.paste(cov, (70, y + 18), mask)
d.text((212, y + 46), BOOK, font=F_TITLE, fill=TEXT)
d.ellipse((212, y + 112, 232, y + 132), fill=PRIMARY)
d.text((242, y + 108), "已加入文档库", font=F_SMALL, fill=MUTED)
# 播放键
d.ellipse((W - 350, y + 62, W - 234, y + 138), fill=PRIMARY_SOFT)
d.polygon([(W - 300, y + 78), (W - 300, y + 122), (W - 266, y + 100)], fill=PRIMARY)
# 关闭
d.line((W - 150, y + 86, W - 122, y + 114), fill=MUTED, width=5)
d.line((W - 150, y + 114, W - 122, y + 86), fill=MUTED, width=5)

# ---------------- 方案 3：顶部横幅 ----------------
label(620, "方案 3：顶部横幅（贴住顶部，不挡底部按钮）")
y = 670
rrect((36, y, W - 36, y + 130), 26, CARD2)
# 下载完成图标
d.ellipse((70, y + 44, 122, y + 96), fill=PRIMARY)
d.line((96, y + 58, 96, y + 82), fill=WHITE, width=6)
d.line((84, y + 72, 96, y + 84), fill=WHITE, width=6)
d.line((108, y + 72, 96, y + 84), fill=WHITE, width=6)
d.text((146, y + 34), "已下载：" + BOOK, font=F_BODY, fill=TEXT)
d.text((146, y + 76), "已加入文档库", font=F_SMALL, fill=MUTED)
rrect((W - 340, y + 34, W - 200, y + 96), 26, PRIMARY_SOFT)
txt_center((W - 270), y + 65, "朗读", F_BTN, PRIMARY)
d.line((W - 150, y + 52, W - 122, y + 80), fill=MUTED, width=5)
d.line((W - 150, y + 80, W - 122, y + 52), fill=MUTED, width=5)

# ---------------- 方案 4：悬浮圆角卡（居中偏下，带倒计时环） ----------------
label(860, "方案 4：悬浮卡（带倒计时圆环，3 秒自动收起）")
y = 910
rrect((36, y, W - 36, y + 280), 40, CARD)
d.text((84, y + 40), "下载完成", font=F_TITLE, fill=TEXT)
d.text((84, y + 96), BOOK, font=F_BODY, fill=MUTED)
d.text((84, y + 150), "已加入文档库，可以直接开始朗读", font=F_SMALL, fill=MUTED)
# 倒计时环
cx, cy, r = W - 130, y + 78, 34
d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(214, 206, 232), width=8)
d.arc((cx - r, cy - r, cx + r, cy + r), start=-90, end=90, fill=PRIMARY, width=8)
txt_center(cx, cy, "3", F_BTN, PRIMARY)
# 两个按钮
rrect((84, y + 206, 84 + 300, y + 266), 30, PRIMARY)
txt_center(84 + 150, y + 236, "立即朗读", F_BTN, WHITE)
rrect((404, y + 206, 404 + 200, y + 266), 30, PRIMARY_SOFT)
txt_center(404 + 100, y + 236, "关闭", F_BTN, PRIMARY)

img.save(r"D:\dsh\tts_reader\build\download_toast_mockups.png")
print("OK", img.size)
