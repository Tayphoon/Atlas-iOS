//
//  ATLUIMessageCollectionViewCell.m
//  Atlas
//
//  Created by Kevin Coleman on 8/31/14.
//  Copyright (c) 2014 Layer, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "ATLMessageCollectionViewCell.h"
#import "ATLMessagingUtilities.h"
#import "ATLUIImageHelper.h"
#import "ATLIncomingMessageCollectionViewCell.h"
#import "ATLOutgoingMessageCollectionViewCell.h"

#import <LayerKit/LayerKit.h>


NSString *const ATLGIFAccessibilityLabel = @"Message: GIF";
NSString *const ATLImageAccessibilityLabel = @"Message: Image";
NSString *const ATLVideoAccessibilityLabel = @"Message: Video";
static char const ATLMessageCollectionViewCellImageProcessingConcurrentQueue[] = "com.layer.Atlas.ATLMessageCollectionViewCell.imageProcessingConcurrentQueue";

CGFloat const ATLMessageCellMinimumHeight = 10.0f;
NSInteger const kATLSharedCellTag = 1000;

@interface ATLMessageCollectionViewCell () <LYRProgressDelegate>

@property (nonatomic) BOOL messageSentState;
@property (nonatomic) LYRProgress *progress;
@property (nonatomic) NSUInteger lastProgressFractionCompleted;
@property (nonatomic) dispatch_queue_t imageProcessingConcurrentQueue;

@end

@implementation ATLMessageCollectionViewCell

+ (ATLMessageCollectionViewCell *)sharedCell
{
    static ATLMessageCollectionViewCell *_sharedCell;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedCell = [[self class] new];
        _sharedCell.tag = kATLSharedCellTag;
        _sharedCell.hidden = YES;
    });
    return _sharedCell;
}

+ (NSCache *)sharedHeightCache
{
    static NSCache *sharedHeightCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedHeightCache = [NSCache new];
    });
    return sharedHeightCache;
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self lyr_commonInit];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self lyr_commonInit];
    }
    return self;
}

- (void)lyr_commonInit
{
    // Default UIAppearance
    _messageTextFont = [UIFont systemFontOfSize:17];
    _messageTextColor = [UIColor blackColor];
    _messageLinkTextColor = [UIColor whiteColor];
    _messageTextCheckingTypes = NSTextCheckingTypeLink | NSTextCheckingTypePhoneNumber;
    _imageProcessingConcurrentQueue = dispatch_queue_create(ATLMessageCollectionViewCellImageProcessingConcurrentQueue, DISPATCH_QUEUE_CONCURRENT);
    [self.bubbleView updateProgressIndicatorWithProgress:0.0 visible:NO animated:NO];
}

- (void)prepareForReuse
{
    [super prepareForReuse];
    // Remove self from any previously assigned LYRProgress instance.
    self.progress.delegate = nil;
    self.lastProgressFractionCompleted = 0;
}

- (void)presentMessage:(LYRMessage *)message
{
    self.message = message;
    [self updateBubbleWidth:[[self class] cellSizeForMessage:self.message inView:nil].width];
    for (LYRMessagePart *messagePart in message.parts) {
        if ([self messageContainsTextContent]) {
            [self configureBubbleViewForTextContent];
            break;
        } else if ([messagePart.MIMEType isEqualToString:ATLMIMETypeImageJPEG]) {
            [self configureBubbleViewForImageContent];
            break;
        }else if ([messagePart.MIMEType isEqualToString:ATLMIMETypeImagePNG]) {
            [self configureBubbleViewForImageContent];
            break;
        } else if ([messagePart.MIMEType isEqualToString:ATLMIMETypeImageGIF]){
            [self configureBubbleViewForGIFContent];
            break;
        } else if ([messagePart.MIMEType isEqualToString:ATLMIMETypeLocation]) {
            [self configureBubbleViewForLocationContent];
            break;
        } else if ([messagePart.MIMEType isEqualToString:ATLMIMETypeVideoMP4]) {
            [self configureBubbleViewForVideoContent];
            break;
        }
    }
}

- (void)configureBubbleViewForTextContent
{
    LYRMessagePart *messagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeTextPlain);
    NSString *text = [[NSString alloc] initWithData:messagePart.data encoding:NSUTF8StringEncoding];
    [self.bubbleView updateWithAttributedText:[self attributedStringForText:text]];
    [self.bubbleView updateProgressIndicatorWithProgress:0.0 visible:NO animated:NO];
    self.accessibilityLabel = [NSString stringWithFormat:@"Message: %@", text];
}

- (void)configureBubbleViewForImageContent
{
    self.accessibilityLabel = ATLImageAccessibilityLabel;

    LYRMessagePart *fullResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEG);
    if (!fullResImagePart) {
        fullResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImagePNG);
    }
    
    if (fullResImagePart && ((fullResImagePart.transferStatus == LYRContentTransferAwaitingUpload) || (fullResImagePart.transferStatus == LYRContentTransferUploading))) {
        [self updateCellWithProgress:fullResImagePart.progress];
    } else {
        [self.bubbleView updateProgressIndicatorWithProgress:1.0 visible:NO animated:YES];
    }
    
    __block UIImage *displayingImage;
    __block LYRMessagePart *previewImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEGPreview);
    if (!previewImagePart) {
        previewImagePart = fullResImagePart;  // If no preview image part found, resort to the full-resolution image.
    }
    
    __weak typeof(self) weakSelf = self;
    __block LYRMessage *previousMessage = weakSelf.message;
    
    dispatch_async(self.imageProcessingConcurrentQueue, ^{
        
        if (previewImagePart.fileURL) {
            displayingImage = [UIImage imageWithContentsOfFile:previewImagePart.fileURL.path];
        } else {
            displayingImage = [UIImage imageWithData:previewImagePart.data];
        }
        
        CGSize size = CGSizeZero;
        LYRMessagePart *sizePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageSize);
        if (sizePart) {
            size = ATLImageSizeForJSONData(sizePart.data);
            size = ATLConstrainImageSizeToCellSize(size);
        }
        if (CGSizeEqualToSize(size, CGSizeZero)) {
            size = ATLImageSizeForData(fullResImagePart.data); // Resort to image's size, if no dimensions metadata message parts found.
        }
        
        // Fall-back to programatically requesting for a content download of single message part messages (Android compatibility).
        if ([[weakSelf.message valueForKeyPath:@"parts.MIMEType"] isEqual:@[ATLMIMETypeImageJPEG]]) {
            if (fullResImagePart && (fullResImagePart.transferStatus == LYRContentTransferReadyForDownload)) {
                NSError *error;
                LYRProgress *progress = [fullResImagePart downloadContent:&error];
                if (!progress) {
                    NSLog(@"failed to request for a content download from the UI with error=%@", error);
                }
                [weakSelf.bubbleView updateProgressIndicatorWithProgress:0.0 visible:NO animated:NO];
            } else if (fullResImagePart && (fullResImagePart.transferStatus == LYRContentTransferDownloading)) {
                [self updateCellWithProgress:fullResImagePart.progress];
            } else {
                [weakSelf.bubbleView updateProgressIndicatorWithProgress:1.0 visible:NO animated:YES];
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.message != previousMessage) {
                return;
            }
            [weakSelf.bubbleView updateWithImage:displayingImage width:size.width];
        });
    });
}

- (void)configureBubbleViewForVideoContent
{
    self.accessibilityLabel = ATLVideoAccessibilityLabel;
    
    LYRMessagePart *fullResVideoPart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4);
    if (fullResVideoPart && ((fullResVideoPart.transferStatus == LYRContentTransferAwaitingUpload) || (fullResVideoPart.transferStatus == LYRContentTransferUploading))) {
        [self updateCellWithProgress:fullResVideoPart.progress];
    }
    
    UIImage *displayingImage;
    LYRMessagePart *previewImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEGPreview);
    if (previewImagePart.fileURL) {
        displayingImage = [UIImage imageWithContentsOfFile:previewImagePart.fileURL.path];
    } else {
        displayingImage = [UIImage imageWithData:previewImagePart.data];
    }
    
    CGSize size = CGSizeZero;
    LYRMessagePart *sizePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageSize);
    if (sizePart) {
        CGSize fullSize = ATLImageSizeForJSONData(sizePart.data);
        size = ATLConstrainImageSizeToCellSize(fullSize);
    }
    [self.bubbleView updateWithVideoThumbnail:displayingImage width:size.width];
}

- (void)configureBubbleViewForGIFContent
{
    self.accessibilityLabel = ATLGIFAccessibilityLabel;

    LYRMessagePart *fullResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF);
    
    if (fullResImagePart && ((fullResImagePart.transferStatus == LYRContentTransferAwaitingUpload) ||
                             (fullResImagePart.transferStatus == LYRContentTransferUploading))) {
        // Set self for delegation, if full resolution message part
        // hasn't been uploaded yet, or is still uploading.
        LYRProgress *progress = fullResImagePart.progress;
        [progress setDelegate:self];
        self.progress = progress;
        [self.bubbleView updateProgressIndicatorWithProgress:progress.fractionCompleted visible:YES animated:NO];
    } else {
        [self.bubbleView updateProgressIndicatorWithProgress:1.0 visible:NO animated:YES];
    }
    
    __block UIImage *displayingImage;
    LYRMessagePart *previewImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIFPreview);
    
    if (!previewImagePart) {
        // If no preview image part found, resort to the full-resolution image.
        previewImagePart = fullResImagePart;
    }
    __weak typeof(self) weakSelf = self;
    __block LYRMessage *previousMessage = weakSelf.message;

    dispatch_async(self.imageProcessingConcurrentQueue, ^{
        if (previewImagePart.fileURL) {
            displayingImage = ATLAnimatedImageWithAnimatedGIFURL(previewImagePart.fileURL);
        } else if (previewImagePart.data) {
            displayingImage = ATLAnimatedImageWithAnimatedGIFData(previewImagePart.data);
        }
        
        CGSize size = CGSizeZero;
        LYRMessagePart *sizePart = ATLMessagePartForMIMEType(weakSelf.message, ATLMIMETypeImageSize);
        if (sizePart) {
            size = ATLImageSizeForJSONData(sizePart.data);
            size = ATLConstrainImageSizeToCellSize(size);
        }
        if (CGSizeEqualToSize(size, CGSizeZero)) {
            // Resort to image's size, if no dimensions metadata message parts found.
            size = ATLImageSizeForData(fullResImagePart.data);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // For GIFs we only download full resolution parts when rendered in the UI
            // Low res GIFs are autodownloaded but blurry
            if ([fullResImagePart.MIMEType isEqualToString:ATLMIMETypeImageGIF]) {
                if (fullResImagePart.transferStatus == LYRContentTransferReadyForDownload) {
                    NSError *error;
                    LYRProgress *progress = [fullResImagePart downloadContent:&error];
                    if (!progress) {
                        NSLog(@"failed to request for a content download from the UI with error=%@", error);
                    }
                    [weakSelf.bubbleView updateProgressIndicatorWithProgress:0.0 visible:NO animated:NO];
                    [weakSelf.bubbleView updateWithImage:displayingImage width:size.width];
                } else if (fullResImagePart.transferStatus == LYRContentTransferDownloading) {
                    LYRProgress *progress = fullResImagePart.progress;
                    [progress setDelegate:weakSelf];
                    weakSelf.progress = progress;
                    [weakSelf.bubbleView updateProgressIndicatorWithProgress:progress.fractionCompleted visible:YES animated:NO];
                    [weakSelf.bubbleView updateWithImage:displayingImage width:size.width];
                } else {
                    displayingImage = ATLAnimatedImageWithAnimatedGIFData(fullResImagePart.data);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (weakSelf.message != previousMessage) {
                            return;
                        }
                        [weakSelf.bubbleView updateProgressIndicatorWithProgress:1.0 visible:NO animated:YES];
                        [weakSelf.bubbleView updateWithImage:displayingImage width:size.width];
                    });
                }
            }
        });
    });
}

- (void)configureBubbleViewForLocationContent
{
    LYRMessagePart *messagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeLocation);
    NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:messagePart.data
                                                               options:NSJSONReadingAllowFragments
                                                                 error:nil];
    double lat = [dictionary[ATLLocationLatitudeKey] doubleValue];
    double lon = [dictionary[ATLLocationLongitudeKey] doubleValue];
    [self.bubbleView updateWithLocation:CLLocationCoordinate2DMake(lat, lon)];
    [self.bubbleView updateProgressIndicatorWithProgress:0.0 visible:NO animated:NO];
}

- (void)updateCellWithProgress:(LYRProgress *)progress
{
    [progress setDelegate:self];
    self.progress = progress;
    [self.bubbleView updateProgressIndicatorWithProgress:progress.fractionCompleted visible:YES animated:NO];
}

- (void)setMessageTextFont:(UIFont *)messageTextFont
{
    _messageTextFont = messageTextFont;
    if ([self messageContainsTextContent]) [self configureBubbleViewForTextContent];
}

- (void)setMessageTextColor:(UIColor *)messageTextColor
{
    _messageTextColor = messageTextColor;
    if ([self messageContainsTextContent]) [self configureBubbleViewForTextContent];
}

- (void)setMessageLinkTextColor:(UIColor *)messageLinkTextColor
{
    _messageLinkTextColor = messageLinkTextColor;
    if ([self messageContainsTextContent]) [self configureBubbleViewForTextContent];
}

- (void)setMessageTextCheckingTypes:(NSTextCheckingType)messageLinkTypes
{
    _messageTextCheckingTypes = messageLinkTypes;
    self.bubbleView.textCheckingTypes = messageLinkTypes;
}

#pragma mark - LYRProgress Delegate Implementation

- (void)progressDidChange:(LYRProgress *)progress
{
    // Queue UI updates onto the main thread, since LYRProgress performs
    // delegate callbacks from a background thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (progress.delegate == nil) {
            // Do not do any UI changes, if receiver has been removed.
            return;
        }
        BOOL progressCompleted = progress.fractionCompleted == 1.0f;
        [self.bubbleView updateProgressIndicatorWithProgress:progress.fractionCompleted visible:progressCompleted ? NO : YES animated:YES];
        // After transfer completes, remove self for delegation.
        if (progressCompleted) {
            progress.delegate = nil;
        }
    });
}

#pragma mark - Helpers

- (NSAttributedString *)attributedStringForText:(NSString *)text
{
    NSDictionary *attributes = @{NSFontAttributeName : self.messageTextFont, NSForegroundColorAttributeName : self.messageTextColor};
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:text attributes:attributes];
    NSArray *linkResults = ATLTextCheckingResultsForText(text, self.messageTextCheckingTypes);
    for (NSTextCheckingResult *result in linkResults) {
        NSDictionary *linkAttributes = @{NSForegroundColorAttributeName : self.messageLinkTextColor,
                                         NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle)};
        [attributedString addAttributes:linkAttributes range:result.range];
    }
    return attributedString;
}

- (BOOL)messageContainsTextContent
{
    return ATLMessagePartForMIMEType(self.message, ATLMIMETypeTextPlain) != nil;
}

#pragma mark - Cell Height Calculations

+ (CGFloat)cellHeightForMessage:(LYRMessage *)message inView:(UIView *)view
{
    CGFloat height = [[self class] cellSizeForMessage:message inView:view].height;
    if (height < ATLMessageCellMinimumHeight) height = ATLMessageCellMinimumHeight;
    height = ceil(height);
    return height;
}

#pragma mark - Cell Size Calculations

+ (CGSize)cellSizeForMessage:(LYRMessage *)message inView:(UIView *)view
{
    if ([[self sharedHeightCache] objectForKey:message.identifier]) {
        return [[[self sharedHeightCache] objectForKey:message.identifier] CGSizeValue];
    }

    CGSize size = CGSizeZero;
    for (LYRMessagePart *part in message.parts) {
        if ([part.MIMEType isEqualToString:ATLMIMETypeTextPlain]) {
            size = [[self class] cellSizeForTextMessage:message inView:view];
        } else if ([part.MIMEType isEqualToString:ATLMIMETypeImageJPEG] || [part.MIMEType isEqualToString:ATLMIMETypeImagePNG] || [part.MIMEType isEqualToString:ATLMIMETypeImageGIF]|| [part.MIMEType isEqualToString:ATLMIMETypeVideoMP4]) {
            size = [[self class] cellSizeForImageMessage:message];
        } else if ([part.MIMEType isEqualToString:ATLMIMETypeLocation]) {
            size.width = ATLMessageBubbleMapWidth;
            size.height = ATLMessageBubbleMapHeight;
        }
        if (!CGSizeEqualToSize(size, CGSizeZero)) {
            break;
        }
    }
    return size;
}

+ (CGSize)cellSizeForTextMessage:(LYRMessage *)message inView:(id)view
{
    //  Adding  the view to the hierarchy so that UIAppearance property values will be set based on containment.
    ATLMessageCollectionViewCell *cell = [self sharedCell];
    if (![view viewWithTag:kATLSharedCellTag]) {
        [view addSubview:cell];
    }
    
    LYRMessagePart *part = ATLMessagePartForMIMEType(message, ATLMIMETypeTextPlain);
    NSString *text = [[NSString alloc] initWithData:part.data encoding:NSUTF8StringEncoding];
    UIFont *font = [[[self class] appearance] messageTextFont];
    if (!font) {
        font = cell.messageTextFont;
    }
    CGSize size = ATLTextPlainSize(text, font);
    size.width += ATLMessageBubbleLabelHorizontalPadding * 2 + ATLMessageBubbleLabelWidthMargin;
    size.height += ATLMessageBubbleLabelVerticalPadding * 2;
    if (![[self sharedHeightCache] objectForKey:message.identifier]) {
        [[self sharedHeightCache] setObject:[NSValue valueWithCGSize:size] forKey:message.identifier];
    }
    return size;
}

+ (CGSize)cellSizeForImageMessage:(LYRMessage *)message
{
    CGSize size = CGSizeZero;
    LYRMessagePart *sizePart = ATLMessagePartForMIMEType(message, ATLMIMETypeImageSize);
    if (sizePart) {
        size = ATLImageSizeForJSONData(sizePart.data);
        size = ATLConstrainImageSizeToCellSize(size);
        return size;
    }
    if (CGSizeEqualToSize(size, CGSizeZero)) {
        LYRMessagePart *imagePart = ATLMessagePartForMIMEType(message, ATLMIMETypeImageJPEGPreview);
        if (!imagePart) {
            // If no preview image part found, resort to the full-resolution image.
            imagePart = ATLMessagePartForMIMEType(message, ATLMIMETypeImageJPEG);
        }
        if (!imagePart) {
            imagePart = ATLMessagePartForMIMEType(message, ATLMIMETypeImagePNG);
        }

        // Resort to image's size, if no dimensions metadata message parts found.
        if ((imagePart.transferStatus == LYRContentTransferComplete) ||
            (imagePart.transferStatus == LYRContentTransferAwaitingUpload) ||
            (imagePart.transferStatus == LYRContentTransferUploading)) {
            size = ATLImageSizeForData(imagePart.data);
        } else {
            // We don't have the image data yet, making cell think there's
            // an image with 3:4 aspect ration (portrait photo).
            size = ATLConstrainImageSizeToCellSize(CGSizeMake(3000, 4000));
        }
    }
    return size;
}

@end
