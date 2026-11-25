// Window-owned, one-shot macOS importer. Its only public result is a status code.
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

enum { HandedOff, Cancelled, UnsupportedInvite, NoInvite, InvalidImage,
       ImageTooLarge, DeliveryFailed, ImportFailed, NoClipboardImage };
static const off_t maxBytes = 16 * 1024 * 1024;
static const uint64_t maxDimension = 8192, maxPixels = 16 * 1024 * 1024;
static NSString *const ternBundle = @"so.stencil.tern";

static int hexDigit(unichar c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static NSURL *inviteURL(NSString *raw) {
    if (raw.length < 11 || raw.length > 16384) return nil;
    // Check the literal authority boundary too: URL parsers can discard an empty
    // port or decode an escaped hostname. Neither spelling is our route.
    if ([raw compare:@"tern://pair" options:NSCaseInsensitiveSearch
               range:NSMakeRange(0, 11)] != NSOrderedSame) return nil;
    NSUInteger i = 11;
    if (i < raw.length && [raw characterAtIndex:i] == '/') ++i;
    if (i < raw.length && [raw characterAtIndex:i] != '?') return nil;
    for (i = 0; i < raw.length; ++i) {
        unichar c = [raw characterAtIndex:i];
        if (c <= 0x20 || c >= 0x7f ||
            !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              strchr("-._~:/?[]@!$&'()*+,;=%", c))) return nil;
        if (c == '%') {
            if (i + 2 >= raw.length) return nil;
            int hi = hexDigit([raw characterAtIndex:i + 1]), lo = hexDigit([raw characterAtIndex:i + 2]);
            if (hi < 0 || lo < 0 || hi * 16 + lo < 0x20 || hi * 16 + lo == 0x7f) return nil;
            i += 2;
        }
    }
    NSURL *url = [NSURL URLWithString:raw];
    // Never deliver a URL silently repaired, trimmed, or re-encoded by Foundation.
    return [url.absoluteString isEqualToString:raw] ? url : nil;
}

static NSString *displayLabel(NSString *value, NSSet<NSString *> *credentials) {
    // Metadata is untrusted too. Don't display arbitrary payloads, control/bidi
    // characters, long opaque values, or a credential repeated as metadata.
    if (!value.length || value.length > 24) return nil;
    for (NSUInteger i = 0; i < value.length; ++i) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
              c == ' ' || c == '_' || c == '.' || c == '-')) return nil;
    }
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!value.length) return nil;
    for (NSString *credential in credentials) {
        if ([value containsString:credential] || [credential containsString:value]) return nil;
    }
    return value;
}

static NSArray<NSString *> *candidateTitles(NSArray<NSURL *> *urls) {
    NSMutableSet *credentials = [NSMutableSet set];
    NSMutableArray *metadata = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithCapacity:2];
        for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
            if ([item.name caseInsensitiveCompare:@"key"] == NSOrderedSame && item.value.length)
                [credentials addObject:item.value];
            if ([item.name isEqualToString:@"name"] || [item.name isEqualToString:@"user"])
                fields[item.name] = fields[item.name] ? @"" : (item.value ?: @"");
        }
        [metadata addObject:fields];
    }
    NSMutableArray *titles = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSDictionary *fields in metadata) {
        NSMutableArray *parts = [NSMutableArray arrayWithObject:
            [NSString stringWithFormat:@"QR %lu", (unsigned long)(titles.count + 1)]];
        for (NSString *field in @[@"name", @"user"]) {
            NSString *label = displayLabel(fields[field], credentials);
            if (label.length) [parts addObject:label];
        }
        [titles addObject:[parts componentsJoinedByString:@" · "]];
    }
    return titles;
}

typedef NSInteger (^ChooseInvite)(NSArray<NSString *> *titles);
typedef BOOL (^DeliverInvite)(NSURL *url);

static int submitCandidates(NSArray<NSString *> *payloads, int emptyStatus,
                            ChooseInvite choose, DeliverInvite deliver) {
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *raw in payloads) {
        if ([seen containsObject:raw]) continue;
        NSURL *url = inviteURL(raw);
        if (url) { [urls addObject:url]; [seen addObject:raw]; }
    }
    if (!urls.count) return emptyStatus;
    NSInteger index = urls.count == 1 ? 0 : choose(candidateTitles(urls));
    if (index < 0 || (NSUInteger)index >= urls.count) return Cancelled;
    return deliver(urls[index]) ? HandedOff : DeliveryFailed;
}

static BOOL regularLocalFile(struct stat info) {
    return S_ISREG(info.st_mode) && !(info.st_flags & SF_DATALESS);
}

static NSData *readImage(NSURL *file, int *status) {
    *status = InvalidImage;
    if (!file.isFileURL) return nil;
    const char *path = file.fileSystemRepresentation;
    struct stat info;
    struct statfs fs;
    if (!path || lstat(path, &info) || !regularLocalFile(info) || statfs(path, &fs) || !(fs.f_flags & MNT_LOCAL)) return nil;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    void *bytes = NULL;
    NSData *data = nil;
    if (!fstat(fd, &info) && regularLocalFile(info) && !fstatfs(fd, &fs) && (fs.f_flags & MNT_LOCAL)) {
        if (info.st_size > maxBytes) *status = ImageTooLarge;
        else if (info.st_size > 0 && (bytes = malloc((size_t)info.st_size))) {
            size_t size = (size_t)info.st_size, done = 0;
            while (done < size) {
                ssize_t count = read(fd, (char *)bytes + done, size - done);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                done += (size_t)count;
            }
            if (done == size && !fstat(fd, &info) && info.st_size == (off_t)size) {
                data = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:YES];
                bytes = NULL;
            }
        }
    }
    free(bytes);
    close(fd);
    return data;
}

static NSArray<NSString *> *decodeImageData(NSData *data, BOOL allowTIFF, int *status) {
    *status = InvalidImage;
    if (!data.length) return nil;
    if (data.length > (NSUInteger)maxBytes) { *status = ImageTooLarge; return nil; }
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)options);
    if (!source) return nil;
    NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
    CGImageRef image = NULL;
    BOOL supported = [type isEqualToString:@"public.jpeg"] || [type isEqualToString:@"public.png"] ||
                     (allowTIFF && [type isEqualToString:@"public.tiff"]);
    if (supported && CGImageSourceGetCount(source) == 1) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, (__bridge CFDictionaryRef)options));
        uint64_t w = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
        uint64_t h = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
        if (w > maxDimension || h > maxDimension || w * h > maxPixels) *status = ImageTooLarge;
        else if (w && h) {
            NSDictionary *thumbnail = @{
                (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @4096,
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES
            };
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)thumbnail);
            if (image && CGImageSourceGetStatusAtIndex(source, 0) != kCGImageStatusComplete) {
                CGImageRelease(image);
                image = NULL;
            }
        }
    }
    CFRelease(source);
    if (!image) return nil;
    VNDetectBarcodesRequest *request = [VNDetectBarcodesRequest new];
    request.symbologies = @[VNBarcodeSymbologyQR];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    CGImageRelease(image);
    if (![handler performRequests:@[request] error:NULL]) return nil;
    NSMutableArray *payloads = [NSMutableArray array];
    for (VNBarcodeObservation *code in request.results) {
        if (code.payloadStringValue.length) [payloads addObject:code.payloadStringValue];
    }
    return payloads;
}

static NSArray<NSString *> *decodeImage(NSURL *file, int *status) {
    NSData *data = readImage(file, status);
    return data ? decodeImageData(data, NO, status) : nil;
}

static NSArray<NSString *> *decodeClipboardImage(NSPasteboard *board, int *status) {
    // Ask for one encoded bitmap, not an NSImage, pasteboard text, HTML, or a URL.
    // ImageIO can then check the byte/pixel budgets before decompressing it.
    NSInteger snapshot = board.changeCount;
    NSPasteboardType type = [board availableTypeFromArray:@[NSPasteboardTypePNG, @"public.jpeg", NSPasteboardTypeTIFF]];
    NSData *data = type ? [board dataForType:type] : nil;
    if (!data || board.changeCount != snapshot) { *status = NoClipboardImage; return nil; }
    return decodeImageData(data, YES, status);
}

// Callbacks marshal results onto the main queue. Keep that queue running while
// waiting; a stalled ImageIO/Vision or LaunchServices request never blocks Tern.
static BOOL waitUntil(BOOL (^done)(void), NSTimeInterval seconds) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    while (!done()) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) return NO;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, MIN(0.1, remaining), true);
    }
    return YES;
}

static BOOL handToTern(NSURL *url) {
    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    NSURL *appURL = [workspace URLForApplicationWithBundleIdentifier:ternBundle];
    if (!appURL) return NO;
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.addsToRecentItems = NO;
    configuration.promptsUserIfNeeded = NO;
    __block BOOL finished = NO, success = NO;
    [workspace openURLs:@[url] withApplicationAtURL:appURL configuration:configuration completionHandler:
        ^(NSRunningApplication *app, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success = !error && [app.bundleIdentifier isEqualToString:ternBundle];
                finished = YES;
            });
        }];
    return waitUntil(^BOOL{ return finished; }, 10) && success;
}

// Accessory command-line apps don't inherit an Edit menu. Route an explicit
// Command-V to the active secure editor only; never inspect the pasteboard.
@interface TernPasteField : NSSecureTextField
@end
@implementation TernPasteField
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.currentEditor && (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand &&
        [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"v"]) {
        [(NSTextView *)self.currentEditor paste:self];
        return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

@interface TernChoice : NSPopUpButton
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles submit:(NSButton *)submit;
@property(nonatomic, weak) NSButton *submit;
@end
@implementation TernChoice
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles submit:(NSButton *)submit {
    self = [super initWithFrame:NSMakeRect(0, 0, 360, 30) pullsDown:NO];
    if (self) {
        self.submit = submit;
        [self addItemWithTitle:@"Choose an invitation…"];
        [self addItemsWithTitles:titles];
        [self selectItemAtIndex:0];
        self.target = self;
        self.action = @selector(selectionChanged:);
        submit.enabled = NO;
    }
    return self;
}
- (void)selectionChanged:(id)sender { self.submit.enabled = self.indexOfSelectedItem > 0; }
@end

static NSAlert *importAlert(NSString *title) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = @"Tern will ask you to review the host and choose Pair or Cancel.";
    [alert addButtonWithTitle:@"Hand to Tern"];
    [alert addButtonWithTitle:@"Cancel"].keyEquivalent = @"\e";
    alert.window.restorable = NO;
    return alert;
}

static NSInteger chooseInvite(NSArray<NSString *> *titles) {
    NSAlert *alert = importAlert(@"Choose the computer to pair with");
    TernChoice *choice = [[TernChoice alloc] initWithTitles:titles submit:alert.buttons.firstObject];
    alert.accessoryView = choice;
    if ([alert runModal] != NSAlertFirstButtonReturn) return -1;
    return choice.indexOfSelectedItem - 1; // Placeholder is never an invitation.
}

static int importText(void) {
    NSAlert *alert = importAlert(@"Paste the full Tern invitation");
    TernPasteField *field = [[TernPasteField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
    field.placeholderString = @"tern://pair?…";
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    BOOL accepted = [alert runModal] == NSAlertFirstButtonReturn;
    NSString *raw = accepted ? field.stringValue : nil;
    [alert.window endEditingFor:nil];
    field.stringValue = @"";
    if (!accepted) return Cancelled;
    return submitCandidates(@[raw], UnsupportedInvite, ^NSInteger(NSArray *titles) { return chooseInvite(titles); },
                            ^BOOL(NSURL *url) { return handToTern(url); });
}

static int importImage(BOOL fromClipboard) {
    NSURL *file = nil;
    if (!fromClipboard) {
        NSOpenPanel *panel = NSOpenPanel.openPanel;
        panel.restorable = NO;
        panel.title = @"Choose a Tern QR image";
        panel.prompt = @"Import";
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.allowedFileTypes = @[@"png", @"jpeg", @"jpg"];
        if ([panel runModal] != NSModalResponseOK) return Cancelled;
        file = panel.URL;
    }
    __block NSArray *payloads;
    __block int status = ImportFailed;
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            int result = InvalidImage;
            NSArray *decoded = nil;
            @try {
                decoded = fromClipboard ? decodeClipboardImage(NSPasteboard.generalPasteboard, &result)
                                        : decodeImage(file, &result);
            }
            @catch (NSException *exception) { result = InvalidImage; }
            dispatch_async(dispatch_get_main_queue(), ^{ payloads = decoded; status = result; finished = YES; });
        }
    });
    if (!waitUntil(^BOOL{ return finished; }, 15)) return ImportFailed;
    if (!payloads) return status;
    return submitCandidates(payloads, NoInvite, ^NSInteger(NSArray *titles) { return chooseInvite(titles); },
                            ^BOOL(NSURL *url) { return handToTern(url); });
}

int tern_pair_import(int source) {
    @autoreleasepool {
        if (![NSThread isMainThread] || source < 0 || source > 2) return ImportFailed;
        // Even malformed image decoders/framework diagnostics must not reach
        // the parent's stderr. This process exits immediately after this call.
        struct rlimit noCore = {0, 0};
        int sink = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (sink < 0) return ImportFailed;
        int redirected = dup2(sink, STDERR_FILENO);
        if (sink != STDERR_FILENO) close(sink);
        if (redirected < 0 || setrlimit(RLIMIT_CORE, &noCore)) return ImportFailed;
        @try {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            [NSApp finishLaunching];
            [NSApp activateIgnoringOtherApps:YES];
            return source == 0 ? importText() : importImage(source == 2);
        } @catch (NSException *exception) { return ImportFailed; }
    }
}
