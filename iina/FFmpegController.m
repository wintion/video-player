//
//  FFmpegController.m
//  iina
//
//  Created by lhc on 9/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

#import "FFmpegController.h"
#import <Accelerate/Accelerate.h>
#import <Cocoa/Cocoa.h>
#include <errno.h>
#include <math.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libswscale/swscale.h>
#import <libavutil/imgutils.h>
#import <libavutil/mastering_display_metadata.h>
#import <libavutil/mathematics.h>
#pragma clang diagnostic pop

#import "FFmpegAudioCompat.h"
#import "IINA-Swift.h"

#define LOG_DEBUG(msg, ...) [FFmpegLogger debug:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];
#define LOG_ERROR(msg, ...) [FFmpegLogger error:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];
#define LOG_WARN(msg, ...) [FFmpegLogger warn:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];

#define THUMB_COUNT_DEFAULT 100
#define AI_SUBTITLE_SAMPLE_RATE 16000

static NSString * const FFmpegAudioErrorDomain = @"com.wintion.rawya.ffmpeg-audio";

typedef NS_ENUM(NSInteger, FFmpegAudioErrorCode) {
  FFmpegAudioErrorInvalidRange = 1,
  FFmpegAudioErrorOpenInput,
  FFmpegAudioErrorStreamInfo,
  FFmpegAudioErrorAudioStream,
  FFmpegAudioErrorDecoder,
  FFmpegAudioErrorSeek,
  FFmpegAudioErrorOutput,
  FFmpegAudioErrorConversion,
  FFmpegAudioErrorNoSamples,
  FFmpegAudioErrorCanceled
};

static int FFmpegAudioInterruptCallback(void *opaque)
{
  if (!opaque) return 0;
  BOOL (^shouldCancel)(void) = (__bridge BOOL (^)(void))opaque;
  return shouldCancel() ? 1 : 0;
}

static void FFmpegSetAudioError(NSError **error, FFmpegAudioErrorCode code, NSString *message)
{
  if (error) {
    *error = [NSError errorWithDomain:FFmpegAudioErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message}];
  }
}

static void FFmpegWriteLE16(FILE *file, uint16_t value)
{
  uint8_t bytes[] = {(uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff)};
  fwrite(bytes, sizeof(bytes), 1, file);
}

static void FFmpegWriteLE32(FILE *file, uint32_t value)
{
  uint8_t bytes[] = {
    (uint8_t)(value & 0xff),
    (uint8_t)((value >> 8) & 0xff),
    (uint8_t)((value >> 16) & 0xff),
    (uint8_t)((value >> 24) & 0xff)
  };
  fwrite(bytes, sizeof(bytes), 1, file);
}

static BOOL FFmpegWriteWAVHeader(FILE *file, uint32_t dataSize)
{
  if (fseek(file, 0, SEEK_SET) != 0) return NO;
  fwrite("RIFF", 4, 1, file);
  FFmpegWriteLE32(file, 36 + dataSize);
  fwrite("WAVEfmt ", 8, 1, file);
  FFmpegWriteLE32(file, 16);
  FFmpegWriteLE16(file, 1);
  FFmpegWriteLE16(file, 1);
  FFmpegWriteLE32(file, AI_SUBTITLE_SAMPLE_RATE);
  FFmpegWriteLE32(file, AI_SUBTITLE_SAMPLE_RATE * 2);
  FFmpegWriteLE16(file, 2);
  FFmpegWriteLE16(file, 16);
  fwrite("data", 4, 1, file);
  FFmpegWriteLE32(file, dataSize);
  return ferror(file) == 0;
}

typedef struct {
  SwrContext *resampler;
  FILE *output;
  double requestedStart;
  double requestedEnd;
  double timestampOrigin;
  double timestampCursor;
  uint64_t bytesWritten;
} FFmpegAudioExtractionContext;

/// Returns 1 when the requested end time has been reached, 0 to continue, or a negative FFmpeg error.
static int FFmpegWriteAudioFrame(AVFrame *frame,
                                AVStream *stream,
                                FFmpegAudioExtractionContext *context)
{
  double frameStart = context->timestampCursor;
  if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
    frameStart = frame->best_effort_timestamp * av_q2d(stream->time_base) - context->timestampOrigin;
  }
  const int inputSampleRate = frame->sample_rate > 0 ? frame->sample_rate : stream->codecpar->sample_rate;
  if (inputSampleRate <= 0) return AVERROR(EINVAL);
  const double frameEnd = frameStart + (double)frame->nb_samples / inputSampleRate;
  context->timestampCursor = frameEnd;
  if (frameEnd <= context->requestedStart) return 0;
  if (frameStart >= context->requestedEnd) return 1;

  const int maximumOutputSamples = (int)av_rescale_rnd(
    swr_get_delay(context->resampler, inputSampleRate) + frame->nb_samples,
    AI_SUBTITLE_SAMPLE_RATE,
    inputSampleRate,
    AV_ROUND_UP);
  uint8_t *outputData = NULL;
  int lineSize = 0;
  int result = av_samples_alloc(&outputData, &lineSize, 1, maximumOutputSamples, AV_SAMPLE_FMT_S16, 0);
  if (result < 0) return result;

  const uint8_t **inputData = (const uint8_t **)frame->extended_data;
  const int convertedSamples = swr_convert(context->resampler,
                                           &outputData,
                                           maximumOutputSamples,
                                           inputData,
                                           frame->nb_samples);
  if (convertedSamples < 0) {
    av_freep(&outputData);
    return convertedSamples;
  }

  int firstSample = 0;
  if (frameStart < context->requestedStart) {
    firstSample = (int)ceil((context->requestedStart - frameStart) * AI_SUBTITLE_SAMPLE_RATE);
  }
  int lastSample = convertedSamples;
  if (frameEnd > context->requestedEnd) {
    lastSample = (int)floor((context->requestedEnd - frameStart) * AI_SUBTITLE_SAMPLE_RATE);
  }
  firstSample = MAX(0, MIN(firstSample, convertedSamples));
  lastSample = MAX(firstSample, MIN(lastSample, convertedSamples));
  const int samplesToWrite = lastSample - firstSample;
  if (samplesToWrite > 0) {
    const size_t written = fwrite(outputData + firstSample * 2, 2, samplesToWrite, context->output);
    context->bytesWritten += written * 2;
    if (written != (size_t)samplesToWrite) result = AVERROR(EIO);
  }
  av_freep(&outputData);
  if (result < 0) return result;
  return frameEnd >= context->requestedEnd ? 1 : 0;
}

static int FFmpegDrainAudioDecoder(AVCodecContext *codecContext,
                                   AVFrame *frame,
                                   AVStream *stream,
                                   FFmpegAudioExtractionContext *context,
                                   BOOL *reachedEnd)
{
  int result;
  while ((result = avcodec_receive_frame(codecContext, frame)) >= 0) {
    const int writeResult = FFmpegWriteAudioFrame(frame, stream, context);
    av_frame_unref(frame);
    if (writeResult < 0) return writeResult;
    if (writeResult > 0) {
      *reachedEnd = YES;
      return 0;
    }
  }
  return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

#define CHECK_NOTNULL(ptr,msg) if (ptr == NULL) {\
LOG_ERROR(@"Error when getting thumbnails: %@", msg);\
return -1;\
}

#define CHECK_SUCCESS(ret,msg) if (ret < 0) {\
LOG_ERROR(@"Error when getting thumbnails: %@ (%d)", msg, ret);\
return -1;\
}

#define CHECK(ret,msg) if (!(ret)) {\
LOG_ERROR(@"Error when getting thumbnails: %@", msg);\
return -1;\
}

@implementation FFThumbnail

@end


@interface FFmpegController () {
  NSMutableArray<FFThumbnail *> *_thumbnails;
  NSMutableArray<FFThumbnail *> *_thumbnailPartialResult;
  NSMutableSet *_addedTimestamps;
  NSOperationQueue *_queue;
  double _timestamp;
}

- (int)getPeeksForFile:(NSString *)file thumbnailsWidth:(int)thumbnailsWidth;
- (void)saveThumbnail:(AVFrame *)pFrame width:(int)width height:(int)height index:(int)index realTime:(int)second forFile:(NSString *)file;

@end


@implementation FFmpegController

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.thumbnailCount = THUMB_COUNT_DEFAULT;
    _thumbnails = [[NSMutableArray alloc] init];
    _thumbnailPartialResult = [[NSMutableArray alloc] init];
    _addedTimestamps = [[NSMutableSet alloc] init];
    _queue = [[NSOperationQueue alloc] init];
    _queue.maxConcurrentOperationCount = 1;
  }
  return self;
}

// MARK: - Generating Thumbnails

- (void)generateThumbnailForFile:(NSString *)file
                      thumbWidth:(int)thumbWidth
{
  [_queue cancelAllOperations];
  NSBlockOperation *op = [[NSBlockOperation alloc] init];
  __weak NSBlockOperation *weakOp = op;
  [op addExecutionBlock:^(){
    if ([weakOp isCancelled]) {
      return;
    }
    self->_timestamp = CACurrentMediaTime();
    int success = [self getPeeksForFile:file thumbnailsWidth:thumbWidth];
    if (self.delegate) {
      [self.delegate didGenerateThumbnails:[NSArray arrayWithArray:self->_thumbnails]
                                   forFile: file
                                 succeeded:(success < 0 ? NO : YES)];
    }
  }];
  [_queue addOperation:op];
}

- (int)getPeeksForFile:(NSString *)file
       thumbnailsWidth:(int)thumbnailsWidth
{
  int i, ret;

  char *cFilename = strdup(file.fileSystemRepresentation);
  [_thumbnails removeAllObjects];
  [_thumbnailPartialResult removeAllObjects];
  [_addedTimestamps removeAllObjects];

  // Register all formats and codecs. mpv should have already called it.
  // av_register_all();

  // Open video file
  AVFormatContext *pFormatCtx = NULL;
  ret = avformat_open_input(&pFormatCtx, cFilename, NULL, NULL);
  free(cFilename);
  CHECK_SUCCESS(ret, @"Cannot open video")

  // Find stream information
  ret = avformat_find_stream_info(pFormatCtx, NULL);
  CHECK_SUCCESS(ret, @"Cannot get stream info")

  // Find the first video stream
  int videoStream = -1;
  for (i = 0; i < pFormatCtx->nb_streams; i++)
    if (pFormatCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      videoStream = i;
      break;
    }
  CHECK_SUCCESS(videoStream, @"No video stream")

  // Get the codec context for the video stream
  AVStream *pVideoStream = pFormatCtx->streams[videoStream];

  AVRational videoAvgFrameRate = pVideoStream->avg_frame_rate;

  // Check whether the denominator (AVRational.den) is zero to prevent division-by-zero
  if (videoAvgFrameRate.den == 0 || av_q2d(videoAvgFrameRate) == 0) {
    LOG_DEBUG(@"Avg frame rate = 0, ignore");
    return -1;
  }

  // Find the decoder for the video stream
  const AVCodec *pCodec = avcodec_find_decoder(pVideoStream->codecpar->codec_id);
  CHECK_NOTNULL(pCodec, @"Unsupported codec")

  // Open codec
  AVCodecContext *pCodecCtx = avcodec_alloc_context3(pCodec);
  AVDictionary *optionsDict = NULL;

  avcodec_parameters_to_context(pCodecCtx, pVideoStream->codecpar);
  pCodecCtx->time_base = pVideoStream->time_base;

  if (pCodecCtx->pix_fmt < 0 || pCodecCtx->pix_fmt >= AV_PIX_FMT_NB) {
    avcodec_free_context(&pCodecCtx);
    avformat_close_input(&pFormatCtx);
    LOG_ERROR(@"Error when getting thumbnails: Pixel format is null");
    return -1;
  }

  ret = avcodec_open2(pCodecCtx, pCodec, &optionsDict);
  CHECK_SUCCESS(ret, @"Cannot open codec")

  // Allocate video frame
  AVFrame *pFrame = av_frame_alloc();
  CHECK_NOTNULL(pFrame, @"Cannot alloc video frame")

  // Allocate the output frame
  // We need to convert the video frame to RGBA to satisfy CGImage's data format
  int thumbWidth = thumbnailsWidth;
  int thumbHeight = (float)thumbWidth / ((float)pCodecCtx->width / pCodecCtx->height);

  AVFrame *pFrameRGB = av_frame_alloc();
  CHECK_NOTNULL(pFrameRGB, @"Cannot alloc RGBA frame")

  pFrameRGB->width = thumbWidth;
  pFrameRGB->height = thumbHeight;
  pFrameRGB->format = AV_PIX_FMT_RGBA;

  // Determine required buffer size and allocate buffer
  int size = av_image_get_buffer_size(pFrameRGB->format, thumbWidth, thumbHeight, 1);
  uint8_t *pFrameRGBBuffer = (uint8_t *)av_malloc(size);

  // Assign appropriate parts of buffer to image planes in pFrameRGB
  ret = av_image_fill_arrays(pFrameRGB->data,
                             pFrameRGB->linesize,
                             pFrameRGBBuffer,
                             pFrameRGB->format,
                             pFrameRGB->width,
                             pFrameRGB->height, 1);
  CHECK_SUCCESS(ret, @"Cannot fill data for RGBA frame")

  // Create a sws context for converting color space and resizing
  CHECK(pCodecCtx->pix_fmt != AV_PIX_FMT_NONE, @"Pixel format is none")
  struct SwsContext *sws_ctx = sws_getContext(pCodecCtx->width, pCodecCtx->height, pCodecCtx->pix_fmt,
                                              pFrameRGB->width, pFrameRGB->height, pFrameRGB->format,
                                              SWS_BILINEAR,
                                              NULL, NULL, NULL);

  // Get duration and interval
  int64_t duration = av_rescale_q(pFormatCtx->duration, AV_TIME_BASE_Q, pVideoStream->time_base);
  double interval = duration / (double)self.thumbnailCount;
  double timebaseDouble = av_q2d(pVideoStream->time_base);
  AVPacket packet;

  // For each preview point
  for (i = 0; i <= self.thumbnailCount; i++) {
    int64_t seek_pos = interval * i + pVideoStream->start_time;

    avcodec_flush_buffers(pCodecCtx);

    // Seek to time point
    // avformat_seek_file(pFormatCtx, videoStream, seek_pos-interval, seek_pos, seek_pos+interval, 0);
    ret = av_seek_frame(pFormatCtx, videoStream, seek_pos, AVSEEK_FLAG_BACKWARD);
    CHECK_SUCCESS(ret, @"Cannot seek")

    avcodec_flush_buffers(pCodecCtx);

    // Read and decode frame
    while(av_read_frame(pFormatCtx, &packet) >= 0) {
      @try {
        // Make sure it's video stream
        if (packet.stream_index == videoStream) {

          // Decode video frame
          if (avcodec_send_packet(pCodecCtx, &packet) < 0)
            break;

          ret = avcodec_receive_frame(pCodecCtx, pFrame);
          if (ret < 0) {  // something happened
            if (ret == AVERROR(EAGAIN))  // input not ready, retry
              continue;
            else
              break;
          }

          // Check if duplicated
          NSNumber *currentTimeStamp = @(pFrame->best_effort_timestamp);
          if ([_addedTimestamps containsObject:currentTimeStamp]) {
            double currentTime = CACurrentMediaTime();
            if (currentTime - _timestamp > 1) {
              if (self.delegate) {
                [self.delegate didUpdateThumbnails:NULL forFile: file withProgress: i];
                _timestamp = currentTime;
              }
            }
            break;
          } else {
            [_addedTimestamps addObject:currentTimeStamp];
          }

          // Convert the frame to RGBA
          ret = sws_scale(sws_ctx,
                          (const uint8_t* const *)pFrame->data,
                          pFrame->linesize,
                          0,
                          pCodecCtx->height,
                          pFrameRGB->data,
                          pFrameRGB->linesize);
          CHECK_SUCCESS(ret, @"Cannot convert frame")

          // Save the frame to disk
          [self saveThumbnail:pFrameRGB
                        width:pFrameRGB->width
                       height:pFrameRGB->height
                        index:i
                     realTime:(pFrame->best_effort_timestamp * timebaseDouble)
                      forFile:file];
          break;
        }
      } @finally {
        // Free the packet
        av_packet_unref(&packet);
      }
    }
  }
  // Free the scaler
  sws_freeContext(sws_ctx);

  // Free the RGB image
  av_free(pFrameRGBBuffer);
  av_frame_free(&pFrameRGB);
  // Free the YUV frame
  av_frame_free(&pFrame);

  // Free the codec
  avcodec_free_context(&pCodecCtx);
  // Close the video file
  avformat_close_input(&pFormatCtx);

  // LOG_DEBUG(@"Thumbnails generated.");
  return 0;
}


- (void)saveThumbnail:(AVFrame *)pFrame width
                     :(int)width height
                     :(int)height index
                     :(int)index realTime
                     :(int)second forFile
                     :(NSString *)file
{
  // Create CGImage
  CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();

  CGContextRef cgContext = CGBitmapContextCreate(pFrame->data[0],  // it's converted to RGBA so could be used directly
                                                 width, height,
                                                 8,  // 8 bit per component
                                                 width * 4,  // 4 bytes(rgba) per pixel
                                                 rgb,
                                                 kCGImageAlphaPremultipliedLast);
  CGImageRef cgImage = CGBitmapContextCreateImage(cgContext);

  // Create NSImage
  NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size: NSZeroSize];

  // Free resources
  CFRelease(rgb);
  CFRelease(cgContext);
  CFRelease(cgImage);

  // Add to list
  FFThumbnail *tb = [[FFThumbnail alloc] init];
  tb.image = image;
  tb.realTime = second;
  [_thumbnails addObject:tb];
  [_thumbnailPartialResult addObject:tb];
  // Post update notification
  double currentTime = CACurrentMediaTime();
  if (currentTime - _timestamp >= 0.2) {  // min notification interval: 0.2s
    if (_thumbnailPartialResult.count >= 10 || (currentTime - _timestamp >= 1 && _thumbnailPartialResult.count > 0)) {
      if (self.delegate) {
        [self.delegate didUpdateThumbnails:[NSArray arrayWithArray:_thumbnailPartialResult]
                                   forFile: file
                              withProgress: index];
      }
      [_thumbnailPartialResult removeAllObjects];
      _timestamp = currentTime;
    }
  }
}

// MARK: - Probing Video

+ (NSDictionary *)probeVideoInfoForFile:(nonnull NSString *)file
{
  int ret;
  int64_t duration;

  char *cFilename = strdup(file.fileSystemRepresentation);

  AVFormatContext *pFormatCtx = NULL;
  ret = avformat_open_input(&pFormatCtx, cFilename, NULL, NULL);
  free(cFilename);
  if (ret < 0) {
    LOG_ERROR(@"Error when opening file %@ to obtain info: %s (%d)", file, av_err2str(ret), ret);
    return NULL;
  }

  duration = pFormatCtx->duration;
  if (duration <= 0) {
    ret = avformat_find_stream_info(pFormatCtx, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Error when probing %@ to obtain info: %s (%d)", file, av_err2str(ret), ret);
      duration = -1;
    } else
      duration = pFormatCtx->duration;
  }

  // In addition to the duration IINA is interested metadata tags, especially the title tag. In many
  // formats metadata is attached to the container itself. However in Ogg files metadata is attached
  // to the stream. If the title tag is not found in the metadata from the container then search for
  // an audio stream. If an audio stream with metadata containing a title tag is found then use the
  // metadata from the stream instead of from the container. This addresses issue #5314.
  AVDictionary *metadata = pFormatCtx->metadata;
  if (av_dict_get(metadata, "title", NULL, 0) == NULL) {
    ret = av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (ret < 0) {
      // Don't report an error when there isn't an audio stream.
      if (ret != AVERROR_STREAM_NOT_FOUND) {
        LOG_ERROR(@"Error when probing %@ to obtain best stream: %s (%d)", file, av_err2str(ret), ret);
      }
    } else if (av_dict_get(pFormatCtx->streams[ret]->metadata, "title", NULL, 0) != NULL) {
      metadata = pFormatCtx->streams[ret]->metadata;
    }
  }

  NSMutableDictionary *info = [[NSMutableDictionary alloc] init];
  info[@"@iina_duration"] = duration == -1 ? [NSNumber numberWithInt:-1] : [NSNumber numberWithDouble:(double)duration / AV_TIME_BASE];
  AVDictionaryEntry *tag = NULL;
  while ((tag = av_dict_get(metadata, "", tag, AV_DICT_IGNORE_SUFFIX))) {
    // FFmpeg may return strings that are not valid. See issue #5602.
    const NSString *key = [NSString stringWithCString:tag->key encoding:NSUTF8StringEncoding];
    if (!key) {
      LOG_WARN(@"Cannot construct a string for a metadata tag key");
      continue;
    }
    const NSString *value = [NSString stringWithCString:tag->value encoding:NSUTF8StringEncoding];
    if (!value) {
      LOG_WARN(@"Cannot construct a string for the value of the metadata tag key: %@", key);
      continue;
    }
    info[key] = value;
  }

  avformat_close_input(&pFormatCtx);
  avformat_free_context(pFormatCtx);

  return info;
}

// MARK: - Extracting Audio

+ (BOOL)extractAudioFromURL:(NSURL *)sourceURL
                streamIndex:(NSInteger)streamIndex
                  startTime:(NSTimeInterval)startTime
                   duration:(NSTimeInterval)duration
                  outputURL:(NSURL *)outputURL
                      error:(NSError **)error
{
  return [self extractAudioFromURL:sourceURL
                       streamIndex:streamIndex
                         startTime:startTime
                          duration:duration
                         outputURL:outputURL
                      shouldCancel:nil
                             error:error];
}

+ (BOOL)extractAudioFromURL:(NSURL *)sourceURL
                streamIndex:(NSInteger)streamIndex
                  startTime:(NSTimeInterval)startTime
                   duration:(NSTimeInterval)duration
                  outputURL:(NSURL *)outputURL
               shouldCancel:(BOOL (^)(void))shouldCancel
                      error:(NSError **)error
{
  if (startTime < 0 || duration <= 0 || !isfinite(startTime) || !isfinite(duration)) {
    FFmpegSetAudioError(error, FFmpegAudioErrorInvalidRange, @"The requested audio range is invalid.");
    return NO;
  }

  AVFormatContext *formatContext = NULL;
  AVCodecContext *codecContext = NULL;
  const AVCodec *codec = NULL;
  AVPacket *packet = NULL;
  AVFrame *frame = NULL;
  SwrContext *resampler = NULL;
  FILE *output = NULL;
  BOOL succeeded = NO;
  int selectedStreamIndex = -1;
  int result = 0;
  NSString *failureMessage = nil;
  FFmpegAudioErrorCode failureCode = FFmpegAudioErrorConversion;
  const char *input = sourceURL.isFileURL ? sourceURL.fileSystemRepresentation : sourceURL.absoluteString.UTF8String;
  BOOL (^cancellationHandler)(void) = [shouldCancel copy];

  if (cancellationHandler) {
    formatContext = avformat_alloc_context();
    if (!formatContext) {
      failureCode = FFmpegAudioErrorOpenInput;
      failureMessage = @"Cannot allocate media input for audio extraction.";
      goto cleanup;
    }
    formatContext->interrupt_callback.callback = FFmpegAudioInterruptCallback;
    formatContext->interrupt_callback.opaque = (__bridge void *)cancellationHandler;
  }

  result = avformat_open_input(&formatContext, input, NULL, NULL);
  if (result < 0) {
    const BOOL wasCanceled = cancellationHandler && cancellationHandler();
    failureCode = wasCanceled ? FFmpegAudioErrorCanceled : FFmpegAudioErrorOpenInput;
    failureMessage = wasCanceled
      ? @"Audio extraction was canceled."
      : [NSString stringWithFormat:@"Cannot open media for audio extraction: %s", av_err2str(result)];
    goto cleanup;
  }
  result = avformat_find_stream_info(formatContext, NULL);
  if (result < 0) {
    failureCode = FFmpegAudioErrorStreamInfo;
    failureMessage = [NSString stringWithFormat:@"Cannot read media stream information: %s", av_err2str(result)];
    goto cleanup;
  }

  if (streamIndex >= 0) {
    if (streamIndex >= formatContext->nb_streams ||
        formatContext->streams[streamIndex]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
      failureCode = FFmpegAudioErrorAudioStream;
      failureMessage = [NSString stringWithFormat:@"Audio stream index %ld is unavailable.", (long)streamIndex];
      goto cleanup;
    }
    selectedStreamIndex = (int)streamIndex;
  } else {
    selectedStreamIndex = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (selectedStreamIndex < 0) {
      failureCode = FFmpegAudioErrorAudioStream;
      failureMessage = @"The media does not contain a decodable audio stream.";
      goto cleanup;
    }
  }

  AVStream *audioStream = formatContext->streams[selectedStreamIndex];
  codec = avcodec_find_decoder(audioStream->codecpar->codec_id);
  if (!codec) {
    failureCode = FFmpegAudioErrorDecoder;
    failureMessage = @"No decoder is available for the selected audio stream.";
    goto cleanup;
  }
  codecContext = avcodec_alloc_context3(codec);
  if (!codecContext) {
    failureCode = FFmpegAudioErrorDecoder;
    failureMessage = @"Cannot allocate the audio decoder.";
    goto cleanup;
  }
  result = avcodec_parameters_to_context(codecContext, audioStream->codecpar);
  if (result < 0 || avcodec_open2(codecContext, codec, NULL) < 0) {
    failureCode = FFmpegAudioErrorDecoder;
    failureMessage = @"Cannot initialize the audio decoder.";
    goto cleanup;
  }
  if (codecContext->sample_rate <= 0) {
    failureCode = FFmpegAudioErrorDecoder;
    failureMessage = @"The selected audio stream has an invalid sample rate.";
    goto cleanup;
  }
  if (codecContext->ch_layout.nb_channels == 0) {
    av_channel_layout_default(&codecContext->ch_layout, MAX(codecContext->ch_layout.nb_channels, 1));
  }

  AVChannelLayout monoLayout = AV_CHANNEL_LAYOUT_MONO;
  result = swr_alloc_set_opts2(&resampler,
                               &monoLayout,
                               AV_SAMPLE_FMT_S16,
                               AI_SUBTITLE_SAMPLE_RATE,
                               &codecContext->ch_layout,
                               codecContext->sample_fmt,
                               codecContext->sample_rate,
                               0,
                               NULL);
  if (result < 0 || !resampler || swr_init(resampler) < 0) {
    failureCode = FFmpegAudioErrorConversion;
    failureMessage = @"Cannot initialize conversion to 16 kHz mono PCM.";
    goto cleanup;
  }

  double timestampOrigin = 0;
  if (audioStream->start_time != AV_NOPTS_VALUE) {
    timestampOrigin = audioStream->start_time * av_q2d(audioStream->time_base);
  } else if (formatContext->start_time != AV_NOPTS_VALUE) {
    timestampOrigin = (double)formatContext->start_time / AV_TIME_BASE;
  }
  const int64_t seekTimestamp = av_rescale_q((int64_t)llround((startTime + timestampOrigin) * AV_TIME_BASE),
                                             AV_TIME_BASE_Q,
                                             audioStream->time_base);
  result = avformat_seek_file(formatContext,
                              selectedStreamIndex,
                              INT64_MIN,
                              seekTimestamp,
                              seekTimestamp,
                              AVSEEK_FLAG_BACKWARD);
  if (result < 0) {
    failureCode = FFmpegAudioErrorSeek;
    failureMessage = [NSString stringWithFormat:@"Cannot seek to the requested audio range: %s", av_err2str(result)];
    goto cleanup;
  }
  avcodec_flush_buffers(codecContext);

  output = fopen(outputURL.fileSystemRepresentation, "wb+");
  if (!output || !FFmpegWriteWAVHeader(output, 0)) {
    failureCode = FFmpegAudioErrorOutput;
    failureMessage = @"Cannot create the extracted WAV file.";
    goto cleanup;
  }

  packet = av_packet_alloc();
  frame = av_frame_alloc();
  if (!packet || !frame) {
    failureCode = FFmpegAudioErrorDecoder;
    failureMessage = @"Cannot allocate audio decoding buffers.";
    goto cleanup;
  }

  FFmpegAudioExtractionContext extraction = {
    .resampler = resampler,
    .output = output,
    .requestedStart = startTime,
    .requestedEnd = startTime + duration,
    .timestampOrigin = timestampOrigin,
    .timestampCursor = startTime,
    .bytesWritten = 0
  };
  BOOL reachedEnd = NO;
  while (!reachedEnd && av_read_frame(formatContext, packet) >= 0) {
    if (packet->stream_index == selectedStreamIndex) {
      while ((result = avcodec_send_packet(codecContext, packet)) == AVERROR(EAGAIN)) {
        result = FFmpegDrainAudioDecoder(codecContext, frame, audioStream, &extraction, &reachedEnd);
        if (result < 0 || reachedEnd) break;
      }
      if (result < 0 || reachedEnd) {
        av_packet_unref(packet);
        if (result < 0) {
          failureMessage = [NSString stringWithFormat:@"Audio decoding failed: %s", av_err2str(result)];
          goto cleanup;
        }
        break;
      }
      result = FFmpegDrainAudioDecoder(codecContext, frame, audioStream, &extraction, &reachedEnd);
      if (result < 0) {
        failureMessage = [NSString stringWithFormat:@"Audio decoding failed: %s", av_err2str(result)];
        goto cleanup;
      }
    }
    av_packet_unref(packet);
  }

  if (cancellationHandler && cancellationHandler()) {
    failureCode = FFmpegAudioErrorCanceled;
    failureMessage = @"Audio extraction was canceled.";
    goto cleanup;
  }

  if (!reachedEnd) {
    result = avcodec_send_packet(codecContext, NULL);
    if (result >= 0 || result == AVERROR_EOF) {
      result = FFmpegDrainAudioDecoder(codecContext, frame, audioStream, &extraction, &reachedEnd);
    }
    if (result < 0 && result != AVERROR_EOF) {
      failureMessage = [NSString stringWithFormat:@"Audio decoder flush failed: %s", av_err2str(result)];
      goto cleanup;
    }
  }

  if (extraction.bytesWritten == 0) {
    failureCode = FFmpegAudioErrorNoSamples;
    failureMessage = @"The requested range did not contain audio samples.";
    goto cleanup;
  }
  if (extraction.bytesWritten > UINT32_MAX || !FFmpegWriteWAVHeader(output, (uint32_t)extraction.bytesWritten)) {
    failureCode = FFmpegAudioErrorOutput;
    failureMessage = @"Cannot finalize the extracted WAV file.";
    goto cleanup;
  }
  succeeded = YES;

cleanup:
  if (output) fclose(output);
  av_frame_free(&frame);
  av_packet_free(&packet);
  swr_free(&resampler);
  avcodec_free_context(&codecContext);
  avformat_close_input(&formatContext);
  if (!succeeded) {
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    FFmpegSetAudioError(error, failureCode, failureMessage ?: @"Audio extraction failed.");
  }
  return succeeded;
}

// MARK: - Decoding Image

+ (NSImage *)createNSImageWithContentsOfURL:(nonnull NSURL *)url
{
  // Variables holding objects that will need to be freed.
  AVFormatContext *pFormatCtx = NULL;
  AVCodecContext *pCodecCtx = NULL;
  AVPacket *packet = NULL;
  AVFrame *pFrame = NULL;
  AVFrame *pFrameRGB = NULL;
  uint8_t *pFrameRGBBuffer = NULL;
  struct SwsContext *swsContext = NULL;
  CGColorSpaceRef cgColorSpace = NULL;
  CGContextRef cgContext = NULL;
  CGImageRef cgImage = NULL;

  @try {
#if DEBUG
    LOG_DEBUG(@"Creating image with contents of file: %s", url.fileSystemRepresentation)
#endif

    int ret = avformat_open_input(&pFormatCtx, url.fileSystemRepresentation, NULL, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Error when opening file %@ to construct NSImage: %s (%d)", url, av_err2str(ret), ret);
      return NULL;
    }

    ret = avformat_find_stream_info(pFormatCtx, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Cannot get stream info: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }

    // Expecting image files to have one video stream.
    if (pFormatCtx->nb_streams != 1) {
      LOG_ERROR(@"Expected one stream found: %d", pFormatCtx->nb_streams);
      return NULL;
    }
    const AVStream *pVideoStream = pFormatCtx->streams[0];
    const enum AVMediaType codecType = pVideoStream->codecpar->codec_type;
    if (codecType != AVMEDIA_TYPE_VIDEO) {
      LOG_ERROR(@"Unexpected stream type: %s (%d)", av_get_media_type_string(codecType), codecType);
      return NULL;
    }
    // Expecting the number of frames to be unknown (0) or 1.
    if (pVideoStream->nb_frames > 1) {
      LOG_ERROR(@"Expected one frame found: %lld", pVideoStream->nb_frames);
      return NULL;
    }

    const AVCodec *pCodec = avcodec_find_decoder(pVideoStream->codecpar->codec_id);
    if (!pCodec) {
      LOG_ERROR(@"Cannot get decoder codec: %d", pVideoStream->codecpar->codec_id);
      return NULL;
    }

    // This method is only intended to be used for JPEG XL or WebP encoded images. As only these
    // formats have been tested, refuse to process other formats.
    if (pCodec->id != AV_CODEC_ID_JPEGXL && pCodec->id != AV_CODEC_ID_WEBP) {
      LOG_ERROR(@"Unexpected encoding: %s (%d)", pCodec->name, pCodec->id);
      return NULL;
    }

    pCodecCtx = avcodec_alloc_context3(pCodec);
    if (!pCodecCtx) {
      LOG_ERROR(@"Cannot alloc codec context: %s (%d)", pCodec->name, pCodec->id);
      return NULL;
    }
    avcodec_parameters_to_context(pCodecCtx, pVideoStream->codecpar);
    if (pCodecCtx->pix_fmt < 0 || pCodecCtx->pix_fmt >= AV_PIX_FMT_NB) {
      LOG_ERROR(@"Invalid pixel format: %d", pCodecCtx->pix_fmt);
      return NULL;
    }

    // Permit use of multiple threads for decoding. By default thread count is set to one which
    // disables use of multiple threads. Setting it to zero allows the codec to use multiple
    // threads. This is only done if the codec has the capability of using multiple threads for
    // decoding an individual frame as testing showed the WebP codec, which does not have this
    // capability, reacted badly to being given permission to use multiple threads. When this
    // property was set to anything other than one WebP decoding failed with "Resource temporarily
    // unavailable". The JPEG XL codec has this capability and will take advantage of multiple
    // threads. Testing on a MacBook Pro with the M1 Max chip showed a 40% reduction in the time to
    // decode a JPEG XL screenshot of a 4K video when using multiple threads. Normally speed of
    // decoding is not an issue, however mpv provides screenshot options that control the encoding
    // compression and quality. Changing these settings can result in the creation of screenshots
    // that take multiple seconds to decode. The thread count must be set before opening the codec.
    if (pCodec->capabilities & AV_CODEC_CAP_OTHER_THREADS) {
      pCodecCtx->thread_count = 0;
    }

    ret = avcodec_open2(pCodecCtx, pCodec, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Cannot open codec: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }

    packet = av_packet_alloc();
    ret = av_read_frame(pFormatCtx, packet);
    if (ret < 0) {
      LOG_ERROR(@"Cannot read packet: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }
    if (packet->stream_index != 0) {
      LOG_ERROR(@"Unexpected video stream: %d", packet->stream_index);
      return NULL;
    }

    pFrame = av_frame_alloc();
    if (!pFrame) {
      LOG_ERROR(@"Cannot alloc frame");
      return NULL;
    }

    ret = avcodec_send_packet(pCodecCtx, packet);
    if (ret < 0) {
      LOG_ERROR(@"Cannot send packet: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }
    ret = avcodec_receive_frame(pCodecCtx, pFrame);
    if (ret < 0) {
      LOG_ERROR(@"Cannot receive frame: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }

#if DEBUG
    [FFmpegController logFrame:pCodec:pFrame];
#endif

    // CGImage requires the image frame to be converted to RGBA.
    pFrameRGB = av_frame_alloc();
    if (!pFrameRGB) {
      LOG_ERROR(@"Cannot alloc RGBA frame");
      return NULL;
    }
    pFrameRGB->width = pFrame->width;
    pFrameRGB->height = pFrame->height;

    // Determine the appropriate RGBA pixel format to convert to.
    CGBitmapInfo bitmapInfo;
    switch (pFrame->format) {
      default:
        // If this message is logged then the situation needs to be investigated to determine the
        // correct conversion. Fall through and treat this as a SDR image.
        LOG_WARN(@"Unexpected pixel format: %s (%d)", av_get_pix_fmt_name(pFrame->format),
             pFrame->format);
      case AV_PIX_FMT_ARGB: // WebP with screenshot-webp-lossless mpv option enabled.
      case AV_PIX_FMT_RGB24: // JPEG XL SDR video.
      case AV_PIX_FMT_RGBA64LE: // JPEG XL SDR video.
      case AV_PIX_FMT_YUV420P: // WebP default.
        pFrameRGB->format = AV_PIX_FMT_RGBA;
        bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
        break;
      case AV_PIX_FMT_RGB48LE: // JPEG XL HDR video.
        // Workaround missing FFmpeg 6.0 scalar capabilities. As per Apple EDR requires using 16 bit
        // floating point components in the image bit map. Therefore we want the scalar to convert
        // the frame to the AV_PIX_FMT_RGBAF16LE pixel format. However when that was specified the
        // call to sws_getContext returned NULL. The scalar printed the message "rgbaf16le is not
        // supported as output pixel format" to the console. As a workaround we convert to
        // AV_PIX_FMT_RGBA64LE and then convert the components to floating point.
        pFrameRGB->format = AV_PIX_FMT_RGBA64LE;
        bitmapInfo = kCGImageByteOrder16Little | kCGImageAlphaPremultipliedLast |
            kCGBitmapFloatComponents;
    }

    // Determine required buffer size and allocate the buffer.
    const int size = av_image_get_buffer_size(pFrameRGB->format, pFrame->width, pFrame->height, 1);
    pFrameRGBBuffer = (uint8_t *)av_malloc(size);
    if (!pFrameRGBBuffer) {
      LOG_ERROR(@"Cannot alloc RGBA buffer");
      return NULL;
    }

    // Assign appropriate parts of buffer to image planes in pFrameRGB.
    ret = av_image_fill_arrays(pFrameRGB->data, pFrameRGB->linesize, pFrameRGBBuffer,
        pFrameRGB->format, pFrameRGB->width, pFrameRGB->height, 1);
    if (ret < 0) {
      LOG_ERROR(@"Cannot fill data for RGBA frame: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }

    // Convert the image frame to RGBA using the FFmpeg scaler.
    swsContext = sws_getContext(pFrame->width, pFrame->height, pFrame->format,
        pFrameRGB->width, pFrameRGB->height, pFrameRGB->format, SWS_BILINEAR, NULL, NULL, NULL);
    if (!swsContext) {
      LOG_ERROR(@"Cannot alloc sws context");
      return NULL;
    }
    sws_scale(swsContext, (const uint8_t* const *)pFrame->data, pFrame->linesize, 0, pFrame->height,
        pFrameRGB->data, pFrameRGB->linesize);

    // Obtain information about the pixel format that is needed to create the bitmap image.
    const AVPixFmtDescriptor *pixFmtDesc = av_pix_fmt_desc_get(pFrameRGB->format);
    if (!pixFmtDesc){
      LOG_ERROR(@"Cannot get descriptor for pixel format: %s (%d)",
            av_get_pix_fmt_name(pFrameRGB->format), pFrameRGB->format);
      return NULL;
    }
    const int bitsPerPixel = av_get_bits_per_pixel(pixFmtDesc);
    const int bitsPerComponent = bitsPerPixel / pixFmtDesc->nb_components;
    const int bytesPerPixel = bitsPerPixel / 8;

    if (pFrameRGB->format == AV_PIX_FMT_RGBA64LE) {
      const int bytesPerComponent = bitsPerComponent / 8;

      // Each row of pixels in memory may contain extra padding for performance reasons. The
      // linesize gives the actual number of bytes each row consumes in the frame buffer.
      const int strideInBytes = pFrameRGB->linesize[0];

      // Apply the second part of the workaround for the FFmpeg scalar not supporting conversion to
      // the pixel format AV_PIX_FMT_RGBAF16LE. Convert the pixel components to short floating point
      // values. This is an in-place conversion, which is supported by vImageConvert_16Uto16F, so
      // only one buffer is used.
      const vImage_Buffer buffer = {.width = pFrameRGB->width * bytesPerPixel / bytesPerComponent,
        .height = pFrameRGB->height, .rowBytes = strideInBytes, .data = pFrameRGB->data[0]};
      const vImage_Error error = vImageConvert_16Uto16F(&buffer, &buffer, kvImageNoFlags);
      if (error != kvImageNoError) {
        LOG_ERROR(@"Method vImageConvert_16Uto16F failed: %ld", error);
        return NULL;
      }
    }

    // Determine the color space to use for the image.
    switch (pFrame->color_primaries) {
      default:
        // If this message is logged then the situation needs to be investigated to determine the
        // correct color space. Fall through and treat this as a SDR image.
        LOG_WARN(@"Unexpected color primaries: %s (%d)",
             av_color_primaries_name(pFrame->color_primaries), pFrame->color_primaries);
      case AVCOL_PRI_UNSPECIFIED:
      case AVCOL_PRI_BT709:
        cgColorSpace = CGColorSpaceCreateDeviceRGB();
        break;
      case AVCOL_PRI_BT2020:
        switch (pFrame->color_trc) {
          default:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
            break;
          case AVCOL_TRC_ARIB_STD_B67:
            if (@available(macOS 11.0, *)) {
              cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_HLG);
            } else if (@available(macOS 10.15.6, *)) {
              cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020_HLG);
            } else {
              cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
            }
            break;
          case AVCOL_TRC_SMPTE2084:
            if (@available(macOS 11.0, *)) {
              cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
            } else if (@available(macOS 10.15.4, *)) {
              cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020_PQ);
            } else {
              cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020_PQ_EOTF);
            }
        }
        break;
      case AVCOL_PRI_SMPTE432:
        switch (pFrame->color_trc) {
          default:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
            break;
          case AVCOL_TRC_ARIB_STD_B67:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3_HLG);
            break;
          case AVCOL_TRC_SMPTE2084:
            if (@available(macOS 10.15.4, *)) {
              cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3_PQ);
            } else {
              cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3_PQ_EOTF);
            }
        }
    }
    if (!cgColorSpace) {
      LOG_ERROR(@"Cannot create color space");
      return NULL;
    }

#if DEBUG
    LOG_DEBUG(@"Selected %s color space for bitmap image",
        CFStringGetCStringPtr(CGColorSpaceCopyName(cgColorSpace), CFStringGetSystemEncoding()));
    LOG_DEBUG(@"Creating bitmap image with %d bits per component and %d bytes per pixel",
        bitsPerComponent, bytesPerPixel);
#endif

    cgContext = CGBitmapContextCreate(pFrameRGB->data[0], pFrameRGB->width, pFrameRGB->height,
        bitsPerComponent, pFrameRGB->width * bytesPerPixel, cgColorSpace, bitmapInfo);
    if (!cgContext) {
      LOG_ERROR(@"Cannot create bitmap context");
      return NULL;
    }
    cgImage = CGBitmapContextCreateImage(cgContext);
    if (!cgImage) {
      LOG_ERROR(@"Cannot create bitmap image");
      return NULL;
    }

    NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size: NSZeroSize];
    if (!image) {
      LOG_ERROR(@"Cannot create image");
    }
    return image;
  }
  @finally {
    // All of these methods accept null, no need to check if the object was allocated.
    CGImageRelease(cgImage);
    CGContextRelease(cgContext);
    CGColorSpaceRelease(cgColorSpace);
    sws_freeContext(swsContext);
    av_freep(&pFrameRGBBuffer);
    av_frame_free(&pFrameRGB);
    av_frame_free(&pFrame);
    av_packet_free(&packet);
    avcodec_free_context(&pCodecCtx);
    avformat_close_input(&pFormatCtx);
  }
}

// MARK: - Media Artwork

+ (NSImage *)readArtworkFromURL:(nonnull NSURL *)url
{
  AVFormatContext *pFormatCtx = NULL;

  @try {
    int ret = avformat_open_input(&pFormatCtx, url.fileSystemRepresentation, NULL, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Failed to open file %@ when searching for artwork: %s (%d)", url, av_err2str(ret), ret);
      return NULL;
    }

    ret = avformat_find_stream_info(pFormatCtx, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Failed to obtain stream info from file %@ when searching for artwork: %s (%d)",
                url, av_err2str(ret), ret);
      return NULL;
    }

    // Search the streams for one that contains front cover artwork.
    int index = 0;
    AVPacket* packet = NULL;
    for (int i = 0; i < pFormatCtx->nb_streams; i++) {
      AVStream* stream = pFormatCtx->streams[i];

      // For this stream to be cover artwork it must be an attached picture (APIC).
      if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) == 0) { continue; }

      // And it must not be a stream of thumbnail images.
      if ((stream->disposition & AV_DISPOSITION_TIMED_THUMBNAILS) != 0) { continue; }

      // If a stream passes these two checks mpv identifies it as album art. To match up with mpv
      // this is all IINA checks as well. ID3v2 defines picture types, but I did not find any code
      // in mpv checking to confirm the image is marked as front cover art. The list of picture
      // types can be found here: https://id3.org/id3v2.3.0#Attached_picture

      // Found front cover artwork.
      index = i;
      packet = &stream->attached_pic;
      break;
    }

    if (!packet) {
      return NULL;
    }

    // Form an image from the stream's data.
    LOG_DEBUG(@"Creating an image from stream %d using %d bytes", index, packet->size);
    NSData *data = [[NSData alloc] initWithBytes:packet->data length:packet->size];
    NSImage *image = [[NSImage alloc] initWithData:data];
    if (!image) {
      LOG_ERROR(@"Cannot create image from artwork for file: %@", url);
    }
    return image;
  }
  @finally {
    avformat_close_input(&pFormatCtx);
  }
}

// MARK: - Logging

#if DEBUG
/// Log details about the given decoded frame.
/// - Parameters:
///   - pCodec: The codec that decoded the frame.
///   - pFrame: The decoded frame to log.
+ (void)logFrame:(const AVCodec *)pCodec
                :(const AVFrame *)pFrame
{
  LOG_DEBUG(@"Decoded %s frame", pCodec->long_name);
  LOG_DEBUG(@"Pixel format: %s (%d)", av_get_pix_fmt_name(pFrame->format), pFrame->format);
  LOG_DEBUG(@"Color range: %s (%d)", av_color_range_name(pFrame->color_range), pFrame->color_range);
  LOG_DEBUG(@"Color primaries: %s (%d)", av_color_primaries_name(pFrame->color_primaries), pFrame->color_primaries);
  LOG_DEBUG(@"Color transfer: %s (%d)", av_color_transfer_name(pFrame->color_trc), pFrame->color_trc);
  LOG_DEBUG(@"Color space: %s (%d)", av_color_space_name(pFrame->colorspace), pFrame->colorspace);
  LOG_DEBUG(@"Width: %d", pFrame->width);
  LOG_DEBUG(@"Height: %d", pFrame->height);
}
#endif

@end
