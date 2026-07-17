#ifndef FFmpegAudioCompat_h
#define FFmpegAudioCompat_h

#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/samplefmt.h>

typedef struct SwrContext SwrContext;

int swr_alloc_set_opts2(SwrContext **context,
                        const AVChannelLayout *outputChannelLayout,
                        enum AVSampleFormat outputSampleFormat,
                        int outputSampleRate,
                        const AVChannelLayout *inputChannelLayout,
                        enum AVSampleFormat inputSampleFormat,
                        int inputSampleRate,
                        int logOffset,
                        void *logContext);
int swr_init(SwrContext *context);
int64_t swr_get_delay(SwrContext *context, int64_t base);
int swr_convert(SwrContext *context,
                uint8_t * const *output,
                int outputSampleCount,
                const uint8_t * const *input,
                int inputSampleCount);
void swr_free(SwrContext **context);

#endif /* FFmpegAudioCompat_h */
