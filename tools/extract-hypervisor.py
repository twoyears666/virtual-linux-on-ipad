#!/usr/bin/env python3
"""从本机 dyld 共享缓存抽出 Hypervisor.framework，改成 iOS 可加载形态并用 ldid 重签。

macOS 15 起 Hypervisor 二进制不再以文件形式落在磁盘上，只在 dyld 共享缓存里，
所以这里借 ipsw 工具把它单独抽出来：
    brew install blacktop/tap/ipsw ldid
    python3 tools/extract-hypervisor.py

产物放在 build-private/Frameworks/Hypervisor.framework，打包时会被拷进 App 的 Frameworks/。
Apple 私有二进制版权原因不入库（见 .gitignore）。
"""

import argparse
import pathlib
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

IMAGE_PATH = "/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor"
DEFAULT_CACHE_DIR = pathlib.Path("/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld")
OUTPUT_DIR = pathlib.Path(__file__).resolve().parent.parent / "build-private/Frameworks"

MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
IOS_MINIMUM = 14 * 0x10000
IOS_SDK = 16 * 0x10000


def find_cache(cache_dir: pathlib.Path) -> pathlib.Path:
    for name in ("dyld_shared_cache_arm64e", "dyld_shared_cache_arm64"):
        candidate = cache_dir / name
        if candidate.exists():
            return candidate
    sys.exit(f"在 {cache_dir} 里找不到 arm64 的 dyld 共享缓存")


def extract(cache: pathlib.Path) -> pathlib.Path:
    temp_dir = pathlib.Path(tempfile.mkdtemp(prefix="vl-hypervisor-"))
    result = subprocess.run(
        ["ipsw", "dyld", "extract", str(cache), IMAGE_PATH, "-o", str(temp_dir)],
        capture_output=True,
        text=True,
    )
    extracted = temp_dir / "Hypervisor"
    if result.returncode != 0 or not extracted.exists():
        shutil.rmtree(temp_dir, ignore_errors=True)
        sys.exit(f"ipsw 抽取失败：{result.stderr.strip() or result.stdout.strip()}")
    return extracted


def patch_platform(binary: pathlib.Path) -> None:
    """把 macOS 平台、15.6 最低版本改成 iOS 14.0，否则设备上的 dyld 不认这个二进制。"""
    data = bytearray(binary.read_bytes())
    magic, _, _, _, ncmds, sizeofcmds, _ = struct.unpack_from("<7I", data, 0)
    if magic != MH_MAGIC_64:
        sys.exit("抽出来的不是 64 位 Mach-O，检查缓存架构")
    print(f"共 {ncmds} 条 load command，占 {sizeofcmds} 字节")

    offset = 32
    end = offset + sizeofcmds
    patched = False
    while offset + 8 <= end:
        command, command_size = struct.unpack_from("<2I", data, offset)
        if command_size < 8:
            sys.exit(f"load command 长度异常（{command_size}），放弃修改")
        if command == LC_BUILD_VERSION:
            _, _, platform, minos, sdk = struct.unpack_from("<5I", data, offset)
            struct.pack_into("<I", data, offset + 8, PLATFORM_IOS)
            struct.pack_into("<I", data, offset + 12, IOS_MINIMUM)
            struct.pack_into("<I", data, offset + 16, IOS_SDK)
            patched = True
            print(f"平台 {platform} → {PLATFORM_IOS}，最低版本 0x{minos:x} → 0x{IOS_MINIMUM:x}")
        offset += command_size

    if not patched:
        sys.exit("没找到 LC_BUILD_VERSION，无法改成 iOS 形态")
    binary.write_bytes(data)


def assemble(extracted: pathlib.Path, output_dir: pathlib.Path) -> pathlib.Path:
    framework = output_dir / "Hypervisor.framework"
    if framework.exists():
        shutil.rmtree(framework)
    framework.mkdir(parents=True)

    binary = framework / "Hypervisor"
    # 不能用 copy2：系统里的 Info.plist 带 schg 之类文件标志，复制元数据会被系统拒绝。
    shutil.copyfile(extracted, binary)
    patch_platform(binary)

    plist_path = framework / "Info.plist"
    plist_path.write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "com.apple.Hypervisor",
                "CFBundleExecutable": "Hypervisor",
                "CFBundleName": "Hypervisor",
                "CFBundlePackageType": "FMWK",
                "CFBundleVersion": "210.7.3",
                "CFBundleShortVersionString": "1.0",
            }
        )
    )

    # 必须用 codesign，不能用 ldid -S：ldid 会重建 LINKEDIT，把共享缓存里带出来的
    # LC_DYLD_CHAINED_FIXUPS 丢掉，dyld 就没法做指针绑定，dlopen 的瞬间进程就被杀，
    # 而且不会留下任何崩溃日志。
    result = subprocess.run(["codesign", "--force", "--sign", "-", str(binary)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"codesign 重签失败：{result.stderr.strip()}")
    return framework


def main() -> None:
    parser = argparse.ArgumentParser(description="抽取并重签 Hypervisor.framework")
    parser.add_argument("--cache-dir", type=pathlib.Path, default=DEFAULT_CACHE_DIR)
    parser.add_argument("--output", type=pathlib.Path, default=OUTPUT_DIR)
    arguments = parser.parse_args()

    cache = find_cache(arguments.cache_dir)
    extracted = extract(cache)
    framework = assemble(extracted, arguments.output)
    shutil.rmtree(extracted.parent, ignore_errors=True)
    print(f"完成：{framework}")


if __name__ == "__main__":
    main()
