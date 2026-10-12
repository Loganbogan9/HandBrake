/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^HBEngineDataCompletion)(NSData * _Nullable, NSError * _Nullable);
typedef void (^HBEngineProgress)(NSDictionary<NSString *, NSNumber *> *);

/// Owns a libhb handle. All engine access is serialized; callbacks arrive on main.
/// JSON copies cross the boundary; libhb pointers never escape to Swift.
@interface HBEngine : NSObject
- (void)prepareWithCompletion:(HBEngineDataCompletion)completion
    NS_SWIFT_NAME(prepare(completion:));
- (void)scanURL:(NSURL *)url titleIndex:(NSInteger)titleIndex
    hardwareDecode:(BOOL)hardwareDecode progress:(HBEngineProgress)progress
    completion:(HBEngineDataCompletion)completion
    NS_SWIFT_NAME(scan(url:titleIndex:hardwareDecode:progress:completion:));
- (void)encodeTitle:(NSInteger)titleIndex presetJSON:(NSData *)presetJSON
    optionsJSON:(NSData *)optionsJSON outputURL:(NSURL *)outputURL
    progress:(HBEngineProgress)progress completion:(void (^)(NSError * _Nullable))completion
    NS_SWIFT_NAME(encode(title:presetJSON:optionsJSON:outputURL:progress:completion:));
- (void)pause;
- (void)resume;
- (void)cancel;
- (void)shutdownWithCompletion:(void (^)(void))completion NS_SWIFT_NAME(shutdown(completion:));
@end
NS_ASSUME_NONNULL_END
