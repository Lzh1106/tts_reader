import 'package:flutter/foundation.dart';

/// 第三方组件在应用内展示的许可声明（★v1.21.45 改动 5）
///
/// ## 为什么要这个
///
/// MP3 导出用到了 **LAME 3.100**（`liblame.so`），它是 **LGPL-2.0**：
/// 动态链接（独立 .so）本身合规，但"要给出声明、附上许可证、并让使用者能替换它"
/// 这几条必须做到。Flutter 自带的「开源许可」页（`showLicensePage`）会列出
/// pub 依赖，**不会**知道我们手工引入的原生库 —— 所以要自己注册进去。
///
/// ## 为什么把源码地址和编译脚本一起写出来
///
/// LGPL 的"可重新链接"要求：使用者要能替换掉这个库。我们把构建方式完整留在仓库里
/// （`tool/build_lame.ps1` + `android/app/src/main/cpp/`），声明里写清位置，
/// 任何人按其重建一个 `liblame.so` 即可替换 —— 这就是满足该条要求的方式。
void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      <String>['LAME (libmp3lame)'],
      '''
LAME 3.100 —— MP3 音频编码器
https://lame.sourceforge.io/

本应用通过独立动态库 liblame.so 使用 LAME（LGPL-2.0），
用于把系统语音引擎合成的 WAV 转成 MP3。LAME 以动态链接方式使用，
其源代码可从上面官网获取；本工程的获取与编译方式见仓库中的：

  · tool/build_lame.ps1                    下载 + 校验 + 交叉编译（三个 ABI）
  · android/app/src/main/cpp/CMakeLists.txt 构建配置
  · android/app/src/main/cpp/lame_jni.c     本应用自己的 JNI 包装（薄薄一层）

按 LGPL-2.0 的条款，你可以自行编译一个 liblame.so 替换本应用内的同名文件。

LAME is free software; you can redistribute it and/or modify it under the terms
of the GNU Lesser General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

LAME is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
''',
    );
  });
}
