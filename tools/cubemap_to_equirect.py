"""把 Sky3D 直接渲染的立方体六面转换为 VRSky 使用的 2:1 经纬度 PNG。"""

from __future__ import annotations

import argparse
import os
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


# 每个立方体面记录前、右、上三个正交方向。顺序必须与捕获脚本的相机朝向一致，
# 否则转换后的全景会出现镜像、旋转或面边界错接。
FACE_BASIS = {
    "px": ((1.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.0, 1.0, 0.0)),
    "nx": ((-1.0, 0.0, 0.0), (0.0, 0.0, -1.0), (0.0, 1.0, 0.0)),
    "py": ((0.0, 1.0, 0.0), (-1.0, 0.0, 0.0), (0.0, 0.0, -1.0)),
    "ny": ((0.0, -1.0, 0.0), (-1.0, 0.0, 0.0), (0.0, 0.0, 1.0)),
    "pz": ((0.0, 0.0, 1.0), (-1.0, 0.0, 0.0), (0.0, 1.0, 0.0)),
    "nz": ((0.0, 0.0, -1.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--width", type=int, default=7096)
    parser.add_argument("--minutes", default="0,300,360,480,720,1020,1140,1260")
    return parser.parse_args()


def load_faces(frame_dir: Path) -> dict[str, np.ndarray]:
    """读取同一关键帧的六个面，并在进入大数组计算前验证尺寸一致且为正方形。"""
    faces: dict[str, np.ndarray] = {}
    expected_size: tuple[int, int] | None = None
    for name in FACE_BASIS:
        path = frame_dir / f"{name}.png"
        with Image.open(path) as image:
            rgb = image.convert("RGB")
            if expected_size is None:
                expected_size = rgb.size
            if rgb.size != expected_size or rgb.width != rgb.height:
                raise ValueError(f"cubemap face size mismatch: {path} is {rgb.size}")
            faces[name] = np.asarray(rgb, dtype=np.uint8)
    return faces


def bilinear_sample(face: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """对单个立方体面执行向量化双线性采样，边缘坐标钳制在有效像素内。"""
    size = face.shape[0]
    x = np.clip(x, 0.0, size - 1.0)
    y = np.clip(y, 0.0, size - 1.0)
    x0 = np.floor(x).astype(np.int32)
    y0 = np.floor(y).astype(np.int32)
    x1 = np.minimum(x0 + 1, size - 1)
    y1 = np.minimum(y0 + 1, size - 1)
    wx = (x - x0)[..., None]
    wy = (y - y0)[..., None]
    top = face[y0, x0] * (1.0 - wx) + face[y0, x1] * wx
    bottom = face[y1, x0] * (1.0 - wx) + face[y1, x1] * wx
    return top * (1.0 - wy) + bottom * wy


def convert_frame(faces: dict[str, np.ndarray], width: int) -> Image.Image:
    """把一个立方体关键帧投影为宽高比 2:1 的经纬度全景图。"""
    if width < 512 or width % 2:
        raise ValueError("width must be an even integer of at least 512")
    height = width // 2
    face_size = next(iter(faces.values())).shape[0]
    output = np.empty((height, width, 3), dtype=np.uint8)
    longitude = (np.arange(width, dtype=np.float32) + 0.5) / width
    longitude = (longitude * 2.0 - 1.0) * np.pi

    # 分块处理纬度行，限制 7096×3548 输出时方向向量和中间浮点数组的峰值内存。
    chunk_rows = 128
    for row_start in range(0, height, chunk_rows):
        row_end = min(row_start + chunk_rows, height)
        latitude = (np.arange(row_start, row_end, dtype=np.float32) + 0.5) / height
        latitude = (0.5 - latitude) * np.pi
        cos_lat = np.cos(latitude)[:, None]
        directions = np.empty((row_end - row_start, width, 3), dtype=np.float32)
        directions[..., 0] = cos_lat * np.cos(longitude)[None, :]
        directions[..., 1] = np.sin(latitude)[:, None]
        directions[..., 2] = cos_lat * np.sin(longitude)[None, :]

        # 绝对值最大的方向分量决定命中的立方体轴，符号再区分正面和负面。
        major_axis = np.argmax(np.abs(directions), axis=2)
        positive = np.take_along_axis(directions, major_axis[..., None], axis=2)[..., 0] >= 0.0
        face_indices = major_axis * 2 + (~positive)
        chunk = np.empty((row_end - row_start, width, 3), dtype=np.float32)

        face_order = ("px", "nx", "py", "ny", "pz", "nz")
        for face_index, name in enumerate(face_order):
            mask = face_indices == face_index
            if not np.any(mask):
                continue
            forward, right, up = (np.asarray(v, dtype=np.float32) for v in FACE_BASIS[name])
            selected = directions[mask]
            denominator = selected @ forward
            screen_x = (selected @ right) / denominator
            screen_y = (selected @ up) / denominator
            pixel_x = (screen_x + 1.0) * 0.5 * (face_size - 1)
            pixel_y = (1.0 - screen_y) * 0.5 * (face_size - 1)
            chunk[mask] = bilinear_sample(faces[name], pixel_x, pixel_y)

        output[row_start:row_end] = np.clip(chunk + 0.5, 0, 255).astype(np.uint8)

    panorama = Image.fromarray(output, mode="RGB")
    # 天空直接渲染保留了云层信号，但经纬度重采样会自然变软。最终分辨率上使用克制的
    # 反锐化遮罩恢复局部对比度，同时避免在地平线或立方体面边缘制造明显光晕。
    return panorama.filter(ImageFilter.UnsharpMask(radius=1.4, percent=135, threshold=3))


def replace_with_retry(staging_path: Path, output_path: Path) -> None:
    # Godot 导入器和 Windows 安全扫描器可能短暂占用刚写入的 PNG。先写暂存文件，
    # 再重试同卷原子替换，确保失败时不会留下半写入的正式天空资源。
    for attempt in range(10):
        try:
            os.replace(staging_path, output_path)
            return
        except PermissionError:
            if attempt == 9:
                raise
            time.sleep(0.25)


def main() -> None:
    args = parse_args()
    minutes = [int(value) for value in args.minutes.split(",") if value]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    # 所有帧先成功写入独立暂存文件，再统一替换正式资源，降低半套时间轴被更新的风险。
    staged: list[tuple[Path, Path]] = []
    for minute in minutes:
        faces = load_faces(args.input_dir / f"{minute:04d}")
        panorama = convert_frame(faces, args.width)
        file_name = f"sky_{minute // 60:02d}{minute % 60:02d}.png"
        output_path = args.output_dir / file_name
        staging_path = args.output_dir / f".{file_name}.direct-render.png"
        panorama.save(staging_path, format="PNG", compress_level=6)
        staged.append((staging_path, output_path))
        print(f"Converted {file_name} ({panorama.width}x{panorama.height})", flush=True)

    for staging_path, output_path in staged:
        replace_with_retry(staging_path, output_path)


if __name__ == "__main__":
    main()
