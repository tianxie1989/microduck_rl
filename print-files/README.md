# microduck 3D 打印文件(拓竹 Bambu Studio)

- `microduck_thick_complete.stl`:完整加厚鸭子单体(展示/雕像用,非功能件)。
- `parts\*.stl`:43 个零件分件(毫米制),组装真机用;其中 8 件外壳为加厚版:
  right_shell, left_shell, face_part, jaw_soft, top_head_shell, soft_mouth_top, jaw, bottom_head_shell

## 建议打印参数(Bambu Studio)

- 材料:PLA / PETG(结构件);外壳可用 ABS 更耐摔
- 层高:0.2 mm(精细件 0.12 mm)
- 填充:外壳 20-30%;腿/髋/支撑件 40-60%(受力件)
- 壁厚:3 层(外壳件)
- 支撑:树状支撑,阈值角 45°(上壳/下颚等悬空处)
- 摆放:导入后自动排列;舵机孔位朝上打印

## 注意

- 分件为原始尺寸+加厚外壳,未做打印补偿(孔位收缩约 0.2-0.3 mm,
  必要时 Bambu Studio 中设置 XY 补偿)
- 完整单体尺寸:[148.8, 144.8, 268.8] mm
