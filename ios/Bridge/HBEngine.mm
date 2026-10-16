/* SPDX-License-Identifier: GPL-2.0-or-later
 * Native libhb integration, following macosx/HBCore.m and test/test.c. */
#import "HBEngine.h"
#import "HBJobPolicy.h"
#include "handbrake/handbrake.h"
extern "C" {
#include "handbrake/ports.h"
}
#include <string>

static NSString * const HBErrorDomain = @"org.handbrake.ios.engine";
static NSLock *logLock;
static NSMutableArray<NSString *> *errorLog;
static void engineError(const char *message)
{
    @autoreleasepool
    {
        NSString *line = message ? [NSString stringWithUTF8String:message] : nil;
        if (!line) return;
        [logLock lock];
        [errorLog addObject:line];
        if (errorLog.count > 32) [errorLog removeObjectAtIndex:0];
        [logLock unlock];
    }
}
static NSError *failure(NSInteger code, NSString *message)
{
    [logLock lock];
    NSString *detail = [errorLog componentsJoinedByString:@"\n"];
    [logLock unlock];
    return [NSError errorWithDomain:HBErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey:message,
        NSLocalizedFailureReasonErrorKey:detail ?: @""
    }];
}
static void clearErrors(void)
{
    [logLock lock]; [errorLog removeAllObjects]; [logLock unlock];
}
static NSString *string(const char *value) { return value ? @(value) : @""; }
static NSData *jsonData(id value) { return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]; }
static void onControlThread(void (^action)(void))
{
    // libhb's pause mutex is held from hb_pause until hb_resume. A GCD serial
    // queue can use different pthreads; these paired controls must use one OS
    // thread. The app never synchronously waits for the engine queue on main.
    if (NSThread.isMainThread) action();
    else dispatch_sync(dispatch_get_main_queue(), action);
}
static id takeJSON(char *value)
{
    if (!value) return nil;
    NSData *data = [NSData dataWithBytes:value length:strlen(value)];
    free(value);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
static const hb_encoder_t *findEncoder(const char *identifier, int video)
{
    if (!identifier) return NULL;
    const hb_encoder_t *cursor = NULL;
    while ((cursor = video ? hb_video_encoder_get_next(cursor) : hb_audio_encoder_get_next(cursor)))
        if (!strcmp(identifier, cursor->short_name)) return cursor;
    return NULL;
}
static NSDictionary *canonicalPreset(NSDictionary *node)
{
    NSMutableDictionary *preset = [NSJSONSerialization JSONObjectWithData:jsonData(node) options:NSJSONReadingMutableContainers error:nil];
    NSString *format = preset[@"FileFormat"];
    int mux = hb_container_get_from_name(format.UTF8String);
    const hb_container_t *container = NULL;
    while ((container = hb_container_get_next(container)))
        if (container->format == mux) { preset[@"FileFormat"] = string(container->short_name); break; }
    // Only these names designate generic encoder families. Explicit concrete
    // names stay intact so unavailable FDK/VT/etc. cannot become a fallback.
    for (NSMutableDictionary *audio in preset[@"AudioList"])
    {
        NSString *name = audio[@"AudioEncoder"];
        if ([name isEqualToString:@"aac"] || [name isEqualToString:@"haac"])
        {
            int codec = hb_audio_encoder_get_from_name(name.UTF8String);
            const hb_encoder_t *encoder = NULL;
            while ((encoder = hb_audio_encoder_get_next(encoder)))
                if (encoder->codec == codec) { audio[@"AudioEncoder"] = string(encoder->short_name); break; }
        }
    }
    return preset;
}
static void flattenPresets(NSArray *nodes, NSString *parent, NSMutableArray *result)
{
    for (NSDictionary *node in nodes)
    {
        NSString *name = node[@"PresetName"] ?: @"Unnamed";
        NSString *path = parent.length ? [parent stringByAppendingFormat:@"/%@", name] : name;
        if ([node[@"Folder"] boolValue]) flattenPresets(node[@"ChildrenArray"], path, result);
        else
        {
            NSString *payload = [[NSString alloc] initWithData:jsonData(canonicalPreset(node)) encoding:NSUTF8StringEncoding];
            [result addObject:@{@"id":path, @"name":path, @"presetJSON":payload}];
        }
    }
}

@interface HBEngine ()
{
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    hb_handle_t *_handle;
    BOOL _scanning, _encoding, _cancelled, _closing;
    HBEngineProgress _progress;
    HBEngineDataCompletion _scanCompletion;
    void (^_encodeCompletion)(NSError *);
    void (^_shutdownCompletion)(void);
    NSURL *_scanURL, *_outputURL;
    std::string _scanPath; // libhb scan thread may read it until SCANDONE.
    NSError *_stopError;
    unsigned _pollCount;
}
@end

@implementation HBEngine
- (instancetype)init
{
    if ((self = [super init])) _queue = dispatch_queue_create("org.handbrake.ios.engine", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (BOOL)initializeEngine
{
    if (_handle) return YES;
    if (_closing) return NO;
    static dispatch_once_t once;
    static int result = -1;
    dispatch_once(&once, ^{
        logLock = [NSLock new]; errorLog = [NSMutableArray new];
        NSURL *temp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"HandBrake"] isDirectory:YES];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:temp withIntermediateDirectories:YES attributes:nil error:&error]) return;
        hb_set_temporary_directory(temp.fileSystemRepresentation);
        hb_register_error_handler(engineError);
        result = hb_global_init();
        // Process-wide tables/presets live until exit, shared by every handle.
    });
    if (result != 0) return NO;
    _handle = hb_init(HB_DEBUG_NONE);
    return _handle != NULL;
}
- (void)prepareWithCompletion:(HBEngineDataCompletion)completion
{
    dispatch_async(_queue, ^{
        if (![self initializeEngine])
        {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, failure(1, @"Could not initialize HandBrake.")); });
            return;
        }
        NSMutableArray *video = [NSMutableArray new], *audio = [NSMutableArray new], *containers = [NSMutableArray new];
        const hb_encoder_t *encoder = NULL;
        while ((encoder = hb_video_encoder_get_next(encoder)))
        {
            float low = 0, high = 0, step = 0; int direction = 0;
            hb_video_quality_get_limits(encoder->codec, &low, &high, &step, &direction);
            double preferred = encoder->codec & HB_VCODEC_VT_MASK ? 60 : 22;
            preferred = fmax(low, fmin(high, preferred));
            // This frontend exposes CQ/ABR controls. Fixed-mode codecs need a separate editor.
            if (!hb_video_quality_is_supported(encoder->codec) && !hb_video_bitrate_is_supported(encoder->codec)) continue;
            [video addObject:@{@"id":string(encoder->short_name), @"name":string(encoder->name),
                @"muxers":@(encoder->muxers), @"qualityMin":@(low), @"qualityMax":@(high),
                @"qualityDefault":@(preferred), @"qualitySupported":@(hb_video_quality_is_supported(encoder->codec)),
                @"bitrateSupported":@(hb_video_bitrate_is_supported(encoder->codec))}];
        }
        encoder = NULL;
        while ((encoder = hb_audio_encoder_get_next(encoder)))
        {
            // Passthrough requires per-source checks; expose explicit encoders first.
            if (encoder->codec & HB_ACODEC_PASS_FLAG) continue;
            int low = 0, high = 0;
            hb_audio_bitrate_get_limits(encoder->codec, 48000, HB_AMIXDOWN_STEREO, &low, &high);
            if (high <= 0) continue; // Lossless audio needs compression-level controls.
            [audio addObject:@{@"id":string(encoder->short_name), @"name":string(encoder->name),
                @"muxers":@(encoder->muxers), @"qualityMin":@0, @"qualityMax":@0,
                @"qualityDefault":@0, @"qualitySupported":@NO, @"bitrateSupported":@YES}];
        }
        const hb_container_t *container = NULL;
        while ((container = hb_container_get_next(container)))
            [containers addObject:@{@"id":string(container->short_name), @"name":string(container->name), @"muxer":@(container->format)}];
        NSMutableArray *presets = [NSMutableArray new];
        id builtin = takeJSON(hb_presets_builtin_get_json());
        if ([builtin isKindOfClass:NSArray.class]) flattenPresets(builtin, @"", presets);
        NSData *data = jsonData(@{@"capabilities":@{@"videoEncoders":video, @"audioEncoders":audio, @"containers":containers}, @"presets":presets});
        dispatch_async(dispatch_get_main_queue(), ^{ completion(data, nil); });
    });
}
- (void)scanURL:(NSURL *)url titleIndex:(NSInteger)titleIndex hardwareDecode:(BOOL)hardwareDecode
    progress:(HBEngineProgress)progress completion:(HBEngineDataCompletion)completion
{
    dispatch_async(_queue, ^{
        if (self->_scanning || self->_encoding || ![self initializeEngine])
        {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, failure(2, @"The engine is busy or unavailable.")); }); return;
        }
        if (!url.isFileURL || ![NSFileManager.defaultManager isReadableFileAtPath:url.path])
        {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, failure(3, @"The imported source is not readable.")); }); return;
        }
        clearErrors();
        self->_cancelled = NO; self->_stopError = nil;
        self->_scanURL = url; self->_scanPath = url.fileSystemRepresentation;
        self->_scanning = YES; self->_scanCompletion = [completion copy]; self->_progress = [progress copy];
        hb_force_rescan(self->_handle);
        hb_list_t *paths = hb_list_init();
        hb_list_add(paths, (void *)self->_scanPath.c_str());
        hb_scan(self->_handle, paths, (int)titleIndex, 10, 0, 0, 0, 0, 0, NULL,
                hardwareDecode ? HB_DECODE_VIDEOTOOLBOX : 0, 0);
        hb_list_close(&paths);
        [self startTimer];
    });
}
- (NSData *)titleData
{
    NSDictionary *set = takeJSON(hb_get_title_set_json(_handle));
    NSMutableArray *titles = [NSMutableArray new];
    for (NSDictionary *title in set[@"TitleList"])
    {
        NSMutableArray *audio = [NSMutableArray new], *subtitles = [NSMutableArray new];
        for (NSDictionary *track in title[@"AudioList"])
            [audio addObject:@{@"id":@([track[@"TrackNumber"] intValue] - 1), @"name":track[@"Name"] ?: track[@"Description"] ?: @"Audio",
                @"language":track[@"Language"] ?: @"Unknown", @"codec":track[@"CodecName"] ?: @"Unknown"}];
        for (NSDictionary *track in title[@"SubtitleList"])
            [subtitles addObject:@{@"id":@([track[@"TrackNumber"] intValue] - 1), @"name":track[@"Name"] ?: track[@"SourceName"] ?: @"Subtitle",
                @"language":track[@"Language"] ?: @"Unknown", @"codec":track[@"SourceName"] ?: @"Unknown"}];
        NSDictionary *rate = title[@"FrameRate"];
        double fps = [rate[@"Den"] doubleValue] > 0 ? [rate[@"Num"] doubleValue] / [rate[@"Den"] doubleValue] : 0;
        [titles addObject:@{@"id":title[@"Index"], @"name":title[@"Name"] ?: @"Video",
            @"duration":@([title[@"Duration"][@"Ticks"] doubleValue] / 90000.0),
            @"width":title[@"Geometry"][@"Width"], @"height":title[@"Geometry"][@"Height"], @"frameRate":@(fps),
            @"audio":audio, @"subtitles":subtitles, @"chapters":@([title[@"ChapterList"] count])}];
    }
    return jsonData(titles);
}

// Validate the explicitly requested codecs before preset processing can sanitize them.
- (hb_dict_t *)buildJob:(NSInteger)titleIndex preset:(NSData *)presetData options:(NSData *)optionsData
    output:(NSURL *)output error:(NSError **)error
{
    std::string presetText((const char *)presetData.bytes, presetData.length);
    std::string optionsText((const char *)optionsData.bytes, optionsData.length);
    hb_value_t *preset = hb_value_json(presetText.c_str()), *options = hb_value_json(optionsText.c_str());
    hb_dict_t *job = NULL;
    NSString *message = nil;
    do
    {
        if (!preset || !options || hb_value_type(preset) != HB_VALUE_TYPE_DICT || hb_value_type(options) != HB_VALUE_TYPE_DICT)
        { message = @"Invalid preset or encoding settings."; break; }
        hb_title_t *title = hb_find_title_by_index(_handle, (int)titleIndex);
        if (!title) { message = @"Scan the requested title before encoding."; break; }
        const char *vname = hb_dict_get_string(options, "videoEncoder"), *aname = hb_dict_get_string(options, "audioEncoder");
        const char *mname = hb_dict_get_string(options, "container");
        int mux = mname ? hb_container_get_from_name(mname) : 0;
        // Upstream *_get_from_name deliberately maps disabled encoders to
        // fallbacks. Only exact runtime-enumerated names are valid here.
        const hb_encoder_t *v = findEncoder(vname, 1), *a = findEncoder(aname, 0);
        int vcodec = v ? v->codec : 0, acodec = a ? a->codec : 0;
        if (!v || !a || !mux || !(v->muxers & mux) || !(a->muxers & mux))
        { message = @"The selected codec is unavailable or incompatible with this container. Choose an available encoder explicitly."; break; }
        int width = hb_dict_get_int(options, "width"), height = hb_dict_get_int(options, "height");
        double fps = hb_dict_get_double(options, "frameRate");
        if (!hb_ios_valid_dimensions(width, height) || !hb_ios_valid_rate(fps))
        { message = @"Resolution limits must be even numbers from 32 to 8192; frame rate must be source or 1–240 fps."; break; }
        const char *qualityMode = hb_dict_get_string(options, "qualityMode");
        if (!qualityMode || (strcmp(qualityMode, "constantQuality") && strcmp(qualityMode, "averageBitrate")))
        { message = @"Choose constant quality or average bitrate explicitly."; break; }
        BOOL cq = !strcmp(qualityMode, "constantQuality");
        double quality = hb_dict_get_double(options, "quality");
        int bitrate = hb_dict_get_int(options, "bitrate"), abitrate = hb_dict_get_int(options, "audioBitrate");
        float low, high, step; int direction;
        hb_video_quality_get_limits(vcodec, &low, &high, &step, &direction);
        if ((cq && (!hb_video_quality_is_supported(vcodec) || !isfinite(quality) || quality < low || quality > high)) ||
            (!cq && (!hb_video_bitrate_is_supported(vcodec) || bitrate < 100 || bitrate > 200000)) || abitrate < 32 || abitrate > 640)
        { message = @"The selected rate control settings are outside this encoder's supported range."; break; }
        hb_value_array_t *tracks = hb_dict_get(options, "audioTracks");
        if (!tracks || hb_value_type(tracks) != HB_VALUE_TYPE_ARRAY)
        { message = @"Invalid audio track selection."; break; }
        BOOL badTrack = NO;
        NSMutableSet *selectedTracks = [NSMutableSet new];
        for (int i = 0; i < hb_value_array_len(tracks); i++)
        {
            int track = (int)hb_value_get_int(hb_value_array_get(tracks, i));
            if (track < 0 || track >= hb_list_count(title->list_audio) || [selectedTracks containsObject:@(track)]) badTrack = YES;
            else
            {
                hb_audio_config_t *config = hb_list_audio_config_item(title->list_audio, track);
                int samplerate = hb_audio_samplerate_find_closest(config->in.samplerate, acodec);
                int mixdown = hb_mixdown_get_best(acodec, config->in.ch_layout, HB_AMIXDOWN_STEREO);
                if (hb_audio_bitrate_get_best(acodec, abitrate, samplerate, mixdown) != abitrate)
                { message = @"The audio bitrate is unsupported for a selected track and encoder. Choose a supported bitrate."; break; }
            }
            [selectedTracks addObject:@(track)];
        }
        if (message) break;
        if (badTrack) { message = @"An audio track is missing or selected twice."; break; }
        NSDictionary *inputAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:string(title->path) error:nil];
        uint64_t required = hb_ios_required_space((double)title->duration / 90000.0,
            [inputAttributes[NSFileSize] unsignedLongLongValue], cq ? 0 : bitrate, abitrate, (int)hb_value_array_len(tracks));
        NSNumber *capacity = nil;
        [output.URLByDeletingLastPathComponent getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
        if (!capacity || capacity.longLongValue < 0 || (uint64_t)capacity.longLongValue < required)
        { message = @"Insufficient free storage for this job and the engine's 256 MB reserve."; break; }
        if (hb_dict_get_bool(options, "hardwareDecode") && !(title->video_decode_support & HB_DECODE_VIDEOTOOLBOX))
        { message = @"VideoToolbox decoding is unavailable for this source. Turn off hardware decoding to use the software decoder."; break; }
        hb_dict_set_string(preset, "VideoEncoder", vname);
        hb_dict_set_string(preset, "FileFormat", mname);
        hb_dict_set_int(preset, "VideoQualityType", cq ? 2 : 1);
        hb_dict_set_double(preset, "VideoQualitySlider", quality);
        hb_dict_set_int(preset, "VideoAvgBitrate", bitrate);
        hb_dict_set_bool(preset, "VideoMultiPass", 0);
        hb_dict_set_int(preset, "PictureWidth", width);
        hb_dict_set_int(preset, "PictureHeight", height);
        hb_dict_set_int(preset, "PictureForceWidth", 0); hb_dict_set_int(preset, "PictureForceHeight", 0);
        hb_dict_set_bool(preset, "PictureKeepRatio", 1); hb_dict_set_bool(preset, "PictureAllowUpscaling", 0);
        hb_dict_set_string(preset, "PictureDeinterlaceFilter", hb_dict_get_bool(options, "deinterlace") ? "bwdif" : "off");
        hb_dict_set_string(preset, "PictureDeinterlacePreset", "default");
        hb_dict_set_bool(preset, "ChapterMarkers", hb_dict_get_bool(options, "chapterMarkers"));
        char rate[32]; snprintf(rate, sizeof(rate), "%.6g", fps);
        if (fps != 0 && hb_video_framerate_get_from_name(rate) < 0)
        { message = @"Choose a frame rate from HandBrake's supported rates."; break; }
        hb_dict_set_string(preset, "VideoFramerate", fps == 0 ? "auto" : rate);
        hb_dict_set_string(preset, "VideoFramerateMode", fps == 0 ? "vfr" : "cfr");
        // Preset encoder tuning belongs to its original encoder; reset it only on codec change.
        id original = [NSJSONSerialization JSONObjectWithData:presetData options:0 error:nil];
        if (![original[@"VideoEncoder"] isEqualToString:string(vname)])
        {
            const char * const *presets = hb_video_encoder_get_presets(vcodec);
            hb_dict_set_string(preset, "VideoPreset", presets && presets[0] ? presets[0] : "");
            hb_dict_set_string(preset, "VideoProfile", "auto"); hb_dict_set_string(preset, "VideoLevel", "auto");
            hb_dict_set_string(preset, "VideoTune", ""); hb_dict_set_string(preset, "VideoOptionExtra", "");
            hb_dict_set_bool(preset, "x264UseAdvancedOptions", 0);
        }
        job = hb_preset_job_init(_handle, (int)titleIndex, preset);
        if (!job) { message = @"HandBrake rejected the preset settings."; break; }
        hb_dict_t *dest = hb_dict_get(job, "Destination");
        hb_dict_set_string(dest, "File", output.fileSystemRepresentation);
        hb_dict_t *source = hb_dict_get(job, "Source");
        hb_dict_set_int(source, "HWDecode", hb_dict_get_bool(options, "hardwareDecode") ? HB_DECODE_VIDEOTOOLBOX | HB_DECODE_FORCE_HW : 0);
        hb_dict_set_int(hb_dict_get(job, "Video"), "HardwareDecode", hb_dict_get_bool(options, "hardwareDecode") ? HB_DECODE_VIDEOTOOLBOX | HB_DECODE_FORCE_HW : 0);
        hb_dict_t *audio = hb_dict_get(job, "Audio");
        hb_value_array_t *audioList = hb_value_array_init();
        hb_dict_set(audio, "AudioList", audioList);
        for (int i = 0; i < hb_value_array_len(tracks); i++)
        {
            hb_dict_t *item = hb_dict_init();
            hb_dict_set_int(item, "Track", hb_value_get_int(hb_value_array_get(tracks, i)));
            hb_dict_set_string(item, "Encoder", aname); hb_dict_set_int(item, "Bitrate", abitrate);
            hb_audio_config_t *config = hb_list_audio_config_item(title->list_audio, hb_value_get_int(hb_value_array_get(tracks, i)));
            hb_dict_set_string(item, "Mixdown", hb_mixdown_get_short_name(hb_mixdown_get_best(acodec, config->in.ch_layout, HB_AMIXDOWN_STEREO)));
            hb_dict_set_int(item, "Samplerate", hb_audio_samplerate_find_closest(config->in.samplerate, acodec));
            hb_value_array_append(audioList, item);
        }
        hb_dict_t *subtitle = hb_dict_get(job, "Subtitle");
        hb_value_array_t *subtitleList = hb_value_array_init(); hb_dict_set(subtitle, "SubtitleList", subtitleList);
        hb_dict_set_bool(hb_dict_get(subtitle, "Search"), "Enable", 0);
        hb_value_t *selection = hb_dict_get(options, "subtitleTrack");
        if (selection && hb_value_type(selection) != HB_VALUE_TYPE_NULL)
        {
            int track = (int)hb_value_get_int(selection);
            hb_subtitle_t *sub = (hb_subtitle_t *)hb_list_item(title->list_subtitle, track);
            if (!sub || !hb_subtitle_can_pass(sub->source, mux))
            { message = @"This subtitle cannot pass through the selected container. Select no subtitles or another container."; break; }
            hb_dict_t *item = hb_dict_init(); hb_dict_set_int(item, "Track", track);
            hb_dict_set_bool(item, "Default", 1); hb_dict_set_bool(item, "Burn", 0); hb_dict_set_bool(item, "Forced", 0);
            hb_value_array_append(subtitleList, item);
        }
    } while (0);
    hb_value_free(&preset); hb_value_free(&options);
    if (message) { hb_value_free(&job); *error = failure(4, message); }
    return job;
}
- (void)encodeTitle:(NSInteger)titleIndex presetJSON:(NSData *)presetJSON optionsJSON:(NSData *)optionsJSON
    outputURL:(NSURL *)outputURL progress:(HBEngineProgress)progress completion:(void (^)(NSError *))completion
{
    dispatch_async(_queue, ^{
        NSError *error = nil;
        if (self->_scanning || self->_encoding || ![self initializeEngine]) error = failure(2, @"The engine is busy or unavailable.");
        else if (!outputURL.isFileURL || [NSFileManager.defaultManager fileExistsAtPath:outputURL.path]) error = failure(5, @"Choose a new output file in the app's storage.");
        if (error) { dispatch_async(dispatch_get_main_queue(), ^{ completion(error); }); return; }
        clearErrors();
        hb_dict_t *job = [self buildJob:titleIndex preset:presetJSON options:optionsJSON output:outputURL error:&error];
        if (!job) { dispatch_async(dispatch_get_main_queue(), ^{ completion(error ?: failure(4, @"Cannot create this job.")); }); return; }
        char *text = hb_value_get_json(job); hb_value_free(&job);
        int result = text ? hb_add_json(self->_handle, text) : -1;
        free(text);
        if (result < 0) { dispatch_async(dispatch_get_main_queue(), ^{ completion(failure(6, @"HandBrake could not add the encoding job.")); }); return; }
        self->_encoding = YES; self->_cancelled = NO; self->_stopError = nil; self->_outputURL = outputURL;
        self->_progress = [progress copy]; self->_encodeCompletion = [completion copy];
        hb_start(self->_handle); [self startTimer];
    });
}
- (void)startTimer
{
    _pollCount = 0;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 5, NSEC_PER_SEC / 50);
    // Deliberately retain self during work: cancellation completes before handle destruction.
    dispatch_source_set_event_handler(_timer, ^{ [self poll]; });
    dispatch_resume(_timer);
}
- (void)poll
{
    hb_state_t state = {0}; hb_get_state(_handle, &state);
    if (state.state == HB_STATE_SCANDONE && _scanning)
    {
        NSData *data = [self titleData];
        NSArray *titles = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSError *error = _cancelled ? failure(NSUserCancelledError, @"Scanning was cancelled.") :
            titles.count == 0 ? failure(7, @"HandBrake found no readable video titles in this file.") : nil;
        HBEngineDataCompletion completion = _scanCompletion; _scanCompletion = nil;
        [self finishOperation];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error ? nil : data, error); });
        return;
    }
    if (state.state == HB_STATE_WORKDONE && _encoding)
    {
        NSError *error = _stopError ?: (_cancelled ? failure(NSUserCancelledError, @"Encoding was cancelled.") :
            state.param.working.error != HB_ERROR_NONE ? failure(state.param.working.error, @"HandBrake could not finish encoding. See the engine diagnostic below.") : nil);
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:_outputURL.path error:nil];
        if (!error && [attributes[NSFileSize] unsignedLongLongValue] == 0) error = failure(8, @"The engine produced an empty output file.");
        if (error) [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];
        void (^completion)(NSError *) = _encodeCompletion; _encodeCompletion = nil;
        [self finishOperation];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        return;
    }
    if (_encoding && ++_pollCount % 25 == 0 && !_stopError)
    {
        NSNumber *space = nil;
        [_outputURL.URLByDeletingLastPathComponent getResourceValue:&space forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
        if (space && space.longLongValue < 32LL * 1024 * 1024)
        { _stopError = failure(9, @"Encoding stopped because storage is nearly full."); onControlThread(^{ hb_stop(self->_handle); }); }
    }
    double progress = 0, fps = 0; int64_t eta = -1; int pass = 1, passCount = 1;
    if (state.state == HB_STATE_SCANNING) progress = state.param.scanning.progress;
    if (state.state == HB_STATE_WORKING || state.state == HB_STATE_PAUSED || state.state == HB_STATE_SEARCHING)
    {
        pass = MAX(1, state.param.working.pass); passCount = MAX(1, state.param.working.pass_count);
        progress = (pass - 1 + state.param.working.progress) / passCount;
        fps = state.param.working.rate_cur; eta = state.param.working.eta_seconds;
    }
    if (state.state == HB_STATE_MUXING) progress = state.param.muxing.progress;
    HBEngineProgress callback = _progress;
    if (callback)
    {
        NSDictionary *snapshot = @{@"state":@(state.state), @"progress":@(fmax(0, fmin(1, progress))), @"fps":@(fps), @"etaSeconds":@(eta), @"pass":@(pass), @"passCount":@(passCount)};
        dispatch_async(dispatch_get_main_queue(), ^{ callback(snapshot); });
    }
}
- (void)finishOperation
{
    dispatch_source_cancel(_timer); _timer = nil;
    onControlThread(^{ hb_resume(self->_handle); });
    _scanning = NO; _encoding = NO; _progress = nil; _scanURL = nil; _scanPath.clear(); _outputURL = nil;
    // libhb removes completed jobs; discard any unstarted passes after cancellation.
    while (hb_count(_handle))
    {
        hb_job_t *job = hb_job(_handle, 0); hb_rem(_handle, job); hb_job_close(&job);
    }
    if (_closing) [self finishShutdown];
}
- (void)pause { dispatch_async(_queue, ^{ if (self->_encoding) onControlThread(^{ hb_pause(self->_handle); }); }); }
- (void)resume { dispatch_async(_queue, ^{ if (self->_encoding && !self->_cancelled) onControlThread(^{ hb_resume(self->_handle); }); }); }
- (void)cancel
{
    dispatch_async(_queue, ^{
        self->_cancelled = YES;
        if (self->_scanning) onControlThread(^{ hb_scan_stop(self->_handle); });
        if (self->_encoding) onControlThread(^{ hb_stop(self->_handle); });
    });
}
- (void)shutdownWithCompletion:(void (^)(void))completion
{
    dispatch_async(_queue, ^{
        self->_closing = YES; self->_shutdownCompletion = [completion copy]; self->_cancelled = YES;
        if (self->_scanning) onControlThread(^{ hb_scan_stop(self->_handle); });
        else if (self->_encoding) onControlThread(^{ hb_stop(self->_handle); });
        else [self finishShutdown];
    });
}
- (void)finishShutdown
{
    if (_handle) hb_close(&_handle);
    void (^completion)(void) = _shutdownCompletion; _shutdownCompletion = nil;
    if (completion) dispatch_async(dispatch_get_main_queue(), completion);
}
- (void)dealloc
{
    // Active operations retain the owner until completion; no libhb worker can use a freed handle.
    if (_handle) hb_close(&_handle);
}
@end
