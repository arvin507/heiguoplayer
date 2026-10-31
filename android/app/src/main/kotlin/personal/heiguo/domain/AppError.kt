package personal.heiguo.domain

import kotlin.coroutines.cancellation.CancellationException

/** 业务层统一的错误。code 保留 SDK 的错误码用于调试，userMessage 是给用户看的中文。 */
class AppError(
    val code: Code,
    val debugMessage: String = "",
    /** 服务端建议的等待时间（秒）；null 表示没有建议。 */
    val retryAfter: Double? = null,
) : Exception("[${code.raw}] $debugMessage") {

    enum class Code(val raw: String) {
        INVALID_OPTIONS("INVALID_OPTIONS"), PROFILE_NOT_FOUND("PROFILE_NOT_FOUND"),
        SIGNER_UNAVAILABLE("SIGNER_UNAVAILABLE"), AUTHENTICATION_REQUIRED("AUTHENTICATION_REQUIRED"),
        NOT_PROTECTED("NOT_PROTECTED"), DRM_PROTECTED("DRM_PROTECTED"),
        ANONYMOUS_LIMITED("ANONYMOUS_LIMITED"), RATE_LIMITED("RATE_LIMITED"), TRANSPORT("TRANSPORT"),
        SIGNATURE_REJECTED("SIGNATURE_REJECTED"), CONTENT_UNAVAILABLE("CONTENT_UNAVAILABLE"),
        PARAM_INVALID("PARAM_INVALID"), CHALLENGE_REQUIRED("CHALLENGE_REQUIRED"),
        DEVICE_REJECTED("DEVICE_REJECTED"), END_OF_LIST("END_OF_LIST"),
        ALBUM_UNAVAILABLE("ALBUM_UNAVAILABLE"), CANCELLED("CANCELLED"), UNKNOWN("UNKNOWN"),

        // App 自己的
        PLAYBACK_QUOTA_EXHAUSTED("APP_PLAYBACK_QUOTA_EXHAUSTED"),
        NO_PLAYABLE_STREAM("APP_NO_PLAYABLE_STREAM"),
        DECODING("APP_DECODING"),
        INVALID_LINK("APP_INVALID_LINK"),
    }

    /** 界面上是否显示“重试”按钮。 */
    val isRetryable: Boolean
        get() = when (code) {
            Code.TRANSPORT, Code.RATE_LIMITED, Code.UNKNOWN, Code.DECODING,
            Code.PLAYBACK_QUOTA_EXHAUSTED, Code.ANONYMOUS_LIMITED, Code.DEVICE_REJECTED -> true
            else -> false
        }

    val userMessage: String
        get() = when (code) {
            Code.TRANSPORT -> "网络连接失败，请检查网络后重试"
            Code.RATE_LIMITED -> {
                val s = retryAfter
                if (s != null && s > 0) "请求太频繁，请约 ${kotlin.math.ceil(s).toInt()} 秒后再试" else "请求太频繁，请稍后再试"
            }
            Code.CONTENT_UNAVAILABLE -> "内容已下架或无权访问"
            Code.ANONYMOUS_LIMITED -> "暂时没有获取到内容，请稍后再试"
            Code.PLAYBACK_QUOTA_EXHAUSTED -> "当前设备的播放次数已用完，已自动更换设备重试仍未成功，请稍后再试"
            Code.DEVICE_REJECTED -> "设备被服务端拒绝，请稍后重试"
            Code.DRM_PROTECTED -> "该集是加密内容，没有拿到可用的内容密钥"
            Code.NO_PLAYABLE_STREAM -> "该集没有可直接播放的视频流"
            Code.AUTHENTICATION_REQUIRED -> "该内容需要登录才能观看，本 App 不支持"
            Code.CHALLENGE_REQUIRED -> "服务端要求人机验证，请稍后再试"
            Code.ALBUM_UNAVAILABLE -> "没有找到其他季"
            Code.END_OF_LIST -> "没有更多内容了"
            Code.INVALID_LINK -> "无法识别的链接或 ID"
            Code.DECODING -> "数据格式异常，接口可能已改版"
            Code.PARAM_INVALID, Code.INVALID_OPTIONS -> "请求参数有误"
            Code.SIGNATURE_REJECTED, Code.SIGNER_UNAVAILABLE -> "请求签名失败，请稍后再试"
            Code.PROFILE_NOT_FOUND -> "设备信息缺失，请重试"
            Code.NOT_PROTECTED -> "内容密钥请求无效"
            Code.CANCELLED -> "已取消"
            Code.UNKNOWN -> "出了点问题，请稍后再试"
        }

    companion object {
        /** 把任意异常归一成 AppError；取消返回 null，调用方应当直接忽略（协程取消必须继续向上抛）。 */
        fun from(t: Throwable): AppError? {
            if (t is CancellationException) return null
            if (t is AppError) return if (t.code == Code.CANCELLED) null else t
            if (t is java.io.IOException) return AppError(Code.TRANSPORT, t.toString())
            return AppError(Code.UNKNOWN, t.toString())
        }
    }
}
