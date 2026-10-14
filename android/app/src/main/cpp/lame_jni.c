/*
 * LAME 的 JNI 包装（★v1.21.45 改动 5：音频导出改 MP3）
 *
 * ## 这里做什么
 *
 * 1. 解析 WAV 头（RIFF / fmt / data），取出 PCM 区间与格式；
 * 2. 用 LAME（libmp3lame）把 PCM 编成 MP3 帧写进目标文件。
 *
 * ## 为什么放在一个 .so 里
 *
 * LAME 是 LGPL-2.0：**动态链接**（独立的 liblame.so）就算合规，
 * 而把 LAME 与这个薄包装编进同一个 .so，最省事也最少踩坑
 * （不用再管两个库的加载顺序）。它的源码与编译脚本都在仓库里
 * （见 tool/build_lame.ps1），满足 LGPL 对"可重新链接"的要求。
 *
 * ## 兼容性策略（重要）
 *
 * 真机上 `flutter_tts.synthesizeToFile` 到底吐**标准 WAV 头**还是**裸 PCM**，
 * 没有设备时无法验证 —— 所以这里**只接受标准 WAV**：
 * 不是 RIFF/WAVE 就直接返回 false，Dart 侧照旧保留 WAV（老行为）。
 * 拿到 false 的日志会打出原因，真机跑一次就知道要不要补裸 PCM 分支。
 */

#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <android/log.h>

#include "lame.h"

#define LOG_TAG "TTS_LAME"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/** 一次送给 LAME 的采样点上限（够大以免频繁调用，又不会吃太多栈） */
#define PCM_CHUNK 8192

/** 读 4 字节小端 */
static uint32_t rd_u32(const unsigned char *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static uint16_t rd_u16(const unsigned char *p) {
    return (uint16_t) (p[0] | (p[1] << 8));
}

/**
 * 解析 WAV 头。
 *
 * 成功返回 1，并填好 [dataOffset]（data 块起点）、[dataLen]、[channels]、
 * [sampleRate]、[bitsPerSample]；不是标准 WAV / 不是 16bit PCM 时返回 0。
 *
 * ⚠️ 只支持 **16bit PCM**（Android 各 TTS 引擎的 synthesizeToFile 都是这个格式）；
 * 其它位深返回 0，让上层退回 WAV —— 宁可不转，也不要出个坏 MP3。
 */
static int parse_wav(FILE *f, long *dataOffset, long *dataLen,
                     int *channels, int *sampleRate, int *bitsPerSample) {
    unsigned char hdr[12];
    if (fseek(f, 0, SEEK_SET) != 0) return 0;
    if (fread(hdr, 1, 12, f) != 12) return 0;
    if (memcmp(hdr, "RIFF", 4) != 0 || memcmp(hdr + 8, "WAVE", 4) != 0) {
        LOGE("不是 RIFF/WAVE 头（前 4 字节 %.4s）", hdr);
        return 0;
    }

    int haveFmt = 0;
    unsigned char chunk[8];
    while (fread(chunk, 1, 8, f) == 8) {
        const uint32_t size = rd_u32(chunk + 4);
        if (memcmp(chunk, "fmt ", 4) == 0) {
            unsigned char fmt[40];
            const size_t want = size < sizeof(fmt) ? size : sizeof(fmt);
            if (fread(fmt, 1, want, f) != want) return 0;
            const uint16_t audioFormat = rd_u16(fmt);
            *channels = rd_u16(fmt + 2);
            *sampleRate = (int) rd_u32(fmt + 4);
            *bitsPerSample = rd_u16(fmt + 14);
            haveFmt = 1;
            if (audioFormat != 1) { /* 1 = PCM */
                LOGE("不是 PCM（audioFormat=%u）", (unsigned) audioFormat);
                return 0;
            }
            // fmt 块可能比 16 字节长（cbSize / 扩展），多出来的要跳过
            if (size > want && fseek(f, (long) (size - want), SEEK_CUR) != 0) return 0;
            continue;
        }
        if (memcmp(chunk, "data", 4) == 0) {
            if (!haveFmt) {
                LOGE("data 块出现在 fmt 之前，放弃");
                return 0;
            }
            *dataOffset = ftell(f);
            *dataLen = (long) size;
            if (*bitsPerSample != 16) {
                LOGE("只支持 16bit PCM（本文件 %d bit）", *bitsPerSample);
                return 0;
            }
            if (*channels != 1 && *channels != 2) {
                LOGE("声道数不支持（%d）", *channels);
                return 0;
            }
            if (*sampleRate <= 0 || *sampleRate > 192000) {
                LOGE("采样率异常（%d）", *sampleRate);
                return 0;
            }
            LOGI("WAV ok: %d Hz, %d ch, %d bit, data=%ld 字节",
                 *sampleRate, *channels, *bitsPerSample, *dataLen);
            return 1;
        }
        // 其它块（LIST / fact / id3 …）整块跳过
        if (fseek(f, (long) size, SEEK_CUR) != 0) return 0;
    }
    LOGE("没找到 data 块");
    return 0;
}

/**
 * 把 [wavPath] 转成 [mp3Path]。
 *
 * 成功返回 JNI_TRUE，任何失败都返回 JNI_FALSE（**不抛异常** ——
 * Dart 侧靠返回值决定是否回退到 WAV，抛异常反而要多写一层 try）。
 */
static jboolean encode_wav_to_mp3(const char *wavPath, const char *mp3Path, int bitrate) {
    FILE *in = NULL;
    FILE *out = NULL;
    lame_t gf = NULL;
    unsigned char *mp3buf = NULL;
    short *pcm = NULL;
    jboolean ok = JNI_FALSE;

    long dataOffset = 0, dataLen = 0;
    int channels = 0, sampleRate = 0, bits = 0;

    in = fopen(wavPath, "rb");
    if (in == NULL) {
        LOGE("打不开 WAV：%s", wavPath);
        goto done;
    }
    if (!parse_wav(in, &dataOffset, &dataLen, &channels, &sampleRate, &bits)) {
        goto done; // parse_wav 里已经打过原因
    }
    if (dataLen <= 0) {
        // 有些文件头里的 size 是 0 / 0xFFFFFFFF（流式写的）：按"到文件尾"处理
        if (fseek(in, 0, SEEK_END) != 0) goto done;
        const long end = ftell(in);
        dataLen = end - dataOffset;
        LOGI("data 块长度无效，按文件尾算：%ld 字节", dataLen);
        if (dataLen <= 0) goto done;
    }
    if (fseek(in, dataOffset, SEEK_SET) != 0) goto done;

    gf = lame_init();
    if (gf == NULL) {
        LOGE("lame_init 失败");
        goto done;
    }
    lame_set_in_samplerate(gf, sampleRate);
    lame_set_num_channels(gf, channels);
    lame_set_brate(gf, bitrate > 0 ? bitrate : 64);
    lame_set_quality(gf, 2);          // 0 最慢最好、9 最快最差；2 是"高质量"档
    lame_set_mode(gf, channels == 1 ? MONO : JOINT_STEREO);
    if (lame_init_params(gf) < 0) {
        LOGE("lame_init_params 失败");
        goto done;
    }

    out = fopen(mp3Path, "wb");
    if (out == NULL) {
        LOGE("写不了 MP3：%s", mp3Path);
        goto done;
    }

    mp3buf = (unsigned char *) malloc((size_t) PCM_CHUNK * 5 / 4 + 7200);
    pcm = (short *) malloc((size_t) PCM_CHUNK * 2 * sizeof(short));
    if (mp3buf == NULL || pcm == NULL) {
        LOGE("内存不足");
        goto done;
    }

    long remaining = dataLen;
    while (remaining > 0) {
        const int wantSamples = (int) (remaining / (2 * channels));
        const int take = wantSamples > PCM_CHUNK ? PCM_CHUNK : wantSamples;
        if (take <= 0) break;
        const size_t wantBytes = (size_t) take * channels * 2;
        const size_t got = fread(pcm, 1, wantBytes, in);
        if (got < wantBytes) break; // 文件被截断 → 用已经读到的收尾
        const int nsamples = (int) (got / (2 * channels));
        const int written = (channels == 1)
            ? lame_encode_buffer(gf, pcm, pcm, nsamples, mp3buf,
                                 (int) ((size_t) PCM_CHUNK * 5 / 4 + 7200))
            : lame_encode_buffer_interleaved(gf, pcm, nsamples, mp3buf,
                                             (int) ((size_t) PCM_CHUNK * 5 / 4 + 7200));
        if (written < 0) {
            LOGE("lame_encode 失败：%d", written);
            goto done;
        }
        if (written > 0 && fwrite(mp3buf, 1, (size_t) written, out) != (size_t) written) {
            LOGE("写 MP3 失败");
            goto done;
        }
        remaining -= (long) got;
    }

    {
        const int flushed = lame_encode_flush(gf, mp3buf, (int) ((size_t) PCM_CHUNK * 5 / 4 + 7200));
        if (flushed < 0) {
            LOGE("lame_encode_flush 失败：%d", flushed);
            goto done;
        }
        if (flushed > 0 && fwrite(mp3buf, 1, (size_t) flushed, out) != (size_t) flushed) {
            LOGE("写 MP3（flush）失败");
            goto done;
        }
    }

    LOGI("转码成功：%s → %s（%d kbps）", wavPath, mp3Path, bitrate > 0 ? bitrate : 64);
    ok = JNI_TRUE;

done:
    if (pcm != NULL) free(pcm);
    if (mp3buf != NULL) free(mp3buf);
    if (out != NULL) fclose(out);
    if (in != NULL) fclose(in);
    if (gf != NULL) lame_close(gf);
    if (ok == JNI_FALSE && mp3Path != NULL) remove(mp3Path); // 半成品不要留给用户
    return ok;
}

/* ---------------------------------------------------------------- JNI 入口 */

/**
 * Kotlin 侧：`com.example.tts_reader.LameEncoder.encodeWavToMp3`
 *
 * ⚠️ 同时提供两条绑定路径，避免"符号名对不上 → UnsatisfiedLinkError"这种
 * 只能在真机上才发现的坑：
 * 1. 标准 mangled 名（Kotlin `object` 的方法是**实例方法**，所以第二参是 jobject）；
 * 2. `JNI_OnLoad` 里 `RegisterNatives` 显式绑定（不依赖名字修饰规则）。
 */
JNIEXPORT jboolean JNICALL
Java_com_example_tts_reader_LameEncoder_encodeWavToMp3(
        JNIEnv *env, jobject thiz, jstring wavPath, jstring mp3Path, jint bitrate) {
    (void) thiz;
    if (wavPath == NULL || mp3Path == NULL) return JNI_FALSE;
    const char *wav = (*env)->GetStringUTFChars(env, wavPath, NULL);
    if (wav == NULL) return JNI_FALSE;
    const char *mp3 = (*env)->GetStringUTFChars(env, mp3Path, NULL);
    if (mp3 == NULL) {
        (*env)->ReleaseStringUTFChars(env, wavPath, wav);
        return JNI_FALSE;
    }

    const jboolean ok = encode_wav_to_mp3(wav, mp3, (int) bitrate);

    (*env)->ReleaseStringUTFChars(env, mp3Path, mp3);
    (*env)->ReleaseStringUTFChars(env, wavPath, wav);
    return ok;
}

/** LAME 版本号（诊断用：确认打进包里的确实是 3.100） */
JNIEXPORT jstring JNICALL
Java_com_example_tts_reader_LameEncoder_lameVersion(JNIEnv *env, jobject thiz) {
    (void) thiz;
    return (*env)->NewStringUTF(env, get_lame_version());
}

static const JNINativeMethod kMethods[] = {
        {"encodeWavToMp3", "(Ljava/lang/String;Ljava/lang/String;I)Z",
         (void *) Java_com_example_tts_reader_LameEncoder_encodeWavToMp3},
        {"lameVersion", "()Ljava/lang/String;",
         (void *) Java_com_example_tts_reader_LameEncoder_lameVersion},
};

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void) reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **) &env, JNI_VERSION_1_6) != JNI_OK) return JNI_VERSION_1_6;

    jclass cls = (*env)->FindClass(env, "com/example/tts_reader/LameEncoder");
    if (cls != NULL) {
        if ((*env)->RegisterNatives(env, cls, kMethods, 2) == 0) {
            LOGI("RegisterNatives ok（LAME %s）", get_lame_version());
        } else {
            LOGE("RegisterNatives 失败，靠 mangled 符号兜底");
        }
    } else {
        // 类还没加载：正常，mangled 符号那条路仍然有效
        LOGI("LameEncoder 尚未加载，跳过 RegisterNatives");
    }
    return JNI_VERSION_1_6;
}
